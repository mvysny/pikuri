# In-memory URL cache — engine results never touch disk

## Problem

Brave's API ToS §3(b)(i) allows only "transient storage required for operation"; Exa's ToS
§4.2(a) allows no copy at all beyond a browser's display cache (quotes and reading in
`cached-result-contents.md`, *stored transiently, by design*). Today `Search::Engines::CACHE`
writes every winning provider's results to disk for 2 h, and `UrlCache` never deletes a stale
file — so a Brave or Exa result can sit on disk indefinitely. Even a reaper deleting expired
files leaves the last 2 h on disk until pikuri runs again — still a stored copy. Safe side: a
Brave or Exa result lives in process memory only, gone at exit.

## Proposal

**Two caches, one API** — today's `UrlCache` renamed, plus a sibling holding the same API in
a `Hash`:

```ruby
cache = Pikuri::UrlFileCache.new(ttl: 2 * 60 * 60, dir: "#{Pikuri::UrlFileCache::ROOT_DIR}/web_scrape")
cache = Pikuri::UrlInMemoryCache.new(ttl: 2 * 60 * 60, max_entries: 100)

cache.fetch(key) { compute }    # today's contract: yield on miss, store, return; a raise stores nothing
cache.read(key)                 # => String, or nil on a miss / stale entry
cache.write(key, value)         # => value — stores unconditionally, replacing any entry
```

`read` / `write` are new on both: `fetch` can't serve a caller that learns *where* a value may
live only after computing it (the search cascade, below).

- **`UrlInMemoryCache`**: `key → [value, stored_at]` behind a `Mutex` — `P_shared_locked`,
  held in class-level constants like today's caches, so every agent in the process shares it.
  Gone at process exit — the property the ToS asks for.
- **`UrlFileCache`**: today's `UrlCache`, renamed, plus `read` / `write`. No other change.
  Nothing in production, so no compat alias (`UrlCache` simply goes).

**Engines declare whether their results may be stored**: every provider answers
`can_cache?` — `DuckDuckGo` `true`, `Brave` and `Exa` `false`. A class-level fact about the
engine's terms, documented on each provider beside its *Privacy posture* with the ToS clause
that decides it.

**Where each value goes:**

| Cache | Holds | Store |
|---|---|---|
| `Engines` query cache | the winning provider's rows | by `winner.can_cache?`: file for DuckDuckGo, memory for Brave / Exa |
| `cached-result-contents` page store | Brave / Exa page text | memory, always |
| `web_scrape`, `fetch` | origin pages pikuri fetched itself | file — no engine terms apply |
| `pikuri-mcp` descriptions | MCP server tool lists | file (TTL ∞) — rename only |

The cascade picks the store after the miss, so `Engines#search` swaps `fetch` for:

```ruby
cached = @memory_cache.read(key) || @file_cache.read(key)
unless cached
  rows, winner = run_cascade(...)
  (winner.can_cache? ? @file_cache : @memory_cache).write(key, rows_json)
end
```

Memory first: a query cached by both (DuckDuckGo won an hour ago, Brave just now) reads the
fresher store's rows either way — no ordering promise worth more than one line.

## Effects on `cached-result-contents`

Its page store moves from disk to memory, which revises several settled bullets there:

- **HMAC secret per process**, random at boot — no `0600` file. A restart changes every handle;
  old ones answer "search again" and can never alias (a new handle matching an old string means
  a 32-bit collision across secrets).
- **Handles live for the process**, until LRU-evicted (1,000 pages, no TTL) — no resume across
  a restart; the 2 h page-store TTL there goes. Resume
  *within* a process (`Agent::History` load in a long-running host) still works.
- **Cross-process enumeration is gone** — another pikuri process has a different store and
  secret. Within one process the 8-hex argument stands unchanged.
- **The reaper is dropped** (already removed there; see *No reaper*).
- The text-mode query cache follows `can_cache?` like the snippet one — in memory whenever
  Brave or Exa won.

