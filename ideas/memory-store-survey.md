# Memory-store survey (point-in-time, 2026-05-31)

Archived result of a one-shot research pass surveying open-source
"agent memory" stores against the [`memory.md`](memory.md) §"Property
checklist". Scope: a single **local, private, no-egress, no-untrusted-
ingest** personal-assistant memory (the `@private` agent of
[`assistant.md`](assistant.md)). Security/poisoning hardening was *not*
scored — it's out of scope for `@private` by construction.

This is a snapshot, not a living doc. Several projects move fast;
treat licenses/behaviors as "true around May 2026, verify before
depending." `?`/`~` cells were genuinely undocumented in the primary
source read, not inferred.

## Candidate profiles

| Store | License | Self-host / local | Embedding dep | One-liner |
|---|---|---|---|---|
| **honcho** | AGPL-3.0 | Yes (Docker + managed) | Local-capable | Background "deriver" synthesizes a user persona server-side. |
| **mem0** | Apache-2.0 | Yes (OSS server) | Local OK / OpenAI default | Fact-extraction layer; 2026 algo went **ADD-only** (history-preserving). |
| **supermemory** | **Contested** (README MIT/air-gapped vs secondary "closed/enterprise") | Cloud-first | Provider-hosted | Benchmark-topping managed API; OSS ≈ app shell, not auditable engine. |
| **byterover** | Elastic 2.0 (non-OSI) | Local CLI + cloud sync | Undocumented | Coding-agent memory; **manual** `/curate`, not autonomous capture. |
| **hindsight** | MIT | Yes (Docker + embedded Postgres) | Local OK (Ollama/LM Studio) | Retain/Recall/Reflect over facts/experiences/entities/**beliefs**; benchmark SOTA. |
| **holographic / nuggets** | nuggets MIT; plugin license unstated | **Local-only, SQLite** | **None** (HRR vectors + FTS5) | The only fully self-contained, no-provider option. |
| **retaindb** | Apache (local) + BSL-1.1 (server) | Yes (`~/.retaindb/` journal) | Local transformer (optional) | Explicit `validFrom/validUntil`, reinforcement, typed `contradicts/updates/supports`. |
| **openviking** | AGPLv3 + Apache (CLI) | Yes | Local provider option | Filesystem-paradigm context DB; L0/L1/L2 tiers, human-readable, session-end async extract. |
| **file/markdown** (baseline) | your code | Fully local, zero-dep | None | Human-readable; **no mechanics** — you build everything. |

## Property matrix

✓ supported · ~ partial · ✗ no · ? unknown. Properties are
[`memory.md`](memory.md) §"Property checklist" 1–11.

| # | honcho | mem0 | supermem | byterover | hindsight | holographic | retaindb | openviking | file |
|---|---|---|---|---|---|---|---|---|---|
| 1 auto-append | ✓ | ✓ | ✓ | ✗ | ✓ | ~ | ~ | ✓ | ✗ |
| 2 supersede-by-append | ~ | ✓ | ~ | ~ | ✓ | ~ | ✓ | ~ | ~ |
| 3 physical erase | ? | ~ | ~ | ? | ? | ✓ | ✓ | ? | ✓ |
| 4 contradiction vs coexist | ~ | ~ | ✓ | ✗ | ✓ | ✓ | ✓ | ~ | ✗ |
| 5 weighted + pinning | ~ | ~ | ~ | ✗ | ~ | ✓ | ✓ | ~ | ✗ |
| 6 time-decay | ? | ~ | ✓ | ✗ | ~ | ✗ | ~ | ✗ | ✗ |
| 7 entity/attr structure | ✓ | ✓ | ✓ | ~ | ✓ | ~ | ~ | ✓ | ✗ |
| 8 layering | ✓ | ✗ | ✓ | ~ | ~ | ✗ | ~ | ✓ | ~ |
| 9 cheap regen / inspect | ~ | ~ | ✗ | ✓ | ~ | ✓ | ✓ | ✓ | ✓ |
| 10 auditable dump / local | ~ | ✓ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| 11 bounded write latency | ✓ | ~ | ✓ | ? | ✓ | ~ | ~ | ✓ | ✓ |

## Question A — can the DB own extraction (no memory-LLM in *our* loop)?

- **honcho** — yes, end-to-end (its deriver owns the loop; you only configure its model). Strongest "DB owns it."
- **supermemory** — yes (claimed), but cloud/closed → fails the privacy gate, moot.
- **openviking** — mostly; owns the loop but you must configure a VLM provider.
- **mem0 / hindsight / retaindb** — partial: they own the extraction *logic* but the integrator supplies the LLM (hindsight/retaindb can point at a *local* model — Ollama/LM Studio — which reuses pikuri's local-llama posture).
- **byterover** — no (manual `/curate`).
- **holographic / nuggets** — the **only purely-algorithmic, no-LLM-at-all** path: HRR cosine + FTS5 + access-count promotion + trust feedback, ~1ms recall, zero model calls. Weak exactly where language understanding is needed (genuine contradiction-vs-coexistence, free-text extraction).

## Question B — negative space (the load-bearing finding)

Three properties the field broadly omits, for **two different reasons**:

- **#6 gradual time-decay — genuinely hard, everyone punts.** What
  exists is binary expiry (supermemory, retaindb `validUntil`) or
  generic temporal retrieval, not a decay curve. Mis-decaying a real
  preference is asymmetrically worse than keeping a stale fact, so the
  field keeps everything and ranks by recency **at read time**. → *Do
  not build write-time decay; use reversible read-time recency
  weighting.* (This is the one finding that course-corrected the design.)
- **#3 physical right-to-forget & #5 explicit-correction pinning —
  omitted because the field isn't privacy-first.** The market optimizes
  for *never losing signal* (mem0 v3 is explicitly history-preserving;
  most "forget" = expiry/deactivation, not destruction). Pinning a
  correction so weak later signals can't override it is shipped by no
  one. → *Not a wrong-direction signal — these are pikuri's
  differentiators, built in-house. Deferred to v2.*

## Convergence signal

**mem0 (37k★, the most-adopted store) moved to ADD-only /
history-preserving in April 2026** — independently the same
"supersede-by-append, resolve current-truth downstream, never mutate"
shape reasoned to in [`memory.md`](memory.md). Field leader converging
on it = the shape is load-bearing.

## Recommendation

Two finalists survive the privacy gate, at opposite ends of one axis:

- **holographic / nuggets** — local-only, zero/low dep, **no
  integrator-managed LLM**, real deletion, repetition+feedback
  weighting, fully inspectable. Best fit for "audit in an evening."
  *Weak on semantic contradiction resolution + free-text extraction.*
- **hindsight** — MIT, embedded-local Postgres, runs against local
  Ollama/llama.cpp, beliefs/supersede + entity resolution, benchmark
  SOTA. *Costs a managed local extraction model.*

The axis is **no-LLM-simple vs local-LLM-capable**, and it is decided
by the observation-granularity fork (free-text ⇒ need an LLM ⇒
hindsight; structured entity/attr/value ⇒ more resolution becomes
algorithmic ⇒ nuggets viable). honcho is the best "DB owns extraction"
answer but AGPL + opaque resolved-view + weak deletion make it a worse
fit for an auditable right-to-forget store. supermemory (cloud/closed)
and byterover (manual) are eliminated.

**Biggest gap we build ourselves regardless of pick:** correction-
pinning (#5) + physical right-to-forget (#3) — both core to a private
persona, shipped by nobody. (Deferred to v2 per the design note.)
