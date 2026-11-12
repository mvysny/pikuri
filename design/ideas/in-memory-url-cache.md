# In-memory URL cache — engine results never touch disk

## Problem

Brave's API ToS §3(b)(i) allows only "transient storage required for operation"; Exa's ToS
§4.2(a) allows no copy at all beyond a browser's display cache (quotes and reading in
`cached-result-contents.md`, *stored transiently, by design*). Today `Search::Engines::CACHE`
writes every winning provider's results to disk for 2 h, and `UrlCache` never deletes a stale
file — so a Brave or Exa result can sit on disk indefinitely. The reaper settled in
`cached-result-contents` narrows that to "the last 2 h, until pikuri runs again"; still a
stored copy. Safe side: a Brave or Exa result lives in process memory only, gone at exit.

## Proposal

**Two caches, one API** — today's `UrlCache` renamed, plus a sibling holding the same API in
a `Hash`:

```ruby
cache = Pikuri::UrlFileCache.new(ttl: 2 * 60 * 60, dir: "#{Pikuri::UrlFileCache::ROOT_DIR}/web_scrape")
cache = Pikuri::UrlInMemoryCache.new(ttl: 2 * 60 * 60)

cache.fetch(key) { compute }    # today's contract: yield on miss, store, return; a raise stores nothing
cache.read(key)                 # => String, or nil on a miss / stale entry
cache.write(key, value)         # => value — stores unconditionally, replacing any entry
```

`read` / `write` are new on both: `fetch` can't serve a caller that learns *where* a value may
live only after computing it (the search cascade, below).

- **`UrlInMemoryCache`**: `key → [value, stored_at]` behind a `Mutex` — `P_shared_locked`,
  held in class-level constants like today's caches, so every agent in the process shares it.
  Same TTL semantics as the file cache; a `write` drops expired entries (one pass over a
  small hash), so memory holds at most a TTL's worth of results. Gone at process exit — the
  property the ToS asks for.
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
- **Handles live for the process**, capped by the 2 h TTL — no resume across a restart.
  Resume *within* a process (`Agent::History` load in a long-running host) still works.
- **Cross-process enumeration is gone** — another pikuri process has a different store and
  secret. Within one process the 8-hex argument stands unchanged.
- **The reaper loses its reason**: engine results no longer reach disk, so its ToS argument is
  void (see `Q_reaper`).
- The text-mode query cache follows `can_cache?` like the snippet one — in memory whenever
  Brave or Exa won.

## Still open

- `Q_flag_home` — you described "caching comes with a `transient_only` flag". Two shapes:
  (a) the pick above, one line in `Engines`, the flag being `winner.can_cache?`; or (b) a third
  class composing both, `write(key, value, transient_only:)`, `read` checking memory then disk.
  Leaning (a): `Engines` is the only caller that mixes, and the page store is memory-only —
  (b) is a class for one call site.
- `Q_reaper` — with engine results off disk, what's left on disk is DuckDuckGo rows, scraped
  origin pages and MCP descriptions; none is under a storage clause. Leaning: drop the reaper
  from `cached-result-contents`, keep the old "stale files stay" behaviour.
- `Q_memory_bound` — "take all the text the engine gives" means an Exa search can hold ~1 MB
  (10 rows of full pages); 2 h of busy research is ~100 MB resident. Leaning: accept it, no
  byte cap until it's measured hurting (same call as for the text cap).
- `Q_spec_seam` — `spec_helper.rb` stubs each module's `.cache` to `UrlCache::NULL`. `Engines`
  grows a second accessor (`.memory_cache`) and both need a null: either one shared `NULL`
  object answering `read` / `write` / `fetch` (where does it live, with no common parent?), or
  a `NULL` on each class. Leaning: a `NULL` on each — two tiny objects, no shared home to
  invent.
- `Q_can_cache_name` — `can_cache?` (as proposed) vs `storable?` / `results_storable?`. The
  predicate is about the engine's *terms*, not a technical ability; `can_cache?` reads as the
  latter. Leaning: keep `can_cache?`, say "per its terms" in the yardoc.
