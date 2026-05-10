# MIGRATION.md — depending on ruby_llm

Sketch for replacing pikuri's hand-rolled transport with ruby_llm, while
preserving the pieces of pikuri that are deliberately stricter or more
opinionated than ruby_llm.

## Goals

1. Replace `OpenAIClient` + `ChatResponse` + `ChatParser` with ruby_llm.
2. **Preserve** the developer-facing public API surface: `Agent#run_loop`,
   `ChatLog` with strict role validation, `Tool.new(...)` constants,
   `Tool::Parameters` with DidYouMean, the recoverable-vs-bug error split.
3. Confine `RubyLLM::*` references to one or two adapter files — the
   "swap is a one-day job" seam.
4. Drop the response-body JSON Schema validation idea (too brittle on top
   of someone else's parser).
5. **Streaming is out of scope for this migration.** Add it as a follow-up
   once the adapter shape is stable.

## Architectural choice — Chat as runtime

Pikuri's `Agent` becomes a thin wrapper around `RubyLLM::Chat`. Tools
are registered with the Chat; `Chat#complete` runs the loop.
`Agent#run_loop` does not iterate; instead it configures the Chat,
attaches event listeners (`before_tool_call`, streaming chunks,
reasoning), invokes `complete`, and renders output through those
listeners.

Why this over the alternative ("Chat as transport, pikuri keeps the
loop"):

- More code deleted from pikuri; less ongoing maintenance overlap with
  ruby_llm.
- Streaming, callbacks, and `Tool::Halt` come for free instead of being
  reimplemented.
- The extensibility surface pikuri actually needs going forward — event
  hooks for plan-mode, permissions, telemetry, TUI — maps cleanly onto
  ruby_llm's existing event stream rather than fighting it.

What we accept in exchange:

- The agent loop is no longer pikuri's. CLAUDE.md's "loop is the spine"
  commitment is replaced by "Agent owns the extension surface; ruby_llm
  owns the loop."
- Tighter coupling to `RubyLLM::Chat` semantics. If ruby_llm goes
  unmaintained, the contingency is a fork.

Mitigated by the seam (next section): all `RubyLLM::*` references
confined to one or two files.

## The seam

Files allowed to reference `RubyLLM::*`:

- `lib/agent.rb` — constructs `RubyLLM::Chat`, attaches event
  listeners, calls `complete`.
- `lib/tool.rb` — `Tool.new(...)` becomes a factory that emits a
  synthetic `RubyLLM::Tool` subclass.
- `lib/llm/config.rb` (new, optional) — translates pikuri's
  `(url:, model:, api_key:)` into ruby_llm config.

Everything else — bundled tools, scrapers, search providers, specs,
`bin/pikuri` — talks to pikuri's surface (`Agent`, `Tool::CALCULATOR`,
…), not to ruby_llm.

The "fork or swap" contingency is a fixed-cost operation against this
seam: rewriting these three files plus the listener wiring inside
`Agent` brings the loop back in-house.

## File-by-file plan

| File | Status | Notes |
| --- | --- | --- |
| `lib/agent.rb` | rewrite | No more iterating loop. `Agent#run_loop` configures a `RubyLLM::Chat`, attaches listeners (reasoning, tool calls, streaming chunks), calls `Chat#complete`, returns. The "extension surface" — what plan-mode / permissions / telemetry will hook into later — is the listener set. |
| `lib/chat_log.rb` | **delete** (likely) | Strict-by-construction validation only protects what *pikuri* constructs. Under B, ruby_llm constructs messages. ruby_llm's `ensure_valid_role` covers the same ground. Keep only if there's a concrete reader-side reason; otherwise drop. |
| `lib/openai_client.rb` | **delete** | Replaced by ruby_llm. |
| `lib/chat_response.rb` | **delete** | Replaced by ruby_llm's `Message`/`Response` types. |
| `schemas/chat_completion_response.json` | **delete** | Drop JSON Schema response validation. |
| `lib/llm/config.rb` | **new** | Tiny adapter: takes pikuri's `(url:, model:, api_key:)` and configures ruby_llm (global config + per-Chat overrides). The seam for transport config. |
| `lib/tool.rb` | rewrite | `Tool.new(name:, description:, parameters:, execute:)` becomes a factory: builds and returns a synthetic `RubyLLM::Tool` subclass whose `execute` body runs pikuri's `Parameters#validate` first, then the user-supplied callable. Public surface (constants like `Tool::CALCULATOR`) unchanged. |
| `lib/tool/parameters.rb` | keep | Validation ordering is the load-bearing detail — see "Tool validation ordering" below. The synthetic ruby_llm tool advertises a permissive schema; pikuri's validator does the actual check. |
| `lib/tool/*.rb` (calculator, web_search, web_scrape, fetch, sub_agent) | keep | All defined via `Tool.new(...)` constants. No changes — the factory rewrite preserves the call shape. |
| `lib/tool/scraper/*.rb`, `lib/tool/search/*.rb` | keep | Unaffected. |
| `bin/pikuri` | refactor | Configure ruby_llm (URL, model, API key). Construct `Agent`. Call `run_loop`. |
| `spec/openai_client_spec.rb`, `spec/chat_response_spec.rb`, `spec/chat_log_spec.rb` | **delete** | Replaced/dropped per above. |
| `CLAUDE.md` | rewrite | Not just the Layout section. Scope decisions and Conventions both need updating — "loop is the spine" is gone, "OpenAI-compatible only / no SDKs" is gone. Replace with: *reuse ruby_llm as runtime; pikuri owns the extension surface and the strict validation.* |

## Migration steps (each commit independently green)

1. **Add ruby_llm to Gemfile, no usage.** `bundle install`, run specs.
   Verifies the closure resolves cleanly. Commit.
2. **Tool factory rewrite.** `Tool.new(...)` returns a synthetic
   `RubyLLM::Tool` subclass instead of pikuri's `Data.define` value
   object. `Tool::CALCULATOR` etc. still resolve to working tools.
   `Tool::Parameters` keeps producing JSON Schema; the synthetic
   subclass advertises a permissive schema (or carefully maps pikuri's
   to ruby_llm's `param`) so validation ordering works (see
   "Validation ordering" below). Spec coverage: a synthetic tool round-
   trips through ruby_llm's tool-calling path with pikuri's strict
   validator producing the LLM-facing error string. Commit.
3. **Agent rewrite.** Replace `Agent#run_loop`'s iterating body with:
   construct `RubyLLM::Chat`, register tools (now ruby_llm-native
   thanks to step 2), attach listeners that mirror today's inline
   output (reasoning dim, tool-call cyan, assistant Markdown), call
   `Chat#complete`. Specs that assert step-by-step loop behavior get
   rewritten as listener assertions. Commit.
4. **`bin/pikuri` rewire.** Replace `OpenAIClient` construction with
   ruby_llm config; pass nothing transport-shaped to `Agent`. Real
   end-to-end invocation against a local llama.cpp server is the
   smoke test. Commit.
5. **Delete dead code.** `lib/openai_client.rb`, `lib/chat_response.rb`,
   `schemas/chat_completion_response.json`, and (likely) `lib/chat_log.rb`
   and their specs. Commit.
6. **Rewrite CLAUDE.md.** Not just Layout — Scope decisions and
   Conventions both shift. New top-level framing: *"reuse ruby_llm as
   runtime; pikuri owns the extension surface and the strict
   validation."* Commit.

Streaming, multi-provider config, token accounting, and `Tool::Halt`
come as separate post-migration commits — out of scope here.

## Validation ordering (the load-bearing detail)

Pikuri's `Tool::Parameters` validator (DidYouMean, type coercion,
all-errors-collected, schema reprinted on failure) is what we want the
LLM to see when it emits bad arguments. ruby_llm has its own validator.
Whichever runs first wins.

