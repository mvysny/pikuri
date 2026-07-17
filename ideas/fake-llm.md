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

Fake at the **`Agent#build_chat` chokepoint**, not at `RubyLLM.chat`. That one
private method is where *every* agent — main, sub-agents, synthesizer, MCP
thinker (all are `Agent`s) — obtains its chat, and it already unifies both
ruby_llm entry points (`RubyLLM.chat` and `Context#chat`). Route it through an
injectable factory:

```ruby
# default (production): current behaviour
# test: Pikuri::Testing.fake_llm! swaps this
Pikuri.chat_factory  # ->(transport) { real build_chat body }
```

Covers override + non-override transports, and the whole agent tree, with no
RubyLLM monkeypatch. Two orthogonal I/O legs still bypass the chat and need
their own neutralization in "fake mode":
- **Context-window probe** — `ContextWindowDetector.detect` hits `/props`
  over HTTP directly. Fake mode must short-circuit it (return a fixed cap, or
  honour an explicit `ChatTransport#context_window`).
- **MCP** — `Mcp::Servers#start_all` reaches real MCP servers. Fake mode
  leaves MCP unregistered (or a separate fake-MCP concern, out of scope
  here).

## API options

- **(A) Global install (Screen.fake-style).**
  `Pikuri::Testing.fake_llm! { |llm| ... }` swaps the factory + neutralizes
  the probe process-wide; `Pikuri::Testing.restore!` (or an RSpec `around`)
  undoes it. Pro: mirrors `Screen.fake`, covers sub-agents automatically, one
  call. Con: global mutable state (needs disciplined teardown).
- **(B) Per-agent injection.** `Agent.new(..., chat_factory:)` (default the
  real one). Pro: no globals, thread-safe. Con: doesn't reach internally
  spawned sub-agents/synthesizer (they build their own) — shallower.
- **(C) Both.** Global for host/integration specs (pikuri-tui App, sub-agent
  trees), per-agent for focused core specs. Likely the answer; (A) is the
  headline feature, (B) a lower-level escape hatch.

## FakeChat contract + scripting model

The fake must satisfy the `build_chat` surface above. Layer the ergonomics:

- **L0 — canned reply.** `llm.reply("hi")` → next `complete` fires
  `after_message` with an assistant message + a `Tokens` event. Covers "does
  the pane render the answer?".
- **L1 — scripted turns (tool loop).** A queue where a turn can be a
  tool-call sequence: fire `before_tool_call` → let the *real* registered
  tool execute → fire `after_tool_result` → … → final `after_message`. This
  is the intricate part (it re-implements ruby_llm's tool loop), but it's
  what exercises the Agent's tool path for real.
- **L2 — streaming.** Split a reply into chunks fed through the streaming
  block `Agent` passes to `complete`, so streaming/delta rendering is
  testable (`fire_chunk` today).
- **Mid-turn gating.** `llm.block!` / `llm.release!` so `complete` parks —
  the real-backend equivalent of the stubs' `block_turns!`/`finish_turn!`,
  letting a host observe spinner / queued-injection / Ctrl+C paths *through
  the real turn lifecycle*.

Open: how faithfully to mimic ruby_llm's loop (L1). More fidelity = more real
coverage but more drift risk against ruby_llm upgrades.

## Packaging

- `Pikuri::Testing` in `pikuri-core/lib/pikuri/testing.rb`, **not** required
  by default (`require 'pikuri/testing'` in specs) — keeps test scaffolding
  off the production load path without a separate gem. (Revisit a
  `pikuri-testing` gem only if it grows heavy deps.)

## Consumers (the payoff)

- **pikuri-core** `agent_spec` (+ mcp/subagents/skills integration specs)
  replace their ad-hoc `fake_chat_class` with the shared helper.
- **pikuri-tui** deletes all three `*StubAgent`s: App builds its *real* agent
  via `default_build_agent` (drop the `&build_agent` override), runs real
  turns under `Pikuri::Testing.fake_llm!`, and finally asserts on rendered
  output. Needs: test config with explicit `context_window` (or fake-mode
  probe short-circuit) + no MCP registered.

## Why not the two-phase `new`/`configure` split (rejected sibling)

We tried splitting `Agent.new` (pure) from a public `Agent#configure`
(block + network) to make offline construction testable. **Reverted — it
bought nothing**: pikuri-tui's stubs fake `run_loop` (turn execution), not
construction, and pikuri-core already tests real agents by faking the
backend, which needs no construction change and works with the *old* ctor
block. The lever was always the backend seam (this idea), not construction.
Don't re-open the two-phase split as a testing enabler.

## Open questions

- **L1 fidelity vs drift** (above).
- **Global vs per-agent default** — start with (A), add (B) if a core spec
  needs isolation.
- **Probe neutralization mechanism** — fake-mode flag on the detector, vs
  requiring explicit `context_window` on test transports. The flag is more
  ergonomic; the explicit window is more honest.
- **Does fake mode touch tools/extensions at all?** Default: leave them real
  (that's the point). MCP is the one that can't stay real offline.
