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
the spike, do it as a scoped throwaway first (client + SSE parser +
one round-trip against llama.cpp) to *measure the real line count*
before committing — the "few hundred lines" claim above is an estimate,
not a measurement.
