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

Pikuri sits *on top of* ruby_llm; we don't pretend otherwise. The seam
protects **consumers of pikuri's library code** — anything that
`require`s `lib/`. The boot/wiring layer (`bin/pikuri`) is allowed to
talk to both, because it's the script that wires them together.

| Layer | May reference `RubyLLM::*`? | Why |
| --- | --- | --- |
| `bin/pikuri` | ✅ | Boot/wiring layer. Configures the underlying ruby_llm runtime. |
| `lib/agent.rb` | ✅ | Constructs `RubyLLM::Chat`, attaches event listeners, calls `complete`. |
| `lib/tool.rb` | ✅ | `Tool.new(...)` factory emits a synthetic `RubyLLM::Tool` subclass. |
| Everything else in `lib/` (bundled tools, scrapers, search providers) | ❌ | Talks to pikuri's surface (`Tool.new`, `Tool::Parameters`, …), not to ruby_llm. |
| Specs | only when testing the seam | A spec for `Agent` may stub `RubyLLM::Chat`; a spec for `Tool::CALCULATOR` should not see ruby_llm at all. |

The "fork or swap" contingency is a fixed-cost operation against this
seam: rewriting `Agent` (replace `RubyLLM::Chat` with an in-house
loop) and `Tool` (replace the synthetic-subclass factory with
pikuri's old `Data.define` value object) brings the loop back
in-house.

## Configuration split

ruby_llm is the underlying transport layer; pikuri is the agent layer
on top. Each owns its own configuration:

| Goes in `RubyLLM.configure` | Goes in `Agent.new` |
| --- | --- |
| `openai_api_base`, `openai_api_key` (and similar for other providers) | `system_prompt` (agent identity) |
| `request_timeout`, `max_retries`, `retry_*`, `http_proxy` (transport policy) | `tools` (agent capability) |
| `default_model` (process-wide fallback) | `model` (this agent's choice; defaults to `RubyLLM.config.default_model`) |
| `logger`, `log_*` (observability of transport) | `max_steps` and any future agent-specific knobs |

Concrete boot:

```ruby
# bin/pikuri
RubyLLM.configure do |c|
  c.openai_api_base = 'http://192.168.122.1:8080/v1'
  c.openai_api_key  = 'not-needed'
end

agent = Agent.new(
  model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
  system_prompt: File.read("#{__dir__}/../smolagents-system-prompt.txt"),
  tools: [Tool::WEB_SEARCH, Tool::CALCULATOR, Tool::WEB_SCRAPE, Tool::FETCH]
)
agent.run_loop(user_message: question)
```

`Agent#initialize` builds the `RubyLLM::Chat` from those args:

```ruby
# lib/agent.rb (sketch)
def initialize(model: RubyLLM.config.default_model, system_prompt:, tools: [], max_steps: 20)
  @chat = RubyLLM.chat(model: model)
  @chat.with_instructions(system_prompt)
  tools.each { |t| @chat.with_tool(t.to_ruby_llm) }
  @max_steps = max_steps
end
```

For test isolation, prefer `RubyLLM.context { |c| ... }` over mutating
the global `RubyLLM.configure` between tests; the context returns a
forked config without touching process-wide state.

## File-by-file plan

| File | Status | Notes |
| --- | --- | --- |
| `lib/agent.rb` | rewrite | No more iterating loop. `Agent#run_loop` configures a `RubyLLM::Chat`, attaches listeners (reasoning, tool calls, streaming chunks), calls `Chat#complete`, returns. The "extension surface" — what plan-mode / permissions / telemetry will hook into later — is the listener set. |
| `lib/chat_log.rb` | **delete** (likely) | Strict-by-construction validation only protects what *pikuri* constructs. Under B, ruby_llm constructs messages. ruby_llm's `ensure_valid_role` covers the same ground. Keep only if there's a concrete reader-side reason; otherwise drop. |
| `lib/openai_client.rb` | **delete** | Replaced by ruby_llm. |
| `lib/chat_response.rb` | **delete** | Replaced by ruby_llm's `Message`/`Response` types. |
| `schemas/chat_completion_response.json` | **delete** | Drop JSON Schema response validation. |
| `lib/llm/config.rb` | **not needed** | Initially planned, but the configuration-split decision (see "Configuration split" section below) means `bin/pikuri` calls `RubyLLM.configure` directly. No pikuri-side wrapper required. |
| `lib/tool.rb` | rewrite | `Tool.new(name:, description:, parameters:, execute:)` becomes a factory: builds and returns a synthetic `RubyLLM::Tool` subclass whose `execute` body runs pikuri's `Parameters#validate` first, then the user-supplied callable. Public surface (constants like `Tool::CALCULATOR`) unchanged. |
| `lib/tool/parameters.rb` | keep | Validation ordering is the load-bearing detail — see "Tool validation ordering" below. The synthetic ruby_llm tool advertises a permissive schema; pikuri's validator does the actual check. |
| `lib/tool/*.rb` (calculator, web_search, web_scrape, fetch, sub_agent) | keep | All defined via `Tool.new(...)` constants. No changes — the factory rewrite preserves the call shape. |
| `lib/tool/scraper/*.rb`, `lib/tool/search/*.rb` | keep | Unaffected. |
| `bin/pikuri` | refactor | `RubyLLM.configure { ... }` for transport (api_base, api_key); `Agent.new(model:, system_prompt:, tools:)` for agent identity. See "Configuration split" below. |
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
3. **Agent rewrite.** Replace `Agent#run_loop`'s iterating body with
   listener wiring + an `ask`/`complete` call. Concrete recipe:

   ```ruby
   def run_loop(user_message:)
     @chat.after_message do |msg|
       next unless msg.role == :assistant
       puts Rainbow(msg.thinking.text).darkgray if msg.thinking&.text && !msg.thinking.text.empty?
       puts TTY::Markdown.parse(msg.content)    if msg.content && !msg.content.empty?
     end
     @chat.before_tool_call  { |tc| @step += 1; raise "agent exceeded #{@max_steps} steps" if @step > @max_steps; puts Rainbow("→ #{tc.name}(#{tc.arguments})").cyan }
     @chat.after_tool_result { |r|  puts Rainbow("= #{r}").cyan }
     @chat.ask(user_message)
   end
   ```

   The thinking/content/tool-call/tool-result rendering matches today's
   inline output 1:1. Reasoning content reaches us via
   `Message#thinking.text` — verified that the OpenAI provider extracts
   `reasoning_content` from llama.cpp/Qwen3-style responses
   (`lib/ruby_llm/providers/openai/chat.rb:166`).

   `max_steps` becomes a counter incremented in `before_tool_call`
   that raises when exceeded. ruby_llm's `Chat` has no built-in
   step budget; without this guard, a buggy tool that always returns
   the same observation could loop indefinitely.

   Specs that assert step-by-step loop behavior get rewritten as
   listener assertions (capture what the callbacks emit instead of
   what `run_loop` prints). Commit.
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

We want pikuri's `Tool::Parameters` validator (DidYouMean, type
coercion, all-errors-collected, schema reprinted on failure) to be
what the LLM sees when it emits bad arguments — not ruby_llm's
keyword-presence checker.

ruby_llm's `Tool#call` (`lib/ruby_llm/tool.rb:106–150`) does two
distinct things, and they're separable:

1. **Schema emission** — what's advertised to the LLM in the request
   body's `tools` array. Built by `params_schema` from either
   `param :name` declarations, a `params(schema)` call (which accepts
   a raw JSON Schema hash), or method reflection.
2. **Runtime validation** — `validate_keyword_arguments` reflects on
   `method(:execute).parameters` and checks keyword presence only.
   It does **not** type-check, and it bypasses entirely when `execute`
   accepts `**rest`:

   ```ruby
   return nil if accepts_extra_keywords  # tool.rb:143
   ```

The synthesis recipe:

```ruby
schema = pikuri_tool.parameters.to_h          # pikuri's JSON Schema
klass  = Class.new(RubyLLM::Tool) do
  description pikuri_tool.description
  params schema                                # advertised to the LLM
  define_method(:execute) do |**args|          # **args disables ruby_llm's check
    pikuri_tool.run(args)                      # pikuri's strict validate + execute
  end
end
```

That's it. The LLM sees pikuri's schema; ruby_llm's runtime validator
no-ops on the keyrest signature; pikuri's `Parameters#validate` runs
inside `Tool#run` and produces the LLM-facing error string on failure.
DidYouMean and coercion both survive.

The synthetic class uses only ruby_llm's public API (`params`,
`description`, `execute`). The fragility risk is bounded to whether
ruby_llm changes the semantics of `params(schema)` accepting a raw
hash, or the keyrest-bypass in `validate_keyword_arguments`.

## Open questions to settle before step 2

1. **Tool-result error shape.** Pikuri returns `"Error: ..."` strings;
   ruby_llm sometimes returns `{error: "..."}` hashes. Verify a
   synthetic tool returning a string from `execute` lands as a normal
   tool-result message (model sees the string), not a structured-error
   path that the model treats specially.
2. **Subagent factory.** `Tool.sub_agent` constructs a fresh `Agent` on
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
