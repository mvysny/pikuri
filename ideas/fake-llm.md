# Fake-LLM test support for `Pikuri::Agent` (à la `Tuile::Screen.fake`)

Run the **real** `Agent` (real `run_loop`, real listeners, real
tools/extensions, real `Event` stream, real ruby_llm loop) against a
**scripted HTTP backend** — unit-test agent behaviour with no server, no
network, no mock *agent*. `Tuile::Screen.fake` installs a headless screen;
this installs a headless chat.

## Status: shipped for single-agent (2026-07-17)

Implemented in **pikuri-core**; this note now holds only the *deferred* work.
The choices made — fake the HTTP backend not the agent, the reverted two-phase
`new`/`configure` split, and why the white-box `fake_chat` is never exported —
are [`DECISIONS.md`](../DECISIONS.md) `D_fake_transport`.
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
