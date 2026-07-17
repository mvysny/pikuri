# Fake-LLM test support for `Pikuri::Agent` (à la `Tuile::Screen.fake`)

Give pikuri a first-class way to run the **real** `Agent` (real `run_loop`,
real `ListenerList`, real tools/extensions, real `Event` stream) against a
**fake LLM backend** — so hosts can unit-test agent behaviour with no server,
no network, no mock *agent*. The analogy: `Tuile::Screen.fake` installs a
headless screen so UI code runs without a terminal; `Pikuri` should install a
headless chat so agent code runs without a provider.

## Why (motivation)

- **pikuri-tui** currently fakes the whole agent — per-shell duck-types
  (`ChatStubAgent` / `CodeStubAgent` / `ComputerStubAgent`) whose only real
  job is a canned `run_loop`. Consequence: the App's *real* listener wiring
  (which lives in `default_build_agent`) is bypassed, so nothing asserts the
  conversation pane actually renders the event stream. A fake *backend* +
  real agent would exercise that wiring end-to-end.
- **pikuri-core** already needs this and re-rolls it ad-hoc in every spec
  (see prior art). No shared, documented, leak-safe helper exists.
- ruby_llm ships nothing reusable (checked 1.16.0 — no test mode / fake
  provider / stub), so pikuri must own it.

## Prior art: the ad-hoc fake in `agent_spec`

`pikuri-core/spec/pikuri/agent_spec.rb` hand-rolls a `fake_chat_class` (a
`RubyLLM::Chat` stand-in) and installs it by monkeypatching the singleton in
a `before`/`after`:

```ruby
RubyLLM.define_singleton_method(:chat) { |**_| captured }   # swap
# ... after: restore the original
```

The fake implements the surface `Agent` touches — `with_instructions`,
`with_tool`, `with_model`, `with_context`, `add_message`, `reset_messages!`,
`messages`, `complete(&blk)`, `ask`, `model`, and the three hook registrars
(`after_message` / `before_tool_call` / `after_tool_result`) — plus test
drivers `fire(hook, *args)`, `fire_chunk(...)`, `add_assistant(...)`. Specs
drive it *imperatively*: call `run_loop`, then manually `fire(:after_message,
add_assistant("hi"))` to simulate the provider replying.

Limits to fix in a real feature:
1. **Global monkeypatch of `RubyLLM.chat`** — leaks if `after` doesn't run;
   not thread-safe; re-declared per spec file.
2. **Doesn't cover the connection-override path.** `Agent#build_chat` builds
   via `RubyLLM.chat` *only when* `!transport.connection_overrides?`;
   otherwise it uses `build_context(transport).chat(...)` (a
   `RubyLLM::Context#chat`). pikuri-tui's `ChatTransport.from_openai_server`
   sets `api_base` → override → the `RubyLLM.chat` swap is **never hit**. So
   the ad-hoc trick wouldn't even work downstream.
3. **Imperative, low-level.** Every test orchestrates callback firing by
   hand; no "script the conversation" ergonomics.

## The seam (key design decision)

**Decided (2026-07-17): fake via a polymorphic transport, not a factory swap.**
The fake rides the **`ChatTransport` itself** — a fake transport carries its own
Faraday adapter, and the agent installs it through the connection machinery it
*already has*. No `Pikuri.chat_factory` global, no `RubyLLM.chat` monkeypatch,
no new chokepoint. Two facts (both spike-verified) make this the cleanest seam:

1. **The adapter can live on the per-chat `Context`, not the global config.**
   `Chat#initialize` does `@config = context&.config || RubyLLM.config`, and the
   connection is built from *that* config — so `faraday_adapter` set inside
   `RubyLLM.context { |c| … }` (exactly where `Agent#build_context` already
   builds one) is per-agent and thread-safe. Spike v2 confirmed: the global
   `RubyLLM.config.faraday_adapter` stayed `:net_http` while the fake chat used
   the scripted adapter. **The "config is global" worry is a non-issue.**