## Settled in discussion (2026-11-12)

- **Lives as long as the Ruby VM.** Held in a class-level constant — no teardown on `Agent`
  close, context clear or `Agent::History` load, and no `Finalizers` entry: exit frees it.
  VM-lifetime memory is "transient storage required for operation" for Brave and never leaves
  the process for Exa. It also keeps `pikuri-core`'s cache ignorant of `Agent`.
- **Bounded by entry count, LRU.** `UrlInMemoryCache.new(ttl:, max_entries:)`; past
  `max_entries` a `write` evicts the least recently used. Ruby's `Hash` keeps insertion order,
  so LRU is a delete-and-reinsert on every hit (a `read` mutates, hence the `Mutex` on reads
  too) and eviction is `@entries.shift`. LRU over FIFO because a page the model is reading is
  the one to keep.
- **The TTL stays, as a freshness rule, not a storage one.** An expired entry is a miss and is
  dropped when met. The query cache keeps 2 h, matching the file cache, so a long-running VM
  doesn't answer today's search with yesterday's rows.
- **One instance per use**, each a VM-lifetime constant — never one shared instance, which
  would need `query:` / `page:` key prefixes and put unlike entries under one cap. The file
  caches already work this way, one dir each. The uses and their sizing:
  - **Query caches: 100 entries, 2 h TTL** — an entry is one search's rows. One per mode,
    mirroring the file side's `web_search/` and `web_search_text/`, since the two modes return
    different rows.
  - **Page store: 1,000 entries, no TTL** (`Float::INFINITY`, like `pikuri-mcp`'s cache) — an
    entry is one *page*, so ~100 searches, the bound `cached-result-contents` first settled on.
    No TTL because the text is the engine's snapshot, no staler on a later read, and the LRU
    cap already bounds it — so "how long is a handle good for" is one rule: until evicted.
  - Worst case resident: 1,000 full pages at ~100 KB ≈ 100 MB — accepted, no byte cap until
    measured hurting.
- **No global caching API; each user holds the store its data allows.** A facade with
  `write(key, value, transient_only:)` would still need every caller to pass the flag right —
  it moves the choice behind a boolean, it doesn't remove it — and would need a namespace
  argument plus per-namespace TTL / cap / dir config, re-inventing the per-use instances. So
  "Brave/Exa text never reaches disk" is a fact of *construction*: the page store's constant
  is a `UrlInMemoryCache`, it has no path to disk at all. The one runtime choice is `Engines`'
  `winner.can_cache?` pick, the only place one store mixes engines — guarded by a spec that a
  Brave / Exa win never writes the file cache.
- **No reaper.** With engine results off disk, the disk holds DuckDuckGo rows, pages pikuri
  scraped itself and MCP descriptions — none under a storage clause, so the reaper
  `cached-result-contents` once settled on (for the ToS alone) is dropped; stale files stay
  until their key is overwritten, as today. Disk growth is a separate, older question, for when
  it hurts.
- **A `NULL` on each class** — `UrlFileCache::NULL`, `UrlInMemoryCache::NULL`, each answering
  `read` (always `nil`), `write` (stores nothing) and `fetch` (always yields). Identical in
  behaviour, but there is no common parent to hold a shared one, and a module invented just to
  hold it is code-sharing by inheritance. `spec_helper.rb` stubs every cache accessor — the
  file ones, `Engines`' two memory ones, the page store's — to its class's `NULL`; specs that
  exercise caching inject a real one (a tmpdir file cache, a fresh memory cache).

## Still open
- `Q_can_cache_name` — `can_cache?` (as proposed) vs `storable?` / `results_storable?`. The
  predicate is about the engine's *terms*, not a technical ability; `can_cache?` reads as the
  latter. Leaning: keep `can_cache?`, say "per its terms" in the yardoc.
