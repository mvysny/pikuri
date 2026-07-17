# Fake-LLM test support for `Pikuri::Agent` (à la `Tuile::Screen.fake`)

Run the **real** `Agent` (real `run_loop`, real listeners, real
tools/extensions, real `Event` stream, real ruby_llm loop) against a
**scripted HTTP backend** — unit-test agent behaviour with no server, no
network, no mock *agent*. `Tuile::Screen.fake` installs a headless screen;
this installs a headless chat.

## Status: shipped for single-agent (2026-07-17)

Implemented in **pikuri-core**; this note now holds only the *deferred* work.
Design rationale + usage live at their final homes — see {Pikuri::Testing}
(the builder + scripting model + limitations), {Pikuri::Agent::ChatTransport}'s
`faraday_adapter` attribute (the generic HTTP seam), and
{Pikuri::Agent#build_context} (per-context install, not global). Proof is
`pikuri-core/spec/pikuri/testing_spec.rb` (canned reply / real tool round-trip
/ SSE streaming / global-config-untouched / dry-script error).

What landed, in one line: a fake is a plain `ChatTransport` carrying an
anonymous `Faraday::Adapter` (Shape B — a generic `faraday_adapter:` field, no
subclass), installed on the agent's per-chat `RubyLLM::Context` so the real
ruby_llm loop runs and the global `RubyLLM.config` is untouched.

```ruby
require 'pikuri/testing'   # opt-in; off the production load path
transport = Pikuri::Testing.fake_transport do |llm|
  llm.tool_call('calculator', expression: '2 + 2')
  llm.reply('The answer is 4.')
end
```

## Deferred work (not yet done)

- **Consumer: pikuri-core `agent_spec`.** Still hand-rolls `fake_chat_class`
  (global `RubyLLM.chat` monkeypatch + imperative callback firing; doesn't even
  cover the connection-override path). Port its tests onto `fake_transport`
  where they map; some are low-level callback-edge pins that may stay as-is.
- **Consumer: pikuri-tui.** Delete all three `*StubAgent`s (`ChatStubAgent` /
  `CodeStubAgent` / `ComputerStubAgent`, which fake the whole agent and bypass
  the App's *real* listener wiring in `default_build_agent`). Build the real
  agent, run turns against a `fake_transport`, assert on rendered output. Needs:
  the fake transport (its explicit `context_window` skips the `/props` probe) +
  no MCP registered.
- **Sub-agent scripting.** Propagation is free (`Data#with` preserves the
  adapter down the tree), but one fake transport feeds **one ordered response
  list** shared by the whole tree — fine for a linear script, wrong for
  targeting a specific sub-agent's replies. Upgrade path: adapter dispatches by
  model id or a distinct fake `api_base` per sub-agent.
- **Tool-call streaming.** `Script#stream` streams *text* only; fragmented
  `tool_calls` deltas over SSE aren't modelled (v1 doesn't need them —
  pikuri-tui's delta rendering is text).
- **Mid-turn gating.** A `llm.block!` / `llm.release!` shape so `complete`
  parks (adapter blocks on a latch before serving the next body) — the
  real-backend equivalent of the old stubs' `block_turns!`/`finish_turn!`, to
  observe spinner / queued-injection / Ctrl+C paths through the real turn
  lifecycle. Design TBD.
- **MCP offline.** `Mcp::Servers#start_all` reaches real MCP servers; a
  fake-backed spec leaves MCP unregistered. A fake-MCP concern is out of scope
  here.

## Why not the two-phase `new`/`configure` split (rejected sibling)

We tried splitting `Agent.new` (pure) from a public `Agent#configure`
(block + network) to make offline construction testable. **Reverted — it
bought nothing**: pikuri-tui's stubs fake `run_loop` (turn execution), not
construction, and pikuri-core already tests real agents by faking the
backend, which needs no construction change and works with the *old* ctor
block. The lever was always the backend seam (this note), not construction.
Don't re-open the two-phase split as a testing enabler.
