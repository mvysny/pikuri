# Idea: mem0 as the `@private` memory store

This note is the **store-selection and evaluation** thread for the
`@private` memory feature, split out of [`memory.md`](memory.md) (which
kept growing) so that note stays about the *design* and this one has room
for the live findings. It picks up after [`memory.md`](memory.md)
§"Property checklist" (the rubric, referenced here as `#N`) and §"Survey
outcome" (the cross-store comparison) — both of which stay there.
Everything mem0-specific lives here: the decision, the v3 config
verification, the live smoke, and the recall-quality evaluation.
References to `#N` and to "§Survey outcome" point back to
[`memory.md`](memory.md).

**Status (2026-05-31):** mem0 chosen; its wanted local config verified and
smoke-tested working; the recall-quality pass found the *models* perform
well but surfaced a likely **pgvector top-k inversion** (recall returns
the *farthest* matches) — under investigation before any `pikuri-memory`
code.

### Decision (2026-05-31): mem0, accept the weight, no second store

After the survey and the custody/lightness debate, **chosen: mem0** —
and the custody-vs-resolution split (a separate raw store) is
**dropped**.

- **Trust = adoption × age, and mem0 wins both.** The agent-memory
  category is young (born ~2023); *none* of the candidates is a
  decade-old battle-tested store. Within that young field mem0 is the
  oldest and by far the most-used (Apache-2.0, ~2–3yr lineage, 37k★) —
  the most-vetted code to hand the user's most private data to. This
  deliberately **reverses the survey's footprint-driven lean** toward
  nuggets/hindsight: for a private-memory store, trust-by-adoption
  outranks lightness, and the lighter options are too young to clear
  that bar (§"Survey outcome" — the trust filter empties the field down
  to mem0).
