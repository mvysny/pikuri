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
in a registry. A new tool, `web_read_cached`, returns a stored row's text by handle. It makes **no
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
- **Prefetch, in the search request.** With a registry, `Search::Exa` adds `text` to its
  contents and `Search::Brave` calls `/llm/context` instead of `/web/search`; both still render
  snippets for the model (Exa highlights; Brave `description`, or the first chunk). Same price
  either engine, one request. (This reverses an earlier "read lazily per handle", which needed
  a read-time request, a miss path and, for Brave, a second ranked search.)
- **Handles only, never a URL.** `web_read_cached` answers from the registry, so a URL would mean
  a fetch — the `D_no_result_scraper` channel, or with a URL argument the whole secret. Same for
  following a link inside a cached page. Cost accepted: after `Agent::History` load the registry
  is empty, so old handles answer an error telling the model to search again.
- **The handle is the "readable" marker.** A row gets one iff its text came back with the search
  — never a DuckDuckGo row, never an Exa/Brave row that came back without text. No extra symbol.
- **Handle = `<search>.<row>`, both 1-based, per registry**: the second row of the third search
  is `3.2`, rendered in the list (`[3.2] Title — url`) so the model copies it, never computes it.
  Unique for the conversation, so search → read → search → read keeps working and older rows
  stay readable. An unknown handle answers `Tool::Result.error` naming the valid ones.
- **Wiring**: the host makes a `Search::ResultHandleRegistry` (a mouthful, but clear) and hands
  it to both — `WebSearch.build(..., registry: nil)` (optional: no registry, no handles, no
  prefetch — cases (a) and (c) need nothing) and `WebReadCached.build(registry:)` (required). It
  holds handle → url, title, text.
  - `WebSearch.build` given a registry but no cache-capable engine raises `ArgumentError`.
  - `WebSearch.build` attaches itself to the registry; `web_read_cached` executed against a
    registry no search ever attached **raises** (a host wiring bug, not something the model can
    react to). Not checkable at build time — the two builds come in either order.
- **One registry for the whole agent tree, no `for_sub_agent`.** `SubAgentTool` rebuilds each
  tool through its own no-arg `for_sub_agent`, so two tools each minting a fresh registry would
  split the pair in the child. Sharing is better anyway: handles are unique tree-wide, and a
  researcher child can reply "see `7.2`" for a parent holding `web_read_cached`. Not a side
  channel around the delegation gate: rows are what the engine returned, never model-written
  text.
- **`P_shared_locked`**: shared across agents (and possibly threads), so a `Mutex` around the
  counter and the row map — Ruby's stand-in for `AtomicInteger`. A tool batch runs one call at a
  time (`tool_concurrency` off), so numbering within one agent is deterministic.
- **The registry keeps the last 100 searches** (a constant, not a knob) — ~100–140 KB of text
  per search, so ≤ ~14 MB, tree-wide. The oldest search's rows drop silently; reading one of its
  handles answers "search N is no longer stored; search again" — told apart from a handle that
  never existed by the search number alone (≤ counter − 100), same advice as after a resume.
- **Attack vectors are documented publicly**, no private store: nothing here is an unfixed bug
  to embargo, and the host choosing (b) over (c) is who needs to know.

## Still open

- `Q_search_cache` — `Engines::CACHE` is on disk, keyed by the query, and holds the rendered
  result. With a registry the entry must hold rows with text — a different key (or subdir) so a
  snippet-only hit never serves a reader, and ~10× bigger entries.
- `Q_brave_snippet` — what `web_search` shows for a Brave row from `/llm/context`. **Probed
  2026-11-12**, two queries × 10 rows, against today's `/web/search` `description`:
  - `/web/search` `description` is a **query-biased** excerpt — the best for picking a row
    ("The biggest difference between Data and Struct is that Data objects are immutable.").
  - `/llm/context` `sources[url].description` (`enable_source_metadata=true`) is the page's
    **meta description**, query-independent: usually a fair summary, sometimes useless (GitHub's
    "LLM inference in C/C++. Contribute to …", "Psst, kid, want some cheap and small LLMs?").
  - The first chunk (threshold `disabled`) is page order — title, lede, often the meta
    description again, sometimes boilerplate ("Skip to content", a byline), now and then gold
    (llama.cpp README's `--ctx-size` row).
  - **The two endpoints rank differently**: only 5–6 of 10 URLs in common for the same query.
    Switching endpoints changes which pages the model sees, not just the snippets — better or
    worse, unmeasured.
  Leaning: meta description, falling back to the first chunk when empty. In wiring (b) the
  snippet only has to steer *which* row to read — the full text is one `web_read_cached` call
  away — and the query-biased excerpt would cost a second request or a chunk-scoring heuristic.
- `Q_text_cap` — Exa `maxCharacters` per row and Brave's 32k-token total: what to request, and
  `web_read_cached`'s own `max_chars` / truncation marker, shaped like `web_scrape`'s.
- `Q_privacy` — Exa trains on query data (`Search::Exa` *Privacy posture*). Prefetch sends
  nothing extra — the query was going anyway — but the tool's doc should say what it says.
