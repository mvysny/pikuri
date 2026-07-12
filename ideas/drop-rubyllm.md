# Dropping ruby_llm for a hand-rolled OpenAI-compatible client

Status: **considered, not decided — deliberately parked.** This note
exists to get the "nuke ruby_llm" argument *out of the way* so it stops
contaminating bug-fix decisions. Nothing here is scheduled. The
decision criteria at the bottom are the live part; revisit only when one
of them actually trips.

Origin: the streaming error-parse crash of 2026-07 (`TypeError: String
does not have #dig` in `ruby_llm/providers/openai/streaming.rb:43`,
`parse_streaming_error` assuming a Hash body — a non-200 whose body is a
bare JSON string mentioning "error", the Grok-in-Europe case). That bug
is being fixed on its own track (upstream
[ruby_llm#837](https://github.com/crmne/ruby_llm/issues/837) + a local
monkeypatch in `pikuri-core/lib/pikuri/ruby_llm_patches.rb`); it is *not*
justification to drop ruby_llm. It is only what prompted
writing this down. See `ideas/typed-transports.md` for the adjacent
"where does the transport abstraction live" question (that note already
argues the privacy-classification concept ends up *above* ruby_llm).

Related:

- [`typed-transports.md`](typed-transports.md) — the transport
  abstraction pikuri owns *on top of* ruby_llm today; a rip-out would
  absorb it rather than sit above it.
- CLAUDE.md **Loop seam** / **Connection seam** / **Value-type
  passthrough** — the three invariants a rip-out touches. This note is
  the "what if those seams stopped fronting ruby_llm" thought
  experiment.

---

## The premise that makes this even thinkable

We have only ever used the **OpenAI API** — specifically the
OpenAI-compatible `/v1/chat/completions` shape, against a local
llama.cpp server by default and the occasional cloud provider. There is
**no foreseeable need for a second provider family** (no Anthropic
Messages API, no Gemini, no Bedrock signing). ruby_llm's core selling
point is multi-provider breadth; we use ~none of that breadth. That is
the whole reason this is a real question and not a non-starter — see
CLAUDE.md "Out of scope" (multi-provider config is already declared out
of scope) and the "small enough to audit in an evening" value.

## What we actually use (measured, not guessed)

`grep -rnoE "RubyLLM(::…)*" pikuri-*/lib pikuri-*/bin`, deduped by
symbol — the real surface, not the imagined one:

| Symbol | hits | what it does for us |
|---|---|---|
| `RubyLLM::Context` | 14 | per-agent connection isolation (**Connection seam**) — `build_context` maps `transport.api_base`/`api_key` onto a per-chat context so agents/sub-agents can't stomp a global |
| `RubyLLM::Tool` | 12 | the base class our `Pikuri::Tool` adapter subclasses |
| `RubyLLM::Chat` | 12 | `#complete`, `#add_message`, `#messages`, callbacks (**Loop seam**) |
| `RubyLLM::ContextLengthExceededError` | 11 | context-overflow detection we branch on |
| `RubyLLM::Message` | 10 | value type (**value-type passthrough**) |
| `RubyLLM::Content` | 10 | value type (multimodal content parts) |
| `RubyLLM::Chunk` | 6 | streaming delta value type |
| `RubyLLM::ModelNotFoundError` | 2 | error branch |
| `RubyLLM::Model::Info` | 1 | model metadata |
| `RubyLLM::Attachment` | 1 | multimodal attachment |

So the load-bearing pieces are: **the SSE streaming parser + provider
error taxonomy**, **the `Chat#complete` loop + tool-call dispatch**, the
**value types** (`Message`/`Content`/`Chunk`/`Attachment`), **context
isolation** (`Context`), and **context-length detection**.

## For dropping

- **Single provider.** We'd reimplement exactly one transport:
  `POST /v1/chat/completions`, SSE parse, `tool_calls`, `usage`. A few
  hundred lines over Faraday, which we already own — no ruby_llm
  breadth wasted.
- **Audit surface shrinks.** ruby_llm pulls its own dependency subtree
  and provider zoo; a hand-rolled client is code a user can read
  end-to-end (a stated CLAUDE.md value). The bug that started this is a
  case in point — it lives in a provider path we don't even exercise
  the general form of.
- **Tool-call impedance goes away.** CLAUDE.md already admits pikuri
  *"hacks tool calls into their API."* Owning the request/response
  shape means the tool protocol is ours, not something we bend
  ruby_llm's model into.
- **The bugs we'd inherit are shallow.** The SSE + error-taxonomy code
  is where the defects live (see origin). If we own it we fix it in one
  place on our schedule, instead of monkeypatching around a release
  cadence.

## Against dropping

- **Three seams move at once.** Loop, Connection, and value-type
  passthrough are all *designed around* ruby_llm's shapes. A rip-out is
  not a swap — it re-opens three load-bearing invariants
  simultaneously. High blast radius for a stack that's otherwise
  stable.
- **We'd own the fiddly part.** Robust SSE framing, partial-chunk
  buffering, the `[DONE]` sentinel, `event: error` vs inline-JSON-error
  vs failed-response bodies, usage accounting across providers,
  reasoning/thinking deltas — this is exactly the surface that just
  bit us. Reimplementing it means we own that class of bug forever
  instead of once.
- **Context-length detection is unglamorous but real.** ruby_llm ships
  a curated regex set (`CONTEXT_LENGTH_PATTERNS`) mapping provider
  prose to `ContextLengthExceededError`. We'd have to carry and
  maintain our own.
- **Model metadata / registry.** `Model::Info`, capability flags,
  pricing — small use today, but re-deriving it is toil with no
  feature payoff.
- **Streaming reasoning + multimodal.** `Chunk.thinking`, `Attachment`,
  `Content` parts — all handled today; all things we'd re-handle.
- **A two-line bug is a terrible reason to move.** Letting this defect
  drive an architecture decision is the tail wagging the dog. The bug
  has a cheap fix on its own track.

## The honest middle

If we ever did this, the smart scope is **not** "replace ruby_llm
wholesale" but "own the OpenAI transport, keep the value-type vocabulary
compatible." Concretely: a `Pikuri`-owned `POST /v1/chat/completions`
client + SSE parser feeding *our own* `Data.define` message/chunk types,
with the `Pikuri::Tool` adapter targeting our types instead of
`RubyLLM::Tool`. The Connection seam already isolates per-agent
transport, so its public shape (`ChatTransport`) could survive the
swap unchanged — the seam is the insulation that would make this
tractable if we chose it.

That still leaves context-length detection and model metadata as things
we consciously either port or drop.

## The fourth option: adopt a dedicated OpenAI client instead of hand-rolling

"The honest middle" says *own the OpenAI transport*. That doesn't have to
mean *hand-roll the SSE parser from scratch* — the fiddly part under
"Against dropping." There is a middle-of-the-middle: swap ruby_llm's
multi-provider machinery for a **single-provider OpenAI client**, keeping
someone else's battle-tested SSE framing and multipart handling and
owning only the loop + tool-call dispatch + value types on top. Two real
candidates plus the incumbent (numbers measured 2026-07-12):

| | official `openai` | `ruby-openai` | `ruby_llm` (today) |
|---|---|---|---|
| Author | OpenAI (Stainless-generated) | Alex Rudall (community) | Carmine Paolino |
| First release | 2025 | 2020 | 2025 |
| Latest | 0.69.0 (2026-07-09) | 8.3.0 (2025-08-29) | 1.16.0 (2026-06-09) |
| Total downloads | 1.47M | 43.6M | 10.3M |
| GitHub stars | 439 | 3,222 | 4,237 |
| Last push | 2026-07-09 | 2026-05-01 | 2026-07-07 |
| License | Apache-2.0 | MIT | MIT |
| Direct runtime deps | `base64`, `cgi`, `connection_pool` | `event_stream_parser`, `faraday`, `faraday-multipart` | 9 (`faraday`×4 + `marcel` + `zeitwerk` + `ruby_llm-schema` + `base64` + `event_stream_parser`) |
| HTTP stack | `net/http` (own) | Faraday | Faraday |
| Scope | full OpenAI API, generated | OpenAI API, hand-written | all major providers |

### Maturity

- **`ruby-openai`** is the oldest and most established (2020, five-plus
  years, 8.x line). But it is visibly *slowing*: last gem release
  2025-08, last repo push 2026-05. For a **frozen** surface —
  `/v1/chat/completions` barely changes — "done and quiet" is arguably a
  feature, not decay. The risk is the day OpenAI ships a
  chat-completions knob we need and nobody's home.
- **official `openai`** is young (2025) and still `0.x` — nominally
  unstable public API, 87 versions in ~16 months. But it is
  **Stainless-generated and vendor-backed**, so it tracks new API
  features (Responses API, structured outputs) fastest and won't be
  abandoned. The flip side is exactly why it's a poor fit here (below).
- **`ruby_llm`** is the most actively developed of the three and the
  only one being pushed weekly — but its churn is *multi-provider*
  churn, i.e. movement in surface we don't use, which is where our bugs
  have come from.

### Popularity

Two different signals disagree. By **downloads** `ruby-openai` dwarfs
everything (43.6M — it *is* the Ruby-meets-OpenAI default, and much of
that is transitive/legacy). By **stars** `ruby_llm` (4.2k) edges out
`ruby-openai` (3.2k) with the official gem a distant third (439) — but
generated SDKs always under-star, so 439 understates real use (1.47M
downloads and climbing). Read together: `ruby-openai` is the safe,
widely-deployed choice; `ruby_llm` has the momentum; the official gem
has the vendor but not yet the ecosystem.

### Dependencies (the axis that actually moves our audit surface)

Raw direct-dep counts (3 / 3 / 9) mislead. What matters is **net-new to
pikuri-core's audit tree**, which already ships Faraday + Zeitwerk +
`base64`:

- **`ruby-openai`** is the cheapest by this measure. `faraday` and
  `base64` are already ours; `zeitwerk` is already ours; net-new is
  `event_stream_parser` (one file, zero deps — *the same SSE parser
  ruby_llm itself uses*) plus `faraday-multipart`. It also **reuses our
  Faraday stack**, so there's one HTTP client in the process, not two.
- **`ruby_llm`** adds `marcel`, `ruby_llm-schema`, and `faraday-retry`
  on top of that — the pieces a lean OpenAI-only client doesn't need.
  (Not `faraday-net_http`: that's a dependency of `faraday` itself —
  faraday 2.14 requires `faraday-net_http >= 2.0` as its default
  adapter — so it's already in the tree via our own Faraday and stays
  regardless of ruby_llm.)
- **official `openai`** looks lean (`base64`/`cgi` are default gems,
  `connection_pool` is tiny) but the count lies in the *opposite*
  direction: it **doesn't use Faraday** — it hand-rolls `net/http`
  inside a **large machine-generated SDK** (the whole OpenAI API surface
  as generated Ruby). So it (a) adds a *second* HTTP path to a process
  that already speaks Faraday everywhere, and (b) is code you cannot
  "read end-to-end in an evening" even though the *dependency* line is
  short. Generated breadth is exactly the thing the audit-first value
  rejects — it's ruby_llm's multi-provider problem in a different suit.

**The `ruby_llm` → `ruby-openai` swap, gem by gem** (ruby_llm's 9
runtime deps, measured 2026-07-12). Net result: **−3 gems**, and the one
gem we *add* (`ruby-openai`) is small hand-written Ruby replacing the
large multi-provider `ruby_llm`.

| ruby_llm runtime dep | Fate after swap | Why |
|---|---|---|
| `marcel` | **removed** | MIME sniffing; ruby_llm-only, no other consumer in the tree |
| `ruby_llm-schema` | **removed** | ruby_llm-only |
| `faraday-retry` | **removed** | ruby_llm-only; `ruby-openai` doesn't depend on it |
| `event_stream_parser` | stays | `ruby-openai` needs it too — *the same SSE parser*, net-neutral |
| `faraday-multipart` | stays | moves from ruby_llm to `ruby-openai` |
| `faraday` | stays | pikuri's own direct dep (23 files) + `ruby-openai` |
| `faraday-net_http` | stays | pulled by `faraday` itself, not by ruby_llm |
| `zeitwerk` | stays | pikuri's own direct dep (13 files) |
| `base64` | stays | pikuri uses it directly (3 files); a default gem regardless |

So the three gems that genuinely leave the audit tree are `marcel`,
`ruby_llm-schema`, and `faraday-retry` — plus `ruby_llm` itself, swapped
for `ruby-openai`. Everything `ruby-openai` "brings"
(`event_stream_parser`, `faraday`, `faraday-multipart`) is already
present, so the transitive surface only *shrinks*.

### Reading

For pikuri's stated posture — single provider, audit-first, already
Faraday-native — **`ruby-openai` is the strongest fit of the three, and
a better target than a from-scratch hand-roll.** It hands us the SSE +
multipart machinery (the surface that bit us), reuses the HTTP stack we
already audit, adds essentially two tiny gems, and is small readable
hand-written Ruby rather than generated bulk. We'd still own the loop,
tool-call dispatch, value types, and — note — the streaming
**error-body** parsing that started this whole note (`ruby-openai` hands
raw chunks to a block; the "is the error body a Hash or a bare String"
call becomes *ours*, which is the point). The official gem's vendor
backing doesn't pay off for a frozen single endpoint and its generated
bulk actively fights the audit value; keeping `ruby_llm` remains the
zero-work default until a decision criterion below trips.

This doesn't change the recommendation (keep `ruby_llm`, fix the bug on
its own track) — it just means *if* a criterion trips, "adopt
`ruby-openai` and own the thin layer above it" should be costed
alongside "hand-roll from scratch," and probably beats it.