- **Accept the heaviness.** Neo4j + docker / docker-compose is
  acceptable. pikuri talks to mem0 as a **self-managed sidecar over a
  thin Faraday HTTP client** — the exact pattern `pikuri-vectordb`'s
  `ChromaServer` already establishes (Docker supervisor routed through
  `Subprocess.spawn` + HTTP client). Local LLM + local embeddings (reuse
  `pikuri-vectordb`'s `Embedder` over `RubyLLM.embed`). A second backend
  can be added later *if* ever wanted — not now.
- **No SQLite, no separate raw store.** The split existed only to avoid
  trusting a young framework with sole custody; choosing the *trusted*
  framework removes that premise. **All memories go into mem0.** Its
  `add`/`search` is our `append`/recall; mem0 owns resolution
  (dedup/supersede/attribute-drift) — the work we explicitly don't want
  to hand-roll. In-loop vs off-loop extraction stops mattering much: if
  mem0 owns extraction we can offload the whole job to it.
- **Audit & forget go through mem0's surface, not `rm`.** Matches the
  original stance (§ top: "doesn't need to be user-auditable, or pick a
  DB with a good auditable dump") — mem0 provides export/dump + a delete
  API. Coarse erase = drop the store volume; granular per-fact erase =
  its delete API (v2, #3). File-shaped storage is no longer needed for
  audit or forget.

Narrow deployment-reality check still outstanding before any build:

1. Is **Neo4j** genuinely required, or optional (vector-store-only)?
   Full docker-compose component list.
2. **Local LLM + local embeddings** wiring — can mem0 point at
   llama.cpp / our `Embedder` with no cloud leg?
3. **REST surface** for a thin Faraday client
   (`add`/`search`/`delete`/`get_all` endpoints + shapes).
4. Does `add()` **preserve raw history** (v3 ADD-only) or mutate? —
   determines whether mem0 is both raw + resolved, or whether the
   conversation transcripts are the only raw source.

**Neo4j is an empirical question, not a footprint one.** *(Superseded
by the verification below — mem0 v3 removed Neo4j from the OSS SDK
entirely, so there is no graph to toggle. Kept for the journey.)* Q1
settles only whether we *can* run without the graph — *should* we is a
separate, quality question that only a test answers. Even if Neo4j turns
out optional, run a recall-quality comparison **with vs. without the
graph** on representative tasks (relational queries like "who is my
manager's manager", multi-hop persona recall); if mem0 is materially
worse without it, **bring Neo4j back**. Footprint-aversion does not get
to decide recall quality — measure it before dropping the graph.

### Verification outcome (2026-05-31): mem0 v3 removed Neo4j; config achievable

The deployment check came back; the headline reshapes the Neo4j thread.
Verified against mem0 `main` source (v3 "token-efficient" algorithm,
~April 2026 — several docs still describe stale v2; pin to **v3**):

- **Neo4j is gone, not just optional.** v3 removed graph/Neo4j from the
  OSS SDK (~4k lines; `enable_graph`/`graph_store` deleted). Relations
  are now **built-in entity linking** into a parallel
  `{collection}_entities` collection in the *same vector store* — no
  external graph DB. **This obsoletes the "with vs. without Neo4j" test
  above: there is no graph to toggle in OSS v3.** The relational
  *capability* survives in lighter form (entity linking / same-entity
  resolution — the part we need for dedup/supersede); what's lost is
  external-graph multi-hop reasoning. Acceptable v1 trade for a
  single-user persona; revisit only if multi-hop recall proves needed.
- **Lighter than feared.** Shipped docker-compose = **3 containers, no
  Neo4j**: mem0 FastAPI server (`:8000`), Postgres/pgvector (vector
  store + history), optional dashboard. The "docker-compose sprawl"
  worry largely dissolves — one app + one Postgres.
- **Fully local: yes.** LLM + embeddings via a local OpenAI-compatible
  endpoint (`openai_base_url`, clean fit for our llama.cpp) or
  `ollama`/`lmstudio` providers. Cloud is the *default*; local is
  explicit opt-in config. *(Corrected below — see §"Source dive before
  the smoke test": `ollama`/`lmstudio` are a **library** capability; the
  **server image** bundles only `openai`/`anthropic`/`gemini` and rejects
  anything else with HTTP 400, so the actual local path is
  `provider: "openai"` + `openai_base_url` → llama.cpp, not an ollama
  provider.)*
- **REST: yes.** FastAPI `server/main.py`: `POST /memories` (add),
  `POST /search`, `GET`/`DELETE /memories[/{id}]`,
  `GET /memories/{id}/history`, `POST /reset`. Thin Faraday client
  works, no Python in our loop — same shape as `ChromaServer`'s client.
  (Exact `add`/`search` JSON field names are med-confidence →
  smoke-test against a live v3 container.)
- **`add()` is ADD-only / non-destructive in v3 — validates our model.**
  New facts coexist with old; recency resolved at read via `created_at`;
  per-memory history API exists. This *is* the append-only +
  read-time-recency design, confirmed in the chosen tool. Lever:
  `infer=true` (default) stores LLM-*extracted facts*; `infer=false`
  stores *verbatim turns* — so the dropped two-store split (raw log +
  resolved view) is available *inside* mem0 (two collections) at no
  extra infra, if ever wanted.

Net: the wanted config — **mem0 sidecar, no Neo4j, fully-local
LLM+embeddings, HTTP-driven from Ruby, history-preserving** — is
achievable as-is, no design rethink.

**Status (2026-05-31).** Graph trade-off **accepted**: v1 runs on v3's
built-in entity linking; external multi-hop graph reasoning is out of
scope, revisit only if it proves necessary. **TODO (deferred — not yet
done): smoke test** a running mem0 v3 container against local llama.cpp —
`POST /memories` + `POST /search` from a throwaway Faraday call — to lock
the exact `add`/`search` JSON shapes (the one med-confidence item) and
pick the vector store (compose ships pgvector; library default is local
Qdrant). This is the boundary between "designed" and "seen to work," and
the natural first step before any `pikuri-memory` code. *(The source-level
half of that step is now done — see §"Source dive before the smoke test"
below; only the live container round-trip remains.)*

### Source dive before the smoke test (2026-05-31): shapes locked, provider list corrected, deployment reality

Ahead of booting anything, cloned `mem0ai` `main` (library **2.0.4**;
server code current) and read the self-hosted server end-to-end
(`server/main.py`, `server_state.py`, both Dockerfiles, the compose,
`db.py`), plus checked Docker Hub. These findings are **source-confirmed,
not yet runtime-confirmed** — the live smoke (boot a container, real
`add`/`search` round-trip against llama.cpp) is still the open step. What
the source already settles:

- **Three version axes — stop conflating them.** Package `mem0ai 2.0.4`
  (PyPI); config-schema `"version": "v1.1"` (set in `DEFAULT_CONFIG`);
  "v3" = the internal token-efficient *algorithm* generation this note
  tracks. All independent — "v3" is not a release tag you can pin.

- **The REST surface is locked from source** (`server/main.py`) — this
  answers the med-confidence item *structurally*; only live response
  *values* remain. The shapes the Faraday client will target:
  - `POST /memories` — `{ messages: [{role, content}], user_id?,
    agent_id?, run_id?, metadata?, infer?, memory_type?, prompt? }`. At
    least one of `user_id`/`agent_id`/`run_id` is required (else HTTP 400).
  - `POST /search` — `{ query, filters?: {user_id: …}, top_k?,
    threshold? }`. Top-level `user_id`/`agent_id`/`run_id` are
    **deprecated** — pass them inside `filters`.
  - Also `GET /memories[?user_id=]`, `GET|PUT|DELETE /memories/{id}`,
    `GET /memories/{id}/history`, `POST /reset`, `GET|POST /configure`.
  - The `infer` lever is present (`infer=true` stores LLM-extracted
    facts, `infer=false` stores verbatim turns) — the raw-vs-resolved
    two-store option, available inside one server, as the verification
    section predicted.

- **Provider correction — supersedes the "ollama/lmstudio" line above.**
  `_validate_bundled_providers` rejects any non-bundled provider on
  `/configure` with HTTP 400. The bundled sets are cloud-only:
  `BUNDLED_LLM_PROVIDERS = (openai, anthropic, gemini)`,
  `BUNDLED_EMBEDDER_PROVIDERS = (openai, gemini)`. So `ollama`/`lmstudio`
  are reachable from the *library* but **not** through this server. The
  local-llama.cpp path is therefore: keep `provider: "openai"`, set
  `openai_base_url` → `http://192.168.122.1:8080/v1` with a dummy key;
  provider stays "openai" so validation passes while traffic goes local.
  (A genuine ollama provider would mean editing `requirements.txt` +
  the `BUNDLED_*` tuples + a rebuild — not worth it.)

- **The 768-dim gotcha is real.** `DEFAULT_CONFIG` sets no
  `embedding_model_dims`, so pgvector defaults to OpenAI's 1536. Our
  embedder `nomic-embed-text-v1.5` is **768**. `/configure` must pass
  `embedding_model_dims: 768` **and** a *fresh* `collection_name` (the
  boot-time default may already have created a 1536 table; changing dims
  on the same collection mismatches). `/configure` is live-reconfigurable
  — `server_state.update_config` deep-merges over `DEFAULT_CONFIG`,
  rebuilds `Memory.from_config`, and persists the override to `mem0_app`
  — so reconfiguring *before the first `add`* is the clean path.

- **Deployment reality.**
  - *Published image is stale; build-from-source is blessed.*
    `mem0/mem0-api-server:latest` is a single Hub tag last pushed
    2025-09-10 — pre-v3, pre-auth, pre-bundled-providers; its API would
    differ. Upstream's own run path (`make up` → `docker compose up -d
    --build`) rebuilds from the checkout every time and never pulls that
    image (`make build` is a local convenience, not a release). The live
    artifact is the source tree + PyPI `mem0ai>=0.1.48`. The library is
    the maintained headline; the server image is a stale courtesy.
  - *Service shape.* Dev compose = 3 services (mem0 `8888→8000`, pgvector
    `8432→5432`, a Next.js dashboard — droppable for a REST smoke). The
    prod `Dockerfile` is lighter (`python:3.12-slim`, `requirements.txt`
    only, **no `[graph]`/Neo4j extra**) but its CMD skips migrations, so a
    compose built on it must run `alembic upgrade head` before `uvicorn`.
  - *Two databases, one server.* The `postgres` DB holds the pgvector
    memories; the `mem0_app` DB (created by `init-db.sh`, migrated by
    alembic) holds auth/settings/request-logs. Memory *history* is a
    separate **SQLite** file (`/app/history/history.db`), not Postgres —
    a refinement to the earlier "Postgres … + history" shorthand.
  - *Auth.* On by default; `AUTH_DISABLED=true` (local-dev only) bypasses
    the JWT/admin requirement for the smoke test.

- **Vector store leaning: pgvector.** The open "pick the vector store"
  item tilts toward pgvector — it's what the server's `DEFAULT_CONFIG`
  and shipped compose use, keeping the footprint at one Postgres. (Qdrant
  is the *library* default, and what the now-sunset OpenMemory used.)
  Final pick still waits on the live smoke.

- **OpenMemory vs mem0 — and why we're not using it.** OpenMemory
  (`openmemory/`) is a separate, MCP-first, Qdrant-backed *end-user* app
  built on the mem0 library, with its own UI. It is **being sunset** (its
  README redirects to `cd server && make bootstrap`). Tempting, since
  `pikuri-mcp` could consume an MCP memory server with no bespoke client —
  but a dead end. The REST-over-Faraday path (this note's choice) is the
  surviving one; the mem0 *engine* is shared either way.

**Still genuinely pending the live smoke:** exact JSON *values* of
`add`/`search` responses (ids, the `event` field on add, the score field
name on search), that a 768-dim pgvector collection is accepted
end-to-end, and that llama.cpp's `/v1` serves mem0's embed + chat calls
without shape surprises. The runtime to do it (trimmed compose + `.env`,
build-from-source) is designed and ready to write. *(Done — see
§"Live smoke outcome" below; all of these are now resolved.)*

### Live smoke outcome (2026-05-31): passes end-to-end against llama.cpp

Booted the stack (trimmed build-from-source compose: pgvector + the mem0
FastAPI server, dashboard dropped) and ran a real `add` → `search`
round-trip against the local llama.cpp. **It passes** — this is the
"designed → seen to work" line crossed.

- **One build fix was needed.** The prod `Dockerfile`
  (`python:3.12-slim`) plus `requirements.txt`'s plain `psycopg>=3.2.8`
  crashes at boot with *"no pq wrapper available"* — slim ships no
  `libpq`, and the pin omits the C/binary impl. The dev Dockerfile dodges
  this via the full `python:3.12` base. Fix for a slim build: add
  `psycopg[binary]` (bundles libpq). Whatever `pikuri-memory`'s
  `ChromaServer`-style supervisor builds/pulls must account for this.
- **Local wiring works as corrected.** `provider:"openai"` +
  `openai_base_url` → `http://…:8080/v1` routes both the extraction LLM
  and the embedder to llama.cpp; `/configure` accepts it (provider stays
  "openai", so bundled-provider validation passes), no cloud leg. The
  mem0 container reached the llama.cpp host IP with no `extra_hosts`
  needed.
- **768-dim handling confirmed.** `/configure` (sent *before* the first
  `add`) with `embedding_model_dims: 768` + a fresh `collection_name`
  deep-merges over `DEFAULT_CONFIG` and creates the 768 pgvector
  collection; the 1536 boot-default collection is left unused. End-to-end
  add+search on 768 works.
- **Response shapes — now runtime-locked** (`user_id` smoke run):
  - `POST /memories` → `{"results":[{"id":"<uuid>","memory":"<fact>","event":"ADD"}]}`
  - `POST /search` (body `{query, filters:{user_id}, top_k}`) →
    `{"results":[{id, memory, hash, metadata, "score":0.30…, created_at, updated_at, user_id}]}`
    — the score field is **`score`**.
  - `GET /memories?user_id=` → same row shape as search, minus `score`
    and `event`.
- **v3 extraction consolidates.** The three input facts ("name is Martin",
  "vegetarian", "loves hiking") came back as a *single* memory string with
  `event:"ADD"` — v3's token-efficient behavior, ADD-only as the design
  assumed. (Supersede/coexistence resolution across *multiple* turns was
  not exercised here — a follow-up smoke, not blocking.)
- **Open follow-up — `score` semantics.** A clearly-relevant query scored
  `0.30`. Whether that's cosine-similarity (higher=better) or a distance
  (lower=better) decides how `threshold` must be set; nail it down before
  `pikuri-memory` relies on `threshold`.

**Net: the chosen config is no longer just achievable on paper — it runs.**
mem0 v3 server, no Neo4j, pgvector at 768, fully-local LLM+embeddings via
llama.cpp, HTTP-driven, history-preserving. The remaining unknowns are
quality/semantics (score meaning, multi-turn supersede), not feasibility.
`pikuri-memory` can be built against this surface; the throwaway smoke
stack was torn down (`docker compose down -v`).

### Recall-quality evaluation (2026-05-31): models good, a likely top-k inversion

After the smoke proved *feasibility*, a focused recall-quality suite
(Ruby + Faraday harness — also the first sketch of `pikuri-memory`'s HTTP
client) plus a retrieval diagnostic ran against the same live stack.
Headline: **the models perform well; mem0's pgvector retrieval in this
stack returns the *farthest* matches, not the nearest** — a correctness
bug that makes recall unusable as configured until resolved.

- **`score` = cosine distance (1 − similarity); lower = closer.** Confirmed
  numerically: mem0's `0.2364` for a query/doc pair equals `1 − 0.7636`
  (the direct cosine of the same pair). Settles the threshold direction.
- **Embeddings discriminate cleanly.** `nomic-embed-text-v1.5` (768)
  separates relevant (cos ≈0.76–0.78) from irrelevant (≈0.52–0.61) *even
  without* nomic's task prefixes. The prefixes (`search_query:` /
  `search_document:`) widen the gap ~25% (+0.187 → +0.231) but are not
  required for correctness — which is also why `pikuri-vectordb` works
  without them (and it has a `bge` reranker second stage that mem0 lacks,
  papering over weak first-stage recall).
- **The bug — `top_k` returns the *farthest* k.** With 8 facts and
  `top_k=3`, "Where does the user live?" returned peanuts/Ruby/Alice (the
  three *least* relevant) and *omitted* "lives in Brno" (distance 0.217,
  by far the closest); Brno appears only at `top_k=8`, dead last. So
  mem0/pgvector is ordering by distance **descending** and limiting —
  returning least-relevant rows. Catastrophic for recall at any realistic
  store size. Root cause not yet hunted; candidates: the old
  `ankane/pgvector:v0.5.1` image, this mem0 version's pgvector provider,
  or a distance-metric/config mismatch. mem0's *library* default store is
  Qdrant, not pgvector — may not reproduce there.
- **Write latency is high (environmental).** `infer:true` adds measured
  **15–66s each** — the 35B extraction plus, on the variance pattern,
  likely **model-swap reloads** between the embedder and chat models on
  the llama-swap server (the embed calls are instant). A dedicated
  always-resident GPU chat model would cut this to a few seconds. mem0's
  design pays one LLM round-trip per write inherently — relevant to rubric
  #11 (bounded write latency / no multi-minute hang on quit).
- **Extraction & resolution — good, and confirms the append-only model
  live.** `add` extracted clean facts and is **strictly ADD-only** even
  for direct contradiction ("loves steak" → "vegetarian": both kept,
  events `[ADD, ADD]`, the new memory phrased as a *transition*
  referencing the old) and negation ("loves horror" → "was joking": both
  kept). Coexistence (steak + sushi) correctly kept both (3/3). This is
  exactly the design's append-only + read-time-resolution shape — but it
  **relocates "supersede quality" to the read side**, which the top-k bug
  currently defeats: if recall returns the farthest memories, synthesis
  never sees the correcting one.
- **Harness lesson (kept because the false trail is instructive).** The
  first pass mis-scored ranking 0/5 and chased a false "embeddings broken
  / need prefixes" hypothesis; the real cause was reading the result list
  from the wrong end (best match is *last*, per the inversion above). The
  diagnostic — dump raw ranked scores + compute direct cosine — corrected
  it. Lesson: *dump raw ranked scores before blaming the embedder.*

**Status:** the models (nomic embed + Qwen3.6 extraction) perform well;
the blocker is the pgvector top-k inversion. Next: root-cause it —
(1) inspect mem0's pgvector distance-metric config / known issues, and
(2) re-run the ranking against a **Qdrant** backend to see if nearest-k
returns correctly. That decides "mem0 is broken" vs "pgvector-in-this-
stack is misconfigured." (The throwaway smoke stack is currently still up
for the hunt.)
