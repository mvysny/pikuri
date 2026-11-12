# Cached result contents — read a search hit's page without touching its origin

## Problem

Snippets rarely answer a question, so every persona that holds `web_search` also holds
`web_scrape` / `fetch` — both `ASSUMED`, so the node's egress is `:attacker_reachable` and the
vouched grade `web_search` declares never shows on a shipped map (`D_egress_axis_shape`: "a soft
cell no shipped wiring reaches"). A scraper confined to the last search's rows does not fix that —
the row *selection* is the channel (`D_no_result_scraper`).

## Proposal

A tool that returns a search hit's page text **from the search engine's own cache**, never from
the origin. The request goes to the same vouched engine `web_search` already reaches, so the tool
declares what `web_search` declares:

```ruby
TrifectaLegs.new(private: false, untrusted: :hard,
                 egress_payload_review: :unreviewed, egress_destination: :tool_vouched)
```

That makes a search-only agent (no `fetch`, no `web_scrape`) actually useful — the first wiring in
the soft verdict cell. Likely home: a narrower researcher persona in `pikuri-subagents`.

Only for engines that can serve page text from a cache with no live crawl. Wired only when such an
engine is configured.

## What the engines offer (checked 2026-11-12)

**Exa — compatible.** pikuri already pins `contents.maxAgeHours: -1` on `/search` (fef8288), the
replacement for the deprecated `livecrawl: "never"`. Exa's `/contents` endpoint takes URLs and
returns text; the same `maxAgeHours: -1` makes it cache-only. Request: `POST
https://api.exa.ai/contents`, header `x-api-key`, body `{urls: [...], text: {maxCharacters: n},
maxAgeHours: -1}`; per-URL outcome in `statuses[]` (`status`, `source: "cached"|"crawled"`,
`error: {tag, httpStatusCode}`). Exa's docs never say what a miss under `-1` does — probed, see
`Q_exa_miss`.

**Brave — not today, maybe via LLM Context.**
- Web Search (`/res/v1/web/search`, what `Search::Brave` calls) returns no page text. The
  `extra_snippets` flag adds up to 5 more excerpts per result, on some plans only — a cheap boost
  for `web_search` itself, not a page read.
- **LLM Context** (`/res/v1/llm/context`, launched Feb 2026, in the Search plan at $5 / 1000
  requests) returns page content as query-relevant chunks grouped per URL (`grounding.generic[]`
  of `{url, title, snippets[]}`), with token budgets (`maximum_number_of_tokens_per_url` up to
  8192), Goggles and `site:` operators. **Query-only** — no URL or result-id input, so it cannot
  answer "give me row 3's page"; it is "search with contents", relevance-filtered, not full text.
- Cache or live? Unclear. The docs describe `fetched_content_timestamp` as "the index's last fetch
  of the page"; the launch blog says Brave digs "into each page's content in real time". No
  max-age / live-crawl knob exists. See `Q_brave_live_fetch`.

**DuckDuckGo — incompatible.** HTML scrape, snippets only.

Sources: <https://api-dashboard.search.brave.com/documentation/services/llm-context>,
<https://brave.com/blog/most-powerful-search-api-for-ai/>,
<https://api-dashboard.search.brave.com/app/documentation/web-search>.

## Open questions

### Settled in discussion (2026-11-12)

- **Two use cases, two wirings, no middle.** Don't mind exfil → `web_search` + `web_scrape`, as
  today. Want `:tool_vouched` *and* page text → `web_search` + this tool, and no
  attacker-reachable tool on the node.
- **A new tool, not a `web_search` parameter**, named **`web_read_cached`**: its own description,
  output size and wiring; a host can wire `web_search` without it. The `web_` prefix is the
  family (`web_search`, `web_scrape` already wear it); `read` is the verb pikuri already uses
  for "give me the content", and `cached` warns it is no live fetch (`web_cache` read as a
  command to cache something). Its description must say it takes a handle from `web_search`,
  never a URL, since `web_scrape` next door does.
- **Handles only, never a URL.** A URL argument carries an arbitrary payload
  (`https://attacker.example/<secret>`), so the vouched grade would rest on Exa never acting on
  a URL it doesn't know — and Exa is a crawler whose default on an unknown URL is to crawl it.
  If a `maxAgeHours: -1` miss ever enqueues a later crawl, the secret is in the attacker's log.
  That is unverifiable from outside, so we don't vouch for it. Same reason rules out following a
  link found inside a cached page. Cost accepted: after `Agent::History` load the registry is
  empty, so old handles answer an error telling the model to search again.
- **Only rows the cache engine itself returned are readable.** A DuckDuckGo row Exa never
  indexed would miss, and if that miss ever triggered a crawl, the *selection* channel of
  `D_no_result_scraper` is back. Rows Exa's own search returned come from its index. A row from
  another engine renders without a handle.
- **Handle = `<search>.<row>`, both 1-based, per agent**: `web_search` numbers its calls, so the
  second row of the agent's third search is `3.2`, rendered in the list (`[3.2] Title — url`) so
  the model copies it, never computes it. Unique for the conversation, so search → read → search
  → read keeps working and older rows stay readable. An unknown handle answers
  `Tool::Result.error` naming the valid ones.
- **Parallel calls**: a batch runs one call at a time (`tool_concurrency` off, see
  {Pikuri::Tool}), so a plain counter is deterministic. If that ever flips, a `Mutex` around
  the increment (Ruby has no stdlib `AtomicInteger`) — not before.
- **Shape**: a per-agent registry (handle → url, title, engine) that `web_search` writes and
  `web_read_cached` reads; both built together per wiring, `P_one_agent`, rebuilt fresh for a
  sub-agent via `for_sub_agent` (a child's `1.1` is its own). `web_search` renders handles only
  when a reader is attached.
- **No prefetch.** `web_read_cached` reads lazily: it looks the handle up and asks the row's *engine*
  for the page (`entry.engine.cached_page(entry.url)` or so), so it never names Exa; a future
  cache-capable engine implements that one method. Wiring `web_read_cached` with no cache-capable
  engine in the cascade raises `ArgumentError`.
- **The handle is the "readable" marker** — only a row whose page the engine can serve from
  cache gets one; no extra symbol. In case (c) no reader is wired, so no handles at all.
- **Three wirings, the orchestrator picks** by the engines it passes `web_search` and the tools
  it wires:
  (a) `web_search`, any engines, no reader — allowed, documented as crippled: on snippets alone
  a model loops, narrowing the query to learn one fact (observed);
  (b) `web_search` with cache-capable engines only + `web_read_cached` — `:tool_vouched` and useful;
  (c) `web_search`, any engines, + `web_scrape` — full exfil leg, as today.
  The (a) loop is the teaching point for (b) in `book/trifecta-detector.md`'s soft-cell part.

### Still open
- `Q_readable_at_search_time` — is "Exa can serve this row from cache" knowable from the
  `/search` response? With `maxAgeHours: -1`, a highlight can only come from the cache, so a
  row carrying highlights should be readable; all 5 rows of one probe search did. A row
  evicted between search and read answers `CONTENT_NOT_CACHED` → `Tool::Result.error`.
- `Q_wiring` — how a host builds the pair: one builder returning both tools around a fresh
  registry, or `WebCache.build(search:)`.
- `Q_exa_miss` — does `/contents` with `maxAgeHours: -1` answer a miss with an error and never a
  crawl? **Probed 2026-11-12** (`/contents`, `text: {maxCharacters: 300}`):
  - an Exa search row (`rrees.prose.sh/ruby-data`) → `success`, `source: "cached"`, $0.001;
  - two never-seen URLs with a random token (`www.example.com/?pikuri-probe=<hex>`,
    `httpbin.org/anything/pikuri-probe-<hex>`) → `error`, tag `CONTENT_NOT_CACHED`,
    `httpStatusCode: 404`, in 262 ms (no synchronous fetch fits that), $0 for the misses;
  - the same two, 10 minutes later → still `CONTENT_NOT_CACHED`, $0. No crawl that landed in the
    cache within 10 minutes.
  Not proven: a crawl that runs later than that, or one that never reaches the cache, is
  invisible here. Closing it takes a host whose access log we can read, watched for days. With
  handles the stakes are small but not zero: a handle names a row Exa's own index returned, so
  no model-made payload can ride a miss — but a row evicted between search and read, re-crawled
  on miss, would tell its owner *which* row was picked (the `D_no_result_scraper` selection
  channel, on a rare path). With URL input it would be the whole secret.
  **Accepted risk (2026-11-12).** It needs three things at once: the attacker's page indexed and
  returned, evicted in the minutes between search and read (not the attacker's to time), and a
  re-crawl on a `-1` miss (unobserved). Each burnt page needs a fresh path, so it is slow and
  targeted. Documented **publicly** — no private attack-vector store: there is no fix to
  embargo, the host choosing wiring (b) over (c) is who needs it, and `D_no_result_scraper`
  already publishes the general channel. On graduation: one line in `SECURITY.md` *Non-goals*
  plus the `web_read_cached` yardoc.
- `Q_brave_live_fetch` — does LLM Context hit the origin at request time? If yes, it carries
  exactly the leak `maxAgeHours: -1` closed for Exa, and Brave stays out. Testable: a page on a
  host we control, indexed by Brave, queried through LLM Context while watching its access log.
- `Q_brave_shape` — if Brave turns out cache-only, LLM Context fits a different tool ("search
  with page chunks", replacing snippets) rather than "read this URL". Worth a tool, or just
  `extra_snippets` on the existing provider?
- `Q_privacy` — Exa trains on query data (`Search::Exa` *Privacy posture*); the URLs a user's
  agent reads are as revealing as its queries. The tool's doc should say so, as Exa's does.
