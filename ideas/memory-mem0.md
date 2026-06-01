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
smoke-tested working. The recall-quality pass found the *models* perform
well but surfaced a **pgvector top-k inversion** (cosine *distance* sorted
as if it were a *similarity*) — root-caused to mem0's pgvector provider
and **confirmed fixed by switching to Qdrant** (nearest-k correct, 5/5).
**Qdrant is the chosen v1 backend.** Recall quality on Qdrant is good;
contradiction-resolution is *not* in mem0's recall (it returns both facts
near-tied, no recency ordering) — it belongs in the consumer's synthesis
step, a `pikuri-memory` design input.

**Update (2026-06-01):** the last open item, **write latency**, is
root-caused — *not* model-swap reloads (the llama.cpp router holds all
models resident at 48GB under both interleave and idle) but **Qwen3.6's
reasoning mode**: thinking-on burns the token budget on CoT and can return
empty/truncated JSON (a non-deterministic correctness cliff, not just slow);
`enable_thinking:false` is ~6× faster and reliable. mem0 **can't forward
that flag via config** (source-confirmed), so the chosen fix is a **~3-line
build-time patch** injecting `extra_body.chat_template_kwargs` (Q2), reusing
the existing 35B at zero extra VRAM; a dedicated non-reasoning small model
(Q1) and a pikuri proxy shim (Q3) are fallbacks. Two upstream mem0 tickets
queued (pgvector top-k inversion; LLM `extra_body` passthrough). See
§"Write-latency root cause" and §"How to disable thinking for mem0".

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

### Root cause (2026-05-31): pgvector distance treated as similarity — Qdrant is the fix

The top-k inversion is a genuine mem0 2.0.4 bug — a distance-vs-similarity
convention mismatch between the ranker and the pgvector provider:

- mem0's hybrid ranker `score_and_rank` (`mem0/utils/scoring.py:60`)
  assumes the vector store's `score` is a **similarity** (higher = more
  relevant): it gates `if semantic_score < threshold: continue`, combines
  additively (`semantic + bm25 + entity`), then sorts `reverse=True`
  (descending) and takes the top (`scoring.py:120`).
