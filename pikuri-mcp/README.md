# pikuri-mcp

[Model Context Protocol](https://modelcontextprotocol.io) support
for the [pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant
toolkit.

Adds:
- `Pikuri::Mcp::Registry` — declarative config layer for stdio +
  HTTP MCP servers.
- `Pikuri::Mcp::Servers` — runtime that spawns the configured
  servers via the [`mcp`](https://rubygems.org/gems/mcp) gem.
- `Pikuri::Mcp::Synthesizer` — LLM-driven description summarizer
  for MCP servers whose handshake omits useful instructions.
- `Pikuri::Mcp::Verifier` — pre-flight prompt-injection scan of
  every MCP server's tool surface before tools are advertised to
  the LLM.
- `Pikuri::Mcp::Cache` — on-disk cache of synthesized descriptions
  and verifier results, keyed on the full server surface.
- `Pikuri::Mcp::Extension` — wires everything into a
  `Pikuri::Agent` via the `c.add_extension(...)` block API.

## Install

```ruby
# Gemfile
gem 'pikuri-mcp'
```

Adds the `mcp` gem as a runtime dep on top of `pikuri-core`.

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-mcp'

registry = Pikuri::Mcp::Registry.new(entries: [
  Pikuri::Mcp::Registry::StdioEntry.new(id: 'gmail', command: %w[npx @gongrzhe/server-gmail-autoauth-mcp]),
  Pikuri::Mcp::Registry::HttpEntry.new(id: 'hubspot', url: 'https://mcp.example.com/v1',
                                       headers: { 'Authorization' => "Bearer #{ENV.fetch('HUBSPOT_TOKEN')}" })
])

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Mcp::Extension.new(registry: registry))
end
```

The extension's `configure` builds the shared `Mcp::Servers` (which
eager-starts every configured server), appends `<available_mcps>` to
the system prompt, and registers a close handler so the agent's
`#close` tears down the MCP subprocesses. Its `bind(agent)` adds a
per-agent `mcp_connect` tool — sub-agents share the live MCP clients
via the same extension instance but each has its own connect tool +
activation set.

## Further reading

- **Narrative walkthrough:** a guide chapter on MCP and
  `pikuri-assistant` is planned once that surface stabilises. In
  the meantime, [chapter 2](../docs/guide/02-subagents.md) and
  [chapter 3](../docs/guide/03-code.md) establish the
  `add_extension` pattern this gem follows.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-mcp> (once published), or run
  `bundle exec yard` in this directory for a local copy.
