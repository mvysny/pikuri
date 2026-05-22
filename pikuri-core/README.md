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
- Controls (`StepLimit`, `Cancellable`, `Interloper`) for budget
  enforcement + cancellation.
- Four stateless bundled tools: `CALCULATOR`, `WEB_SEARCH`,
  `WEB_SCRAPE`, `FETCH`.
- A demo binary, `bin/pikuri-chat`.

Extensions (skills, MCP, workspace, coding stack, named-agent
personas) live in sibling gems and opt in à la carte — see
[`pikuri-skills`](../pikuri-skills/README.md),
[`pikuri-mcp`](../pikuri-mcp/README.md),
[`pikuri-workspace`](../pikuri-workspace/README.md),
[`pikuri-code`](../pikuri-code/README.md),
[`pikuri-assistant`](../pikuri-assistant/README.md). For the
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
  system_prompt: Pikuri.prompt(:'pikuri-chat'),
  tools: [Pikuri::Tool::CALCULATOR, Pikuri::Tool::WEB_SEARCH],
  listeners: Pikuri::Agent::ListenerList.new([
    Pikuri::Agent::Listener::Terminal.new
  ]),
  step_limit: Pikuri::Agent::Control::StepLimit.new(max: 20)
)
agent.run_loop(user_message: 'What is 17 * 23?')
```

See `bin/pikuri-chat` for a worked example with REPL, signal
handling, and cancellation.