- But mem0's **pgvector provider** (`mem0/vector_stores/pgvector.py:327,
  337`) returns a raw **cosine distance** (`vector <=> query AS distance`)
  and never converts it — lower = more relevant, the opposite convention.
- Net: sorting a *distance* descending surfaces the **farthest** memory
  first. `top_k=3` returns the three *least* relevant and omits the
  obvious answer; `top_k=8` returns all, ordered worst→best. (Latent
  second bug: the `< threshold` gate wrongly drops any memory *closer*
  than distance 0.1.)

**It's backend-specific, and that's the fix.** Qdrant's provider
(`mem0/vector_stores/qdrant.py`) passes through Qdrant's native
`ScoredPoint.score`, which *is* a similarity (higher = better) — so
`score_and_rank`'s descending sort is correct there. The fault is the
pgvector provider failing to convert distance→similarity, not the ranker.
Any pgvector user of this version's v1.1 hybrid search is affected.

Consequences:

- **Resolves the open "pick the vector store" item → Qdrant, not
  pgvector.** pgvector was the lean only because the *server's shipped
  compose* defaults to it; the *library* default is Qdrant, whose path is
  correct by construction. Qdrant is independently the better fit anyway —
  popular, actively maintained, OSS, purpose-built vector DB (vs. a
  Postgres extension), and a clean Docker sidecar like the rest of our
  infra.
- The models and our wiring are vindicated — the blocker was entirely
  mem0's pgvector provider.
- Worth an upstream report/PR (convert `<=>` distance to `1 - distance` in
  the pgvector provider, or normalize per-store inside `score_and_rank`).

### Qdrant confirmation (2026-05-31): nearest-k correct, 3/3 — decision locked

Drove the mem0 **library** directly (same `score_and_rank` + provider code
as the server, so it exercises the exact buggy path) against a fresh
Qdrant container — same 8 facts, `infer:false`, `top_k=3`:

- **rank-1 correct 3/3.** "Where does the user live?" → Brno #0;
  "programming language" → Ruby #0; "boss" → Alice #0. Results sorted
  nearest-first.
- **`score` is a similarity here** (Brno 0.7832, higher = better) and the
  values *match the standalone llama cosine* (Brno 0.7832, Ruby 0.7636 —
  identical to the Part-2 diagnostic), proving Qdrant returns raw cosine
  similarity and `score_and_rank`'s descending sort is correct against it.

Same models, same wiring, same ranker — only the backend changed. That
nails it: **pgvector path broken, Qdrant path correct. Qdrant is the v1
backend** — and the better fit on its own merits (popular, OSS,
maintained, purpose-built, clean Docker sidecar).

Caveat seen in passing: the server image ships **without spaCy/fastembed**,
so BM25 keyword search is disabled and search is semantic-only (true for
both backends here — the bug is purely in the semantic→`score_and_rank`
path). Fine for v1; revisit hybrid keyword recall later
(`pip install mem0ai[nlp]` + fastembed) if wanted.

### Supersede recall on Qdrant (2026-05-31): recall works; resolution is the consumer's job

Re-ran the **full** suite on Qdrant (library path = server path). A2
ranking flipped **0/5 → 5/5** (recall correct); A1 paraphrase wins clearly
(0.78 similarity). The C-trio (`infer:true`, 3 runs) now checks whether
the *correcting* memory outranks the *stale* one at search time:

- **C2 coexistence: 3/3.** Both "steak" (~0.73) and "sushi" (~0.67) kept
  and recalled — no false supersession, no over-merging.
- **C1 supersede 1/3, C3 negation 1/3 — but the verdict misleads; the
  scores are the finding.** Every run kept *both* memories (ADD-only) and
  *both* surfaced in the top-2, scored within **~0.001–0.05** of each
  other (C3: "loves horror" **0.8049** vs "was joking… can't stand"
  0.7589). Which lands at #0 is essentially noise — and the *stale*
  positive often edges out the correction, because a short bare statement
  ("loves horror movies") is a tighter semantic match to the query than
  the wordy retraction.

The load-bearing conclusion:

- **mem0 recall does not resolve contradictions — it returns both,
  near-tied, with no recency term in the ranking** (BM25 also off here, no
  spaCy/fastembed). "Newest wins" is *not* applied at read time.
- This **matches the design** (§"v1 write API": resolution lives at
  read-time/synthesis, i.e. in the *consuming LLM*). mem0's job —
  surfacing the relevant memories — works: the correction is always in the
  recalled slice, and mem0 phrases corrections as **transitions**
  ("switched from steak to vegetarian", "was joking about horror") that a
  synthesis step can resolve.
- **`pikuri-memory` design input:** do **not** treat recall rank-0 as
  current truth. Recall hands the agent the conflicting pair; the
  synthesis / system-prompt step resolves it — so the recalled context
  must carry **timestamps** (+ the transition-phrased corrections mem0
  emits). Confirms the rubric line "recency at read does the *ordering*,
  not the *resolution*" — except mem0 does not even do the recency
  *ordering*; the consumer must.

**Net:** recall quality on Qdrant is good and coexistence is safe;
contradiction-resolution is not in mem0's recall and never was — it's a
`pikuri-memory` synthesis concern, not a mem0 defect.

Still open (quality, not feasibility): **write latency** (15–66s/add,
mostly llama-swap model reloads — environmental, not mem0's architecture).
*(Resolved below — the cause was not model reloads but Qwen3.6's reasoning
mode; see §"Write-latency root cause".)*

### Write-latency root cause (2026-06-01): reasoning tokens, not model swaps

Tested the "llama-server unloads models between writes" hypothesis directly
against the live router (`http://192.168.122.1:8080`, VRAM raised to 48GB).
The server is llama.cpp's **router** (`role:"router"`, `max_instances:4`),
not llama-swap; three models registered (Qwen3.6-35B-A3B chat, nomic embed,
bge reranker). **Hypothesis refuted on both axes:**