2. **`Data#with` preserves the subclass**, so `parent.transport.with(…)` (how
   both sub-agents and the synthesizer derive their transport) carries a fake
   transport down the whole tree for free — the sub-agent coverage that a global
   install was wanted for, with no global. *(Sub-agent scripting is deferred —
   see "Sub-agents (deferred)" — but the propagation comes for free.)*

**Shape B — one generic field on `ChatTransport` (chosen over a subclass).**
`ChatTransport` gains a `faraday_adapter:` member, defaulting `nil` (→ ruby_llm's
normal `:net_http`). `Agent#build_context` consults it in one line:

```ruby
def build_context(transport)
  RubyLLM.context do |c|
    c.public_send("#{transport.provider}_api_base=", transport.api_base) unless transport.api_base.nil?
    c.public_send("#{transport.provider}_api_key=", transport.api_key)  unless transport.api_key.nil?
    c.faraday_adapter = transport.faraday_adapter if transport.faraday_adapter   # <- the whole change
  end
end
```

That is the *entire* Agent-side change. Agent never names a fake type — it just
reads a field. The field is framed generically ("inject a custom HTTP adapter"):
a VCR or logging adapter would use the same door, so it isn't a test hack
smuggled into production.

**Why not a `FakeTransport < ChatTransport` subclass** (the first instinct — a
`faraday()` method the subclass overrides): `ChatTransport` is a frozen `Data`,
so a subclass instance **can't add members or ivars** (spike: `ivar set FAILS:
FrozenError`) — the overridden method would have nowhere to read the scripted
response list from, forcing a module-level registry keyed on some existing
member (`api_base`). Shape B sidesteps that entirely: the adapter is an
**anonymous class closing over the response list**, and it lives *in* the
`faraday_adapter` field, which `.with` preserves. No registry, no frozen-Data
gymnastics.

Two orthogonal I/O legs still bypass the chat and need neutralization; a fake
transport handles both by construction:
- **Context-window probe** — `ContextWindowDetector.detect` hits `/props` over
  HTTP directly. A fake transport carries an explicit
  `ChatTransport#context_window`, which short-circuits the probe (agent.rb:427)
  — no HTTP leak.
- **MCP** — `Mcp::Servers#start_all` reaches real MCP servers. Out of scope
  here; a fake-backed spec leaves MCP unregistered.

A fake transport must also set an `api_base` so `connection_overrides?` is true
and `build_chat` takes the `Context#chat` branch (the `RubyLLM.chat` else-branch
uses the global config and would miss the per-context adapter). The builder does
this automatically.

## Two backends behind that seam (the fork that resolves L1-drift)

`build_chat` is *where* we inject; it does not decide *what* the injected chat
is. Two candidates, and the choice is the whole ballgame for the "L1 fidelity
vs. drift" open question below:

- **(1) Hand-rolled `FakeChat`.** A `RubyLLM::Chat` stand-in that satisfies the
  `build_chat` surface and *reimplements ruby_llm's tool loop* to fire the
  Agent's callbacks (`after_message` / `before_tool_call` / `after_tool_result`)
  in the right order. Ergonomic to script (pikuri Event/tool vocabulary), but it
  is a **second agent loop that drifts against ruby_llm upgrades** — and for a
  project whose selling point is "small enough to audit / teaches how agents
  actually work," a fake loop that can silently diverge from the real one is the
  wrong direction.

