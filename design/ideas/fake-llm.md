# Fake-LLM test support — the deferred remainder

`Pikuri::Testing.fake_transport` shipped for single-agent use (why:
`D_fake_transport`; mechanics + limitations: {Pikuri::Testing}). pikuri-tui's
chat and code shells run their real agent on it (the computer shell's port is
pikuri-tui's own idea). What is left here:

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
