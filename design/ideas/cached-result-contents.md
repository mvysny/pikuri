# Cached result contents — read a search hit's page without touching its origin

## Problem

Snippets rarely answer a question, so every persona that holds `web_search` also holds
`web_scrape` / `fetch` — both `ASSUMED`, so the node's egress is `:attacker_reachable` and the
vouched grade `web_search` declares never shows on a shipped map (`D_egress_axis_shape`: "a soft
cell no shipped wiring reaches"). A scraper confined to the last search's rows does not fix that —
the row *selection* is the channel (`D_no_result_scraper`).

## Proposal

When a host wants page text, `web_search` asks its engine for **the page text of every row in the
same search request**, served from the engine's own index — never from the origin — and stores it
in an on-disk page store. A new tool, `web_read_cached`, returns a stored row's text by handle. It makes **no
request at all**, so it holds no egress leg:

```ruby
TrifectaLegs.new(private: false, untrusted: :hard, egress_payload_review: :no_egress)
```

`web_search` keeps its own `:tool_vouched` grade, unchanged. That makes a search-only agent (no
`fetch`, no `web_scrape`) actually useful — the first wiring in the soft verdict cell. Likely
home: a narrower researcher persona in `pikuri-subagents`.

## What the engines offer (probed 2026-11-12)

**Exa — compatible, free.** `/search` with `contents: {highlights: true, text: {maxCharacters:
n}, maxAgeHours: -1}`: 10 rows, every one with text (2.8k–23.6k chars), 137 KB response, **$0.007
— the same as highlights alone**. Exa's docs: contents are "available in Exa Search for returned
URLs, at no extra charge up to 10 results per search ($1/1000 pages afterwards)". `maxAgeHours:
-1` keeps it cache-only (fef8288). (`/contents` takes a URL and is cache-only under `-1` too — a
miss is `CONTENT_NOT_CACHED`, 404, ~260 ms, $0, still uncached 10 minutes later — but prefetch
means pikuri never calls it.)

**Brave — compatible via LLM Context.**
- Web Search (`/res/v1/web/search`, what `Search::Brave` calls today) returns no page text;
  `extra_snippets` adds ≤5 excerpts per row, on some plans only.
- **LLM Context** (`GET /res/v1/llm/context`, header `X-Subscription-Token`, launched Feb 2026,
  the Search plan's $5 / 1000 requests — **the same price as a Web Search call**) returns page
  chunks grouped per URL (`grounding.generic[]` of `{url, title, snippets[]}`); `sources[url]`
  carries title, hostname and, with `enable_source_metadata=true`, `description` and
  `fetched_content_timestamp`. With `context_threshold_mode=disabled`,
  `maximum_number_of_tokens_per_url=8192`, `maximum_number_of_tokens=32768`: 10 rows, 0.7k–25k
  chars each, ~103k chars total, 1.5 s.
- **Served from the index, no live fetch.** Every `fetched_content_timestamp` was 1.3–2934 h
  before the request (15 rows, three queries). Clock pages settle it: each chunk's clock text
  matches its timestamp to the second (`time.is/UTC` chunk "05:22:14", fetched `05:22:14Z`,
  requested 06:41). The launch blog's "in real time" is the chunking over stored HTML.
- Query-only — no URL input. Reading one row later would mean re-running its query pinned by an
  inline Goggle (`"$discard\n/<path>$site=<host>"`, which works) — needing the page to rank again
  and a second request. Prefetch avoids all of that.
- **Snippet candidates** (two queries × 10 rows): `/web/search`'s `description` is a
  **query-biased** excerpt, the best for picking a row ("The biggest difference between Data and
  Struct is that Data objects are immutable."). `/llm/context`'s `sources[url].description`
  (`enable_source_metadata=true`) is the page's **meta description**, query-independent: usually a
  fair summary, sometimes useless (GitHub's "LLM inference in C/C++. Contribute to …", "Psst, kid,
  want some cheap and small LLMs?"). The first chunk (threshold `disabled`) is page order —
  title, lede, often the meta description again, sometimes boilerplate ("Skip to content", a
  byline), now and then gold (llama.cpp README's `--ctx-size` row).
- **The two endpoints rank differently**: only 5–6 of 10 URLs in common for the same query, so
  switching endpoints changes which pages the model sees, not just the snippets — better or worse,
  unmeasured.

**DuckDuckGo — incompatible.** HTML scrape, snippets only; its rows get no handle.

Not covered for either engine: whether a query ever schedules a background re-crawl of a row.
That is an index-freshness question about `web_search`'s own request, which already holds the
vouched leg — `web_read_cached` adds no request for it to ride.

Probe scripts were throwaway (`Net::HTTP`, keys from the examples config).

Sources: <https://api-dashboard.search.brave.com/documentation/services/llm-context>,
<https://brave.com/blog/most-powerful-search-api-for-ai/>,
<https://api-dashboard.search.brave.com/app/documentation/web-search>,
<https://docs.exa.ai/reference/get-contents>, <https://docs.exa.ai/reference/livecrawling-contents>.

## Settled in discussion (2026-11-12)

- **Three wirings, the orchestrator picks** by the engines it passes `web_search` and the tools
  it wires:
  (a) `web_search`, any engines, no reader — allowed, documented as crippled: on snippets alone a
  model loops, narrowing the query to learn one fact (observed);
  (b) `web_search` with cache-capable engines only + `web_read_cached` — vouched search, a
  no-egress read;
  (c) `web_search`, any engines, + `web_scrape` — full exfil leg, as today.
  The (a) loop is the teaching point for (b) in `book/trifecta-detector.md`'s soft-cell part.
- **A new tool, not a `web_search` parameter**, named **`web_read_cached`**: its own
  description, output size and wiring. The `web_` prefix is the family; `read` is the verb pikuri
  already uses for "give me the content"; `cached` says it is no live fetch (`web_cache` read as a
  command to cache something). Its description must say it takes a handle from `web_search`,
  never a URL, since `web_scrape` next door does.
- **Prefetch, in the search request.** In text mode `Search::Exa` adds `text` to its contents
  and `Search::Brave` calls `/llm/context` instead of `/web/search`; both still render snippets
  for the model. Same price either engine, one request. (This reverses an earlier "read lazily
  per handle", which needed a read-time request, a miss path and, for Brave, a second ranked
  search.)
- **Handles only, never a URL.** `web_read_cached` answers from the page store, so a URL would
  mean a fetch — the `D_no_result_scraper` channel, or with a URL argument the whole secret.
  Same for following a link inside a cached page.
- **Under revision — `in-memory-url-cache.md`** moves the page store and every Brave/Exa result
  into process memory; the disk, secret-file, resume and reaper bullets below change with it.
- **The page store is on disk, keyed by handle — no in-memory registry.** One JSON file per
  page, `<handle>.json` holding url, title, the full text and the engine's index timestamp when
  it gives one, in its own dir under `UrlCache::ROOT_DIR`. A search writes every row that came
  back with text (overwriting a stale or same-URL entry); `web_read_cached` reads. Disk, not
  memory, so handles survive `Agent::History` load, are shared tree-wide and across processes,
  and need no counter, `Mutex`, eviction cap or wiring object.
- **Handle = `HMAC-SHA256(secret, url)`, first 8 hex digits**, rendered in the list
  (`[a3f9c21e] Title — url`) so the model copies it. The secret is random, made once, kept
  beside the files (mode `0600`). A keyed hash because each property the alternatives broke
  matters:
  - *Collision-free by construction*: when `<h8>.json` is fresh and holds a different URL, the
    new URL takes 12 digits instead. Random collisions are rare (~10k fresh entries in 2³²);
    engineered ones need the secret — an unkeyed hash lets a crafted URL take over a popular
    page's handle in minutes of CPU, defeating the model's choice of row.
  - *Never aliased*: a handle is a function of its URL, so a stale one can't come back meaning
    another page — the bug in a per-process `<search>.<row>` counter, which restarts at 1 after
    a resume, and in any scheme that reuses freed IDs.
  - *Not enumerable*: the store is machine-wide, so small or sequential IDs would let a model in
    one conversation walk through another's research — private data reaching a node that holds
    untrusted text and a query leg, all three legs. At 2³² a blind guess hits once in ~400k
    calls, and then a random page. Without the URL there is no way to compute a handle; with
    it, the only way to get one is a search that writes fresh text anyway.
  - *Same page, same handle* across repeated queries and searches.
  Deleting the secret changes every handle — old ones answer "search again", a safe failure.
  **Why not shorter** (say 4 hex, growing on collision): a keyed hash is unpredictable, not
  unguessable — what counts is the store's fill. ~10k entries in 4 hex (65,536) is a ~14% hit
  per blind guess, 5 hex ~1%; the shortest handles are always the most guessable, so the length
  is set by the guess rate (space ≳ 10⁵ × store), not by collisions. (Worked for a 7-day
  store; at 2 h the store is ~100× smaller and 8 hex is margin, kept so a busy multi-process
  machine never revisits this.) 8 hex is a few tokens, the size of the tool-call ids models
  already copy.
- **The handle is the "readable" marker.** A row gets one iff its text came back with *this*
  search — never a DuckDuckGo row, never an Exa/Brave row without text, even when the store
  holds that URL from another search (else a handle's presence would tell one session what
  another read). No extra symbol. An unknown or expired handle answers `Tool::Result.error`
  telling the model to search again.
- **2 h TTL on the page store**, the query cache's — how long a handle stays readable, not
  freshness: the text is the engine's snapshot (Brave's were 1.3–2934 h old when searched), no
  staler on a later read. 2 h, not the 7 days first agreed, because both engines' terms forbid
  storing results beyond the transient (*stored transiently, by design*, below); resuming the next day, or a
  conversation past 2 h, gets "search again" — and the re-search writes the page back under the
  same handle. Freshness is shown instead:
  the read prints the engine's index timestamp when there is one (Brave
  `fetched_content_timestamp`; Exa's to check). Asking the origin for its `Cache-Control` is
  out: the query picks which pages rank, so a per-row origin request is the
  `D_no_result_scraper` channel again, and the leg turns `:attacker_reachable`.
- **Plain files, no SQLite.** The handle is the URL index (looking one up is computing it), so
  SQLite would buy only atomic writes and real expiry — not worth a native extension in
  `pikuri-core`; real expiry comes from the reaper below.
- **Engine results are stored transiently, by design.** Both engines' terms forbid keeping
  them (read 2026-11-12):
  - Brave's API ToS §3(b)(i): the customer may not "store, cache, or create a database of
    Search Results, in whole or in part, other than transient storage required for operation of
    Customer Applications"; §1.10's Search Results is any API output, LLM Context text too. The
    pricing FAQ sells storage rights on a custom plan.
  - Exa's Terms of Service cover "(iii) our application programming interface"; §4.2(a)
    forbids to "download, modify, copy … duplicate … any information … obtained from or
    through, the Services, except for temporary files that are automatically cached by your web
    browser for display purposes". Its Master Subscription Agreement says "Customer owns all
    Customer Data" (output included), but binds Order Form customers — a pay-as-you-go key is
    under the ToS.
  Read literally, Exa's clause forbids even the existing 2 h `web_search` cache; 2 h is the line
  we call transient — every engine-result cache (both query caches, the page store) keeps it.
  Not legal advice; a host needing more buys storage rights.
- **`UrlCache` reaps.** A file we stop reading after the TTL is still stored, so every
  `UrlCache` (also `web_scrape`'s) deletes files older than its TTL: on its first use in a
  process, then at most every ~10 min on a write; `Errno::ENOENT` from a racing sweeper or reader
  is a miss. Claim: while pikuri runs nothing outlives its TTL by more than the sweep interval;
  leftovers of a stopped pikuri go on its next start. The gap — the last 2 h sit on disk until
  pikuri runs again — is documented, not closed (a `systemd` timer is the host's business, an
  `at_exit` sweep misses a crash). Kept in mind, not done: `$XDG_RUNTIME_DIR` (tmpfs, wiped at
  logout) as the engine caches' home would keep them off disk entirely, at the cost of a new
  `Paths` entry and a fallback.
- **Wiring**: `WebSearch.build(..., page_text: false)` turns text mode on; given `true` with no
  cache-capable engine it raises `ArgumentError`. `web_read_cached` is a stateless constant like
  `FETCH`, `P_shared_benign` like `UrlCache` (racing writers write the same bytes). Lost: a
  reader wired without a text-mode search can't be caught — every read answers "search again".
- **One store tree-wide, no `for_sub_agent`.** A researcher child can reply "see `a3f9c21e`" for
  a parent holding `web_read_cached`. Not a side channel around the delegation gate: rows are
  what the engine returned, never model-written text.
- **Attack vectors are documented publicly**, no private store: nothing here is an unfixed bug
  to embargo, and the host choosing (b) over (c) is who needs to know.
- **Brave's snippet from `/llm/context` is the meta description**, falling back to the first
  chunk when empty. In wiring (b) the snippet only steers *which* row to read — the full text is
  one `web_read_cached` call away — and the query-biased `/web/search` excerpt would cost a second
  request or a chunk-scoring heuristic. Without text mode Brave stays on `/web/search`.
- **The search cache holds rows, not Markdown.** An entry is JSON `[{url, title, snippet,
  has_text}]`; rendering and handle lookup run after the cache lookup. `count_rendered` goes: the
  summary counts rows, which a hostile snippet can't inflate. No migration of old Markdown
  entries (nothing in production).
  - **Text mode gets its own query cache**, a second `UrlCache` under `web_search_text/` beside
    `web_search/`: the two modes return different rows (Brave's endpoint and ranking), so a
    snippet-only hit never hides handles and a `/llm/context` ranking never reaches a
    snippet-mode wiring. Text lives only in the page store, under the same 2 h TTL; the pages
    are written just before the query entry, so for a few seconds at expiry a hit can find a
    row's page gone — that row shows no handle.
  - A hit makes no request, so no leg.
- **Take all the text the engine gives; trim at read time.** The search asks for each engine's
  maximum (Exa: no `maxCharacters`, or its ceiling; Brave: the per-URL and total token ceilings —
  both limits to confirm against the docs when implementing), and the page store keeps it whole.
  `web_read_cached` takes `max_chars` with `web_scrape`'s defaults (20k, clamped to 100k) and the
  same truncation marker — one truncation helper for both tools. Its output starts with the
  stored url and title. No optimizing until there's a measured need.
- **Brave chunks are joined with a visible gap** (`\n\n…\n\n`), so excerpts don't read as one
  continuous page.

- **Privacy: prefetch sends nothing new** — the query was going anyway — so
  `web_read_cached`'s doc says it sends nothing and links each engine's *Privacy posture*
  (Exa trains on queries; Brave keeps a 90-day log). Brave's Search API privacy notice covers
  the whole API, so `/llm/context` falls under it like `/web/search`; `Search::Brave`'s yardoc
  now cites it (re-read 2026-11-12, notice updated 3 Nov 2026).

## Still open

Nothing — ready to implement.