## Sizing the port: is there a way to guess-estimate?

Yes, and it beats "a few hundred lines." Method: take the **measured**
symbol table above (what we *actually* touch), map each symbol to the
ruby_llm source file that implements it, read that file's line count as
an **upper bound**, then discount along three axes that all cut the same
way for us:

1. **Single provider** — drop everything under `providers/openai/` that
   isn't chat/streaming/tools (`capabilities.rb` 273, `models.rb`,
   `embeddings`/`images`/`moderation`/`transcription`) and the whole
   base-`provider.rb` (281) dispatch machine, which exists to pick
   *between* providers we don't have.
2. **`ruby-openai` absorbs the fiddly HTTP** — SSE framing/buffering,
   the `[DONE]` sentinel, auth, multipart. That deletes the *framing*
   half of `streaming.rb` (179) + `openai/streaming.rb` (55) and all of
   the Faraday plumbing. We keep only the *semantic* half: assembling
   `tool_calls` across deltas and tallying `usage`.
3. **We already own the adjacent code** — `Pikuri::Tool` (126),
   `context_window_detector.rb` (222), `chat_transport.rb` (166) exist
   today; the port *retargets* them from `RubyLLM::` types to ours
   rather than writing them fresh.

Measured against ruby_llm 1.16.0's sources, the net-new hand-written
code we'd **own** (as opposed to delete or retarget):