- **(2) Faraday-adapter stub — inject a *real* `RubyLLM::Chat` backed by a fake
  HTTP transport.** ruby_llm builds its Faraday connection with a **configurable
  adapter** (`ruby_llm/connection.rb:120`):

  ```ruby
  adapter = @config.respond_to?(:faraday_adapter) ? @config.faraday_adapter : :net_http
  faraday.adapter(adapter || :net_http)
  ```

  So a custom adapter serving scripted, OpenAI-wire-shaped JSON lets the **real
  ruby_llm loop run** — real tool-call parsing, real tool dispatch, real
  result-append-and-re-request, real SSE streaming. The fake only serves N
  sequential HTTP responses; **zero loop reimplementation, zero drift, streaming
  for free.** Cost: the script speaks provider-wire JSON, not pikuri terms.

  Caveat found while reading: `faraday.adapter(adapter || :net_http)` is called
  **without a block**, so plain `:test` yields an empty stub set (every request
  raises "no stubbed request"). The route is to register a small custom adapter
  class fed from a thread-local response queue and set
  `config.faraday_adapter = ThatClass`.

  **Spike result (2026-07-17): PASS — this route is clean.** A ~40-line
  `ScriptedAdapter < Faraday::Adapter` (thread-local response queue; `call`
  does `super` then `save_response(env, 200, json, {...}, nil)`) drove a **real
  `Pikuri::Agent`** through a **real two-turn tool round-trip** with zero
  RubyLLM monkeypatch and zero hand-rolled loop:
  - transport was `from_openai_server` (connection **override** path — the exact
    one the old `RubyLLM.chat` swap misses); 2 HTTP requests reached the adapter,
    confirming the loop re-requested after the tool result.
  - the **real** `calculator` tool executed (`ToolResult "4"`); the real Event
    stream emitted `ContextCap, UserTurn, Tokens, ToolCall, ToolResult,
    Assistant, Tokens`.
  - explicit `context_window: 8192` on the transport short-circuited the
    `/props` probe (agent.rb:427) — no HTTP leak there.

  Adapter shape that worked (the two gotchas): override `call` must invoke
  `super` first (the base builds `env.response`; skipping it → `undefined method
  'finish' for nil`), and `save_response` needs an explicit `nil` reason_phrase
  to dodge a kwargs clash. Streaming (L2) still needs an SSE-shaped variant
  (`text/event-stream`, `data:` chunks) — known-doable, not yet spiked.

Trade-off, at a glance:

| | (1) `FakeChat` | (2) Faraday stub |
|---|---|---|
| loop fidelity | reimplemented, drifts | **real ruby_llm loop, no drift** |
| streaming (L2) | re-faked chunks | **real SSE path for free** |
| script vocabulary | pikuri Event/tool terms (nice) | provider-wire JSON (uglier) |
| coverage | Agent callbacks only | Agent callbacks **+ real loop** |

The scripting DSL below layers on *either* backend — it just emits wire JSON
instead of firing callbacks by hand.

**Decided (2026-07-17): backend (2), fake Faraday.** The spike passed and the
drift risk that motivated (1)'s nicer vocabulary is gone — there's no second
loop to drift. The DSL emits OpenAI-wire JSON under the hood, so (2)'s "uglier
vocabulary" con is hidden behind builder helpers (`tool_call(...)` / `reply(...)`).

## Public API: `Pikuri::Testing.fake_transport`

The whole feature is one builder that returns a plain `ChatTransport` carrying a
fake adapter (Shape B). No global install, no `Agent.new` signature change — you
just pass the transport you always pass:

```ruby
transport = Pikuri::Testing.fake_transport do |llm|
  llm.tool_call('calculator', expression: '2 + 2')   # turn 1: model calls a real tool
  llm.reply('The answer is 4.')                        # turn 2: final answer
end

agent = Pikuri::Agent.new(transport:, system_prompt: '…') do |c|
  c.add_tool Pikuri::Tool::CALCULATOR
end
agent.run_loop(user_message: 'What is 2 + 2?')   # real loop runs the real calculator
```

Under the hood `fake_transport`:
- collects the block's calls into an ordered list of OpenAI-wire response bodies;
- builds an **anonymous `Faraday::Adapter` subclass closing over that list** (each
  request pops the next body; `call` does `super` then `save_response(env, 200,
  json, {...}, nil)` — the two spike gotchas);
- returns `ChatTransport.new(model: 'fake', provider: :openai,
  assume_model_exists: true, api_base: 'http://fake.invalid/v1', api_key:
  'not-needed', context_window: <default>, faraday_adapter: <that class>)`.