- **Active interleave.** Embed↔chat 4× (mem0's write shape): once loaded,
  both the embedder and the 35B chat model stay `loaded` throughout — no
  eviction, no reloads. Cold chat load is ~11s; warm calls drop to ~1s.
- **Idle.** 5 min with zero traffic: both models stay `loaded` the whole
  time. No idle-timeout eviction. At 48GB with 3 models under
  `max_instances:4`, nothing ever needs to be swapped out.

The real driver is **generation cost on a reasoning model**, not swapping.
Qwen3.6-35B-A3B is a thinking model: a warm extraction-style call spent its
*entire* token budget on `reasoning_content` and emitted empty `content`.
The MoE runs ~21 tok/s, and mem0 makes up to 2 LLM calls per `add` — so
hundreds of CoT tokens × 2 calls fully accounts for the 15–66s range with
no model swap involved.

**The lever is disabling thinking, not VRAM/keep-alive.** Same extraction
prompt, `max_tokens:512`:

| mode | latency | completion tokens | output |
| --- | --- | --- | --- |
| thinking ON (default) | **23.9s** | 512 (all reasoning) | `finish:length`, **empty** — never reached an answer |
| `enable_thinking:false` | **4.2s** | 87 | `finish:stop`, clean correct JSON (all 9 facts) |

`chat_template_kwargs:{enable_thinking:false}` is honored by llama.cpp and
gives ~6× on a single call (and actually *produces* the answer; thinking-on
didn't finish within 512 tokens). Recall quality was already "good" with
this model — so this is a **mode** fix, not a model swap: keep Qwen3.6 for
extraction, turn thinking off.

**`pikuri-memory` design input.** The open item is now a mem0-config
question, not an environmental one: can mem0 be made to pass
`enable_thinking:false` (or a `/no_think` directive) through to llama.cpp on
its extraction/update calls? If mem0 won't forward `chat_template_kwargs`,
the fallback is a dedicated non-reasoning extraction model (e.g. a dense
Qwen3-8B no-think / Llama-3.1-8B-Instruct as a 4th router instance — fits
easily within `max_instances:4` and 48GB), decoupling the memory-extraction
model from the chat model. Lever 1 (thinking off, same model) is preferred:
it preserves the already-validated extraction quality and adds no infra.
*(The "can mem0 forward the flag?" question is answered below — it can't;
the decision section picks how to force no-think anyway.)*

### How to disable thinking for mem0: decision (2026-06-01) — build-time patch (Q2)

First, the blocking finding. **mem0 cannot forward `chat_template_kwargs`
(or any `extra_body`) through its config — source-confirmed** against
`mem0/llms/openai.py` + `mem0/llms/base.py` + the config classes on `main`:

- The request body is built by `_get_common_params()` → exactly
  `{temperature, max_tokens, top_p}` + `model` + `messages`
  (+ `response_format`/`tools`/`store` when set). **No `extra_body`, no
  arbitrary-field passthrough anywhere.**
- `BaseLlmConfig`/`OpenAIConfig` are a **fixed field schema** — nowhere to
  stash `chat_template_kwargs`. `generate_response(**kwargs)` looks like a
  passthrough but isn't wired from config, and the OpenAI SDK's `create()`
  rejects an unknown top-level `chat_template_kwargs` unless wrapped in
  `extra_body` (which mem0 never does).
- The one reasoning knob, `reasoning_effort`, is emitted *only* for
  hardcoded OpenAI models (`o1/o3/gpt-5`); Qwen3.6 is treated as a "regular"
  model so it's never sent — and it's the wrong knob anyway (effort level,
  not on/off).

So per-request no-think via mem0 config is impossible without intervention.
Also note `/no_think` as a *prompt* soft-switch is **unreliable** on this
Unsloth Qwen3.6 GGUF (tested: a `/no_think` system prompt still burned ~330
reasoning tokens and a re-run came back empty; only the structured
`chat_template_kwargs` flag suppresses thinking deterministically) — so
patching mem0's prompts is not a trustworthy route either.

That leaves a **trilemma — pick where the complexity lives:**

| Option | Complexity home | Extra VRAM | Reuses 35B? | Touches mem0? | New service? |
| --- | --- | --- | --- | --- | --- |
| **Patch (Q2)** | mem0 code (pinned patch) | none | ✅ | yes (~3 lines) | no |
| **Small model (Q1)** | a new model | ~+5GB | no | no | no |
| **Proxy shim (Q3)** | a new network service | none | ✅ | no | yes (pikuri HTTP) |

**Decision: Q2 — patch the one mem0 file at docker build time.** It ships
fastest, reuses the existing Qwen3.6-35B-A3B instance at **zero extra VRAM**
(thinking is per-request, so one loaded instance serves pikuri-chat/code
*with* thinking and mem0's patched calls *without* it), and touches only the
write path (embeddings go through a different provider; search is
pure-vector). The patch is ~3 lines in `OpenAILLM.generate_response`,
injecting before `client.chat.completions.create(**params)`:

```python
params["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}
```

Apply it as a **version-pinned `.patch` via `git apply`** in the
pikuri-memory supervisor's Dockerfile (pin mem0 to the tracked ref;
*not* `sed` — fail loud if upstream drifts). It's a fork-by-patch, but a
minimal, auditable one visible in the build — consistent with "small enough
to read in an evening."

**Q1 and Q3 stay as solid fallbacks if Q2 bites** (none burns the others):

- **Q1 — dedicated non-reasoning small model for mem0.** The task is
  closed-context and knowledge-free (transcript + existing memories are all
  in the prompt), so a small model is plausible; the deciding axis is
  **non-reasoning + reliable JSON, not parameter count**. Default 7–8B
  (Qwen2.5-7B-Instruct, Llama-3.1-8B-Instruct, Gemma-2-9B-it); a 3B
  (Qwen2.5-3B-Instruct, Llama-3.2-3B-Instruct) is worth a bake-off since
  3B→8B costs only ~2–3GB. **Must be genuinely non-reasoning** — a small
  Qwen3/Qwen3.6 is a *hybrid* that thinks by default and reproduces the
  cliff. Extraction is trivial for a 3B; the ADD/UPDATE *consolidation*
  judgment is the risk, but it's largely inert here (this stack is
  effectively ADD-only, resolution deferred to read-time). Benchmark
  candidates on mem0's actual two prompts (latency + JSON validity +
  extraction quality) before picking.