| Piece we'd own | ruby_llm ref (LOC) | our est. | why the discount |
|---|---|---|---|
| Chat loop — `complete` + tool-dispatch + message accumulation | `chat.rb` 521 | ~150 | one provider, no tool-DSL, no async/batch variants; the pikuri loop wiring already lives in `agent.rb` |
| Value types — `Message`/`Content`/`Chunk`/`Attachment` | 127+91+6+224 = 448 | ~120 | `Data.define`; `Attachment`/multimodal is 1 hit total, so a stub |
| Request rendering — messages+tools → params hash | `openai/chat.rb` 236 + `openai/tools.rb` 125 | ~120 | we build the hash `ruby-openai` passes through verbatim |
| Streaming **semantics** — merge tool-call deltas, usage, error-body | `openai/streaming.rb` 55 + half of `streaming.rb` | ~80 | framing is `ruby-openai`'s; the *"is the error body Hash or bare String"* call (the bug that started this note) becomes ours here |
| Error taxonomy — context-length regexes + HTTP→error mapping | `error_middleware.rb` 81 + `error.rb` 48 | ~60 | port the `CONTEXT_LENGTH_PATTERNS` set + a few `raise` branches |
| Tool schema — our type → OpenAI `function` JSON | `tool.rb` 271 (theirs) / `tool.rb` 126 (ours) | ~30 | already ours; just swap the base class it targets |
| Context isolation — per-agent base-URL/key | `context.rb` 29 | ~0 | **free**: a per-`Agent` `OpenAI::Client` *is* the isolation; the Connection seam collapses into the client constructor |
| Model metadata / registry / pricing | `capabilities.rb` 273 + `models.json` | **drop** | unused; `ModelNotFound` degrades to a plain error string |

