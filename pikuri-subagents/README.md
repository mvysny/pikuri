# pikuri-subagents

Sub-agent / delegation support for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Provides:
- `Pikuri::SubAgent::Persona` — the
  `(name, description, tool_names, system_prompt, max_steps)`
  record bundling "what kind of agent is this." Hosts declare
  which personas an agent may spawn by handing instances to the
  extension.
- `Pikuri::SubAgent::SubAgentTool` — the LLM-facing `agent` tool.
  Picks a persona by name, spawns a fresh agent with that
  persona's toolset + system prompt, runs it to a final answer,
  returns the summary to the parent.
- `Pikuri::SubAgent::Extension` — wires the tool + the
  `<available_agents>` snippet into a `Pikuri::Agent` via the
  `c.add_extension(...)` block API.
- `Pikuri::SubAgent::RESEARCHER` — bundled persona: web tools
  (`web_search` / `web_scrape` / `fetch`), 20 steps, focused
  research system prompt.
- `Pikuri::SubAgent::FILE_MINER` — bundled persona: read-only
  filesystem recon (`read` / `grep` / `glob`), 30 steps. No
  egress, no mutation, no `agent` recursion — gives
  prompt-injected file contents nothing actionable to reach for.

Includes the `bin/pikuri-minions` fan-out demo binary: a top-level
agent biased toward parallel decomposition, with `RESEARCHER`
wired in as a delegate.

## Install

```ruby
# Gemfile
gem 'pikuri-subagents'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-subagents'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_tool Pikuri::Tool::WEB_SEARCH
  c.add_tool Pikuri::Tool::WEB_SCRAPE
  c.add_tool Pikuri::Tool::FETCH
  c.add_extension(
    Pikuri::SubAgent::Extension.new(
      personas: [Pikuri::SubAgent::RESEARCHER]
    )
  )
end
```

The extension's `configure` validates every persona's `tool_names`
against the agent's registered tools and appends
`<available_agents>` to the system prompt. Its `bind(agent)` adds
a per-agent `agent` tool. Sub-agents do **not** inherit extensions
— each persona owns its toolset and system prompt verbatim, so
e.g. a `RESEARCHER` cannot recursively spawn another `agent` tool.

See `bin/pikuri-minions` for a worked example with REPL +
fan-out-biased system prompt.

## Further reading

- **Narrative walkthrough:** [chapter 2 of the pikuri
  guide](../docs/guide/02-subagents.md) — the `Persona` record,
  the `configure` + `bind` Extension protocol, what gets inherited
  vs. owned when a parent spawns a child, and the
  privilege-separation story.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-subagents> (once published),
  or run `bundle exec yard` in this directory for a local copy.