The fake `api_base` forces the `Context#chat` branch; the `context_window` skips
the `/props` probe; the `faraday_adapter` field is the new generic seam.

## Scripting model (the builder's `llm.*` verbs)

- **L0 — canned reply.** `llm.reply("hi")` appends a plain assistant-text body.
  Covers "does the pane render the answer?".
- **L1 — scripted tool turn.** `llm.tool_call(name, **args)` appends an
  assistant body with a `tool_calls` entry; the **real** ruby_llm loop parses
  it, runs the **real** registered tool, appends the observation, and re-requests
  — so the next scripted body is the model's follow-up. No loop reimplementation
  (that was backend (1)'s burden; backend (2) is free of it).
- **L2 — streaming.** An SSE-shaped variant (`text/event-stream`, `data:`
  chunks) so streaming/delta rendering is testable through the real streaming
  path. **Not yet spiked** — the one remaining unknown.
- **Mid-turn gating.** A `llm.block!` / `llm.release!` shape so `complete` parks
  (adapter blocks on a latch before serving the next body) — the real-backend
  equivalent of the old stubs' `block_turns!`/`finish_turn!`, letting a host
  observe spinner / queued-injection / Ctrl+C paths through the real turn
  lifecycle. Design TBD.

## Sub-agents (deferred)

Propagation is free (`.with` preserves the fake transport down the tree), but a
single fake transport feeds **one ordered response list** shared by the whole
tree — fine for a linear script, wrong for targeting a *specific* sub-agent's
replies. Deferring until the single-agent feature proves itself; the upgrade
path is to have the adapter dispatch by model id or a distinct fake `api_base`
per sub-agent. Not a v1 blocker.

## Packaging

- `Pikuri::Testing` in `pikuri-core/lib/pikuri/testing.rb`, **not** required
  by default (`require 'pikuri/testing'` in specs) — keeps test scaffolding
  off the production load path without a separate gem. (Revisit a
  `pikuri-testing` gem only if it grows heavy deps.)

## Consumers (the payoff)

- **pikuri-core** `agent_spec` (+ mcp/subagents/skills integration specs)
  replace their ad-hoc `fake_chat_class` with `Pikuri::Testing.fake_transport`.
- **pikuri-tui** deletes all three `*StubAgent`s: App builds its *real* agent
  via `default_build_agent` (drop the `&build_agent` override), runs real turns
  against a `fake_transport`, and finally asserts on rendered output. Needs: the
  fake transport (its explicit `context_window` skips the probe) + no MCP
  registered. (Single-agent shells first; sub-agent trees ride the deferred
  work above.)

## Why not the two-phase `new`/`configure` split (rejected sibling)

We tried splitting `Agent.new` (pure) from a public `Agent#configure`
(block + network) to make offline construction testable. **Reverted — it
bought nothing**: pikuri-tui's stubs fake `run_loop` (turn execution), not
construction, and pikuri-core already tests real agents by faking the
backend, which needs no construction change and works with the *old* ctor
block. The lever was always the backend seam (this idea), not construction.
Don't re-open the two-phase split as a testing enabler.

## Open questions

- **L1 fidelity vs drift** — **resolved: backend (2)** (Faraday stub → real
  ruby_llm loop). Spike passed (see "Two backends behind that seam"); the
  drift risk is gone because there's no second loop to drift.
- **Global vs per-agent** — **resolved: neither, polymorphic transport** (Shape
  B). Per-agent by construction (adapter rides the transport's `Context`, global
  config untouched — spike-verified), and sub-agent propagation is free via
  `.with`. No global install to tear down.
- **Probe neutralization** — **resolved: explicit `context_window` on the fake
  transport** (the honest option; short-circuits agent.rb:427 with no HTTP).
- **L2 streaming** — the one open unknown: an SSE-shaped adapter variant.
  Known-doable, not yet spiked.
- **Mid-turn gating shape** — `llm.block!`/`release!` via an adapter latch;
  design TBD.
- **Does fake mode touch tools/extensions at all?** Default: leave them real
  (that's the point). MCP is the one that can't stay real offline.
