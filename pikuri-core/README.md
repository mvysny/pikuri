# pikuri-core

The lean, audit-friendly foundation of the [pikuri](https://codeberg.org/mvysny/pikuri)
AI-assistant toolkit:

- `Pikuri::Agent` — a thin wrapper around ruby_llm's chat loop with
  the Configurator + Extension protocol for hosts to wire extra
  capabilities into an agent.
- `Pikuri::Tool` framework with strict argument validation
  (`Pikuri::Tool::Parameters`) and LLM-actionable error messages.
- Listener stream (`Pikuri::Agent::Listener::*`) for rendering,
  token accounting, and structured capture.
- Controls (`Cancellable`, `Interloper`) for cancellation and
  mid-loop injection. The loop itself is unbounded — see
  `design/decisions.md` `D_no_step_limit`.
- One bundled example tool, `Pikuri::Tool::CALCULATOR`.
- A demo binary, `bin/pikuri-chat`.

Extensions (web tools, skills, MCP, workspace, coding stack,
named-agent personas) live in sibling gems and opt in à la carte — see
[`pikuri-web`](../pikuri-web/README.md),
[`pikuri-skills`](../pikuri-skills/README.md),
[`pikuri-mcp`](../pikuri-mcp/README.md),
[`pikuri-workspace`](../pikuri-workspace/README.md),
[`pikuri-code`](../pikuri-code/README.md). For the
convenience bundle that pulls in everything, see the
[`pikuri`](../pikuri/README.md) metagem.

## Install

```ruby
# Gemfile
gem 'pikuri-core'
```

```sh
gem install pikuri-core
```

## Minimal usage

```ruby
require 'pikuri-core'

RubyLLM.configure do |c|
  c.openai_api_base = 'http://localhost:8080/v1'
  c.openai_api_key  = 'not-needed'
end

agent = Pikuri::Agent.new(
  transport: Pikuri::Agent::ChatTransport.new(
    model: 'unsloth/Qwen3.6-35B-A3B-GGUF',
    provider: :openai,
    assume_model_exists: true
  ),
  system_prompt: Pikuri.prompt(:'pikuri-chat')
) do |c|
  c.add_tool Pikuri::Tool::CALCULATOR
  c.add_listener Pikuri::Agent::Listener::Terminal.new
end
agent.run_loop(user_message: 'What is 17 * 23?')
```

See `bin/pikuri-chat` for a worked example with REPL, signal
handling, and cancellation.

## Further reading

- **Narrative walkthrough:** [the first-conversation chapter of the pikuri guide](../book/chat.md)
  — install llama.cpp, start the server, run `pikuri-chat`, the
  agentic loop, and the tools `pikuri-chat` wires.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-core> (once published), or run
  `bundle exec yard` in this directory for a local copy.