- **Q3 — proxy shim that routes mem0's LLM traffic through pikuri.** Worth
  it only if "pikuri owns mem0's model routing + egress/observability" is
  wanted *for its own sake* (centralizes config to one endpoint; single
  egress chokepoint, fits the privacy stance). The no-think injection then
  comes free. Cost: makes pikuri an **HTTP server** (it's currently
  library + CLI) and adds a failure point on the write path. Natural later
  upgrade for pikuri-assistant's central-egress story, not a v1 no-think
  fix.

**TODO — open two upstream tickets against mem0:**

1. **pgvector distance-vs-similarity bug (the top-k inversion).** The
   pgvector provider (`mem0/vector_stores/pgvector.py`) returns a raw cosine
   *distance* (`vector <=> query AS distance`) but the hybrid ranker
   `score_and_rank` (`mem0/utils/scoring.py`) treats `score` as a
   *similarity* — gates `< threshold`, sums additively, sorts `reverse=True`
   — so `top_k` returns the **farthest** k. Fix: convert distance→similarity
   (`1 - distance`) in the pgvector provider, or normalize per-store inside
   `score_and_rank`. (Latent second bug: the `< threshold` gate wrongly
   drops memories *closer* than the threshold.) Root-caused above in
   §"Root cause … Qdrant is the fix".
2. **LLM kwargs / `extra_body` passthrough.** `BaseLlmConfig`/`OpenAIConfig`
   have a fixed schema and `_get_common_params` only forwards
   `temperature/max_tokens/top_p`, so there is **no way to pass
   provider-specific body params** (e.g. `chat_template_kwargs`) to an
   OpenAI-compatible backend. This makes it impossible to tell a hybrid
   *reasoning* model (Qwen3/Qwen3.6, etc.) `enable_thinking:false` via
   config, forcing downstream forks/patches (this note's Q2). Ask: add an
   `extra_body`/passthrough config field on the OpenAI provider so reasoning
   models can be configured without patching.

### Patch verified live (2026-06-01): Q2 works end-to-end

Built a patched mem0 **2.0.4** image (pip install + build-time injection) and
ran a real `add()` against the live llama-server (chat routed through a
logging proxy) + a throwaway Qdrant. **Q2 is validated:**

- **Patch applies fail-loud at build.** The patcher locates
  `self.client.chat.completions.create(` and inserts
  `params["extra_body"] = {"chat_template_kwargs": {"enable_thinking": False}}`
  before it; prints `PATCH OK` or `exit 1` if the call moved. Applied cleanly
  to 2.0.4 (confirms the tracked version; the exact call exists in the
  release, not just `main`).
- **The flag reaches llama.cpp on the wire.** The proxy captured top-level
  `"chat_template_kwargs":{"enable_thinking":false}` — the OpenAI SDK flattens
  `extra_body` into the JSON body, which is what llama.cpp reads.
- **Covers *both* mem0 LLM paths.** The warm re-run (store already populated)
  made 2 chat calls — fact-extraction *and* the update-decision — and **both**
  carried `enable_thinking=false`. One patch point, both paths (both route
  through `generate_response`).
- **Latency confirms the thesis.** Cold first add: 32.6s (one-time model
  load); warm add: **2.8s**; warm single chat call: 2.1s — vs 15–66s with
  thinking on. At 48GB the model stays resident, so steady state ≈3s/add.
- **Quality clean.** Extracted "name is Martin / lives in Brno", "writes Ruby
  / manager Alice", "is vegetarian"; the warm re-run correctly NOOP'd
  (`results: []`, no duplicate ADD).

Net: the locate-and-insert / fail-loud patcher is a good template for the
real `pikuri-memory` supervisor — though production should `git apply` a
`.patch` against the pinned source, not patch a pip install. Throwaway stack
(proxy, Qdrant container, image) torn down.
