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

## Not exported: the white-box `fake_chat` (decided 2026-07-18)

pikuri-core `agent_spec` (and the mcp/skills/subagents specs) hand-roll a
`fake_chat_class` — a **white-box callback-capture stub**: tests fire individual
chat callbacks by hand (`fire(:before_tool_call, …)`, `fire_chunk(…)`) and
inspect chat internals (`model_switches`, `contexts`, `added_messages`,
`instructions`). That harness tests **pikuri's own `Agent` ↔ `RubyLLM::Chat`
adapter seam** — an internal contract.

It is **not** a `fake_transport` job and must **not** move into the exported
`Pikuri::Testing`:

- It's the opposite of `fake_transport`. `fake_transport` runs the *real*
  ruby_llm loop black-box; `fake_chat` is a passive stub the test drives
  manually (so it is *not* the rejected backend (1), which reimplemented the
  loop). Most of `agent_spec` can't move to `fake_transport` without losing
  coverage (you can't fire a lone `after_tool_result`, or read `model_switches`,
  off a real chat).
- **Only pikuri itself can use it.** A downstream consumer — pikuri-tui, or any
  project on pikuri — tests *their* tools/listeners/extensions and wants
  `fake_transport`; none ever pokes pikuri's Agent↔Chat callback wiring.
  Exporting `fake_chat` would ship a helper no external caller can use and leak
  the internal adapter contract into the public API.

So `Pikuri::Testing` stays just `fake_transport`. The white-box fakes stay
test-internal, per gem. The 5× duplication is an accepted internal DRY smell
(the copies genuinely diverge; cross-gem spec-support sharing is awkward) — not
worth a shared helper, and definitely not an exported one. The real-loop
coverage `agent_spec`'s callback tests approximate is already carried
end-to-end by `pikuri-core/spec/pikuri/testing_spec.rb`.

## Consumer: pikuri-tui (chat + code DONE, computer deferred)

The App test seam changed from a whole-agent `&build_agent` override to a
`transport:` injection: App always builds its *real* agent via
`default_build_agent`, and a spec passes `Pikuri::Testing.fake_transport` so the
real listener/tool/extension wiring runs against scripted HTTP. Done for
**chat** and **code** (including code's full extension stack — workspace,
sandbox, MCP, sub-agents, tasks, skills); `ChatStubAgent` / `CodeStubAgent`
deleted; each shell gained a net-new "a real streamed turn renders in the
conversation pane" test — the motivating gap. The fake impersonates a config
connection via `api_base:`; mid-turn Ctrl+C uses the `Gate`; the model-picker
test spies `run_loop` for the picked (real) transport without dialing it.

**Computer shell — deferred (needs test-isolation seams, not a mechanical
port).** `Computer::App#default_build_agent` wires `Os::Extension` +
`Thunderbird::Extension`, which probe the host at build:
- **Thunderbird profile.** `Profile.discover(profile_dir: nil)` finds the dev
  machine's *real* profile (opens real mail) and raises on an ambiguous
  install. A test must pass `profile_dir:` → an empty temp dir (deterministic:
  Gloda absent → inbound tools omitted, outbound tools harmlessly wired).
- **Machine facts.** `Os::SystemInfo#prompt_section` spawns `inxi -b`
  synchronously at *every* agent build (confirmed) — ~30 builds ⇒ ~30 spawns,
  slow + machine-coupled. Needs a spec-level stub of `Os::SystemInfo.new`
  (define_singleton_method, the pikuri convention) returning a fast fake.
- **Sandbox.** `config.sandbox: true` builds `FullFsNoNet`, whose bwrap probe
  may raise; the computer spec should boot with `sandbox: false` (confirm no
  test asserts the sandbox wiring).
Once those three are handled, the port mirrors chat/code (swap `&build_agent`
→ `transport:`, delete `ComputerStubAgent`, add the render test).

## Remaining fake_transport work (not yet done)

- **Sub-agent scripting.** Propagation is free (`Data#with` preserves the
  adapter down the tree), but one fake transport feeds **one ordered response
  list** shared by the whole tree — fine for a linear script, wrong for
  targeting a specific sub-agent's replies. Upgrade path: adapter dispatches by
  model id or a distinct fake `api_base` per sub-agent.
- **Tool-call streaming.** `Script#stream` streams *text* only; fragmented
  `tool_calls` deltas over SSE aren't modelled (v1 didn't need them —
  pikuri-tui's delta rendering is text).
- **MCP offline.** `Mcp::Servers#start_all` reaches real MCP servers; a
  fake-backed spec leaves MCP unregistered (an empty registry is a no-op). A
  fake-MCP concern is out of scope here.

*(Mid-turn gating shipped — `Pikuri::Testing::Gate`, `block!`/`release!`; used
by the chat/code Ctrl+C tests.)*

## Why not the two-phase `new`/`configure` split (rejected sibling)

We tried splitting `Agent.new` (pure) from a public `Agent#configure`
(block + network) to make offline construction testable. **Reverted — it
bought nothing**: pikuri-tui's stubs fake `run_loop` (turn execution), not
construction, and pikuri-core already tests real agents by faking the
backend, which needs no construction change and works with the *old* ctor
block. The lever was always the backend seam (this note), not construction.
Don't re-open the two-phase split as a testing enabler.