**Headline: ~500–600 LOC of new owned code**, plus a mechanical
retarget of the existing ~1,000 LOC of `agent/` + `tool.rb` from
`RubyLLM::` symbols to `Pikuri::` ones (≈11 call sites per symbol, per
the table — rename-and-compile, not redesign). Against that we *delete*
`ruby_llm_patches.rb` (102) and the whole ruby_llm dependency subtree.
For scale: this owns ~550 lines to replace the ~1,450 LOC of ruby_llm
*core* we lean on — itself a slice of a much larger multi-provider gem.

Caveats that would push the number **up** if we wanted parity, not just
"works against llama.cpp": streaming **reasoning/thinking** deltas
(`Chunk.thinking`), real **multimodal** `Attachment` handling, and
**prompt-caching** hints are all handled-today, drop-on-the-floor in the
estimate above; each is additive. The estimate is a *design-time* figure
from source-mapping — the decision-criteria coda still stands: before
committing, build the throwaway spike (client + delta-merge + one
tool-call round-trip against llama.cpp) to convert this ~550 into a
*measured* count.

## Decision criteria — only reopen when one trips

1. **A second bug of this kind** in ruby_llm's OpenAI path that upstream
   is slow to fix *and* is awkward to monkeypatch. One bug is noise; a
   pattern is signal.
2. **Upstream drift** — ruby_llm takes a direction (config model, tool
   protocol, dependency bloat) that actively fights our single-provider,
   audit-first posture.
3. **We genuinely need control the API doesn't expose** — a request/
   response knob ruby_llm hides that we can't reach through `Context`.

Absent one of these: **keep ruby_llm.** The fix for the current bug is
upstream-issue + local monkeypatch, tracked separately. If we do build
the spike, do it as a scoped throwaway first (a `ruby-openai` client +
tool-call delta-merge + one round-trip against llama.cpp) to *measure
the real line count* before committing — the ~550-LOC figure under
"Sizing the port" is a source-mapped design-time estimate, not a
measurement.
