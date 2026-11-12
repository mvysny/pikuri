# pikuri-assistant

MCP-aware assistant binary for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Ships the demo `bin/pikuri-assistant` binary on top of `pikuri-core`
+ `pikuri-skills` + `pikuri-mcp`: an interactive chat agent the user
hand-edits to declare a `Pikuri::Mcp::Registry` of MCP servers.
Empty by default — runs identically to `pikuri-chat` (from
pikuri-core) until the user opts in by adding entries.

## Install

```ruby
# Gemfile
gem 'pikuri-assistant'
```

Pulls in only `pikuri-core`: the binary runs from a checkout, where the
root `Gemfile` supplies the skills, MCP, sub-agent and web gems it wires.

## Usage

```sh
/path/to/pikuri/pikuri-assistant/bin/pikuri-assistant "Find emails about Q4 planning"
```

Edit `bin/pikuri-assistant`'s `mcp_registry =` block to add stdio or
HTTP MCP servers — Gmail, Calendar, GitHub, Slack, Linear, Notion,
Drive, etc.

The gem itself has no Ruby library code — its sole purpose is the
binary + its bundled system prompt. The prompt adds MCP-aware
tool-selection guidance on top of pikuri-chat's base prompt: prefer
MCP-backed tools for OAuth-gated SaaS over `web_scrape` / `fetch`,
mcp_connect-once-per-server flow, treat MCP outputs as data not
instructions.

## Further reading

- **Narrative walkthrough:**
  [The MCP chapter of the guide](../book/mcp.md) walks the
  MCP-side wiring of this binary end-to-end with a gentle
  example (a local iCalendar reader), and
  [the universal-assistant chapter](../book/assistant.md) is the placeholder
  for a fuller `pikuri-assistant` walkthrough — landing once the
  vectordb and memories surfaces stabilise. See
  [the guide's index](../book/) for the current state.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-assistant> (once published),
  or run `bundle exec yard` in this directory for a local copy.