ruby_llm validates against the schema declared on the `RubyLLM::Tool`
subclass. To make pikuri's validator the LLM-facing one:

- Synthesize the `RubyLLM::Tool` subclass with **no `param` declarations
  and a wildcard `**extra` in `execute`** so ruby_llm's validator
  rubber-stamps anything.
- Inside the synthetic `execute(**args)` body, run pikuri's
  `Parameters#validate(args)` first. On failure, return its error
  string — same shape as today (`"Error: ..."` becomes the LLM-facing
  observation, just routed through ruby_llm's tool-result message
  instead of pikuri's `tool` log entry).
- The schema pikuri ships to the LLM (in the request body's `tools`
  array) still comes from `Parameters#to_h`. The synthetic class
  overrides whatever ruby_llm would emit so the LLM sees pikuri's
  schema, not an empty one.

This means the synthetic class is *not* a normal `RubyLLM::Tool` — it's
a hand-built one that bypasses ruby_llm's schema-generation and
validation pipelines. Verify ruby_llm exposes the right hooks to do
this cleanly before committing to the design.

## Open questions to settle before step 2

1. **Can the synthetic tool override ruby_llm's schema emission?**
   We need the LLM to see pikuri's JSON Schema in the request body, not
   ruby_llm's reflection-based one. Read `RubyLLM::Tool::SchemaDefinition`
   and confirm there's a clean override point. If not, the migration
   needs reshaping.
2. **Configuration shape.** ruby_llm prefers a global
   `RubyLLM.configure` block + per-Chat overrides. Pikuri uses
   explicit constructor args. Decide whether to lean into ruby_llm's
   global config (simpler) or keep per-instance configuration via Chat
   options (cleaner for tests).
3. **Reasoning content.** Pikuri prints `reasoning_content` from
   thinking models dimmed inline. Verify ruby_llm exposes this on
   `Message` (README mentions a `thinking` field). If aligned, render
   via the listener attached in step 3. If not, may need
   `Message#raw` as a fallback.
4. **Tool-result error shape.** Pikuri returns `"Error: ..."` strings;
   ruby_llm sometimes returns `{error: "..."}` hashes. Verify a
   synthetic tool returning a string from `execute` lands as a normal
   tool-result message (model sees the string), not a structured-error
   path that the model treats specially.
5. **Subagent factory.** `Tool.sub_agent` constructs a fresh `Agent` on
   a clean log. Under B, "fresh `Agent`" means a fresh
   `RubyLLM::Chat`. Verify there's no shared global state in ruby_llm
   that would leak between parent and sub-agent (model config, API
   key, etc. should be per-Chat-overridable).

## Risks worth tracking

- **Bus factor 1 on ruby_llm** (crmne wrote 97% of commits). Pin
  tightly (e.g., `ruby_llm '~> 1.15'`), re-evaluate periodically.
  Contingency under B is a fork that brings the loop in-house — the
  reverse of this migration. Doable, not free.
- **`Chat` API stability.** Coupling to `RubyLLM::Chat` is tighter
  under B than under the alternative. Watch minor releases; ruby_llm
  1.15 just normalized token field names, that kind of internal-API
  shift is the failure mode to expect.
- **Synthetic-tool fragility.** If ruby_llm refactors its tool DSL
  (how `param` / schema emission / `execute` invocation work),
  pikuri's synthetic-tool factory breaks. The seam means the breakage
  is contained to `lib/tool.rb`, not spread across the codebase.

## Out of scope (deliberately)

- **Multi-provider config.** Step 1 of the pi-shaped journey is just
  "swap the transport." Adding Anthropic / Gemini / Bedrock support
  comes later, on its own.
- **Streaming.** Once Transport is stable, add a `stream:` block
  argument as a separate change.
- **Vision / audio / embeddings.** Not part of pikuri's current shape.
  Available via ruby_llm if/when needed.
- **Token accounting and cost tracking.** Free if we want it later;
  not load-bearing now.
- **Rails integration (`acts_as_chat`).** No.

## Estimate

Two focused sessions, ~6 commits. The weight is in step 2 (synthetic-
tool factory + verifying ruby_llm's override hooks) and step 3 (Agent
rewrite — listeners replace iteration). Steps 1, 4, 5 are mechanical.
Step 6 (CLAUDE.md rewrite) is short but needs care; it's where the
project's new framing gets crystallized.
