# Fake-LLM test support — the deferred remainder

`Pikuri::Testing.fake_transport` shipped for single-agent use (why:
`D_fake_transport`; mechanics + limitations: {Pikuri::Testing}). pikuri-tui's
chat and code shells run their real agent on it. What is left:

## Computer shell port (pikuri-tui) — needs test-isolation seams

`Computer::App#default_build_agent` wires `Os::Extension` +
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

## `Q_subagent_scripting`

Propagation is free (`Data#with` preserves the adapter down the tree), but one
fake transport feeds **one ordered response list** shared by the whole tree —
fine for a linear script, wrong for targeting a specific sub-agent's replies.
Upgrade path: adapter dispatches by model id or a distinct fake `api_base` per
sub-agent.

## `Q_tool_call_streaming`

`Script#stream` streams *text* only; fragmented `tool_calls` deltas over SSE
aren't modelled (pikuri-tui's delta rendering is text, so nothing needs it yet).

## `Q_mcp_offline`

`Mcp::Servers#start_all` reaches real MCP servers; a fake-backed spec leaves MCP
unregistered (an empty registry is a no-op). A fake MCP server is out of scope
for `fake_transport`.
