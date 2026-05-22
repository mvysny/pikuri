# pikuri

A small Ruby AI assistant you run on your own machine, shipped as a
family of seven gems in a monorepo. `pikuri-chat` (in
[`pikuri-core/bin/`](pikuri-core/bin/pikuri-chat)) is a
general-purpose chatbot with a calculator, web search, web scraping,
and a fetch tool — wired by default to a
[llama.cpp](https://github.com/ggml-org/llama.cpp) server running
locally, so the conversation never leaves your computer unless the
model itself decides to call a tool.

## What's in this repo

Each subdirectory is its own gem with its own `.gemspec`, `lib/`,
`spec/`, and (where relevant) `bin/` + `prompts/`. See each gem's
README for its surface, usage, and security notes.

- [`pikuri-core/`](pikuri-core/README.md) — the lean foundation:
  `Pikuri::Agent`, the `Tool` framework with strict argument
  validation, the listener event stream, four stateless bundled
  tools (calculator, web search, web scrape, fetch), and the
  `bin/pikuri-chat` demo binary.
- [`pikuri-skills/`](pikuri-skills/README.md) — discovery + loading
  of [Agent Skills](https://agentskills.io/specification) from
  `.pikuri/skills`, `.claude/skills`, or `.agents/skills`.
- [`pikuri-workspace/`](pikuri-workspace/README.md) — filesystem
  tools (`read`, `write`, `edit`, `grep`, `glob`) plus the
  `Workspace` and `Confirmer` seams they ride on.
- [`pikuri-code/`](pikuri-code/README.md) — `bash` tool +
  `bin/pikuri-code`, an in-repo coding agent in the spirit of
  Claude Code / opencode / pi-code.
- [`pikuri-mcp/`](pikuri-mcp/README.md) — [Model Context
  Protocol](https://modelcontextprotocol.io) support: stdio + HTTP
  servers, description summarization, injection verification.
- [`pikuri-assistant/`](pikuri-assistant/README.md) — the
  MCP-aware `bin/pikuri-assistant` demo binary on top of core +
  skills + MCP.
- [`pikuri/`](pikuri/README.md) — convenience metagem:
  `gem install pikuri` pulls in all six above.

The top-level `Rakefile` fans out tests
(`bundle exec rake test`) across every gem and orchestrates
lockstep releases (`rake release VERSION=x.y.z`).

## Quick start

```sh
git clone https://codeberg.org/mvysny/pikuri.git
cd pikuri

# Ruby 3.x + bundler (Ubuntu/Debian)
sudo apt install ruby ruby-bundler

bundle install

./pikuri-core/bin/pikuri-chat "What is 17 * 23?"
```

The first run won't get far — pikuri-chat needs a model behind it. See
[GETTING_STARTED.md](GETTING_STARTED.md) for the full walkthrough:
installing `llama.cpp`, pulling a model, starting `llama-server`, and
asking your first question.

## Using pikuri as a library

Pikuri ships as a family of gems you can use in your own project.
The recommended path: **first** play with `pikuri-chat`, inspect the
sources, get a feel for the shape — *then* pull pikuri into your
project as a library.

Privacy-conscious users with a minimal dep tree to audit should
install just the lean core + the extensions they need:

```ruby
# In your Gemfile
gem 'pikuri-core'                                 # mandatory base
gem 'pikuri-skills'                               # Agent Skills standard
gem 'pikuri-mcp'                                  # MCP support (adds `mcp` dep)
gem 'pikuri-workspace'                            # file tools + Workspace/Confirmer
gem 'pikuri-code'                                 # Bash + bin/pikuri-code
gem 'pikuri-assistant'                            # bin/pikuri-assistant
```

For the "I want everything" case, install the convenience metagem:

```ruby
gem 'pikuri'                                      # pulls in all six above
```

A minimal wiring — single agent, default `llama.cpp` transport, the
bundled calculator + web-search tools, the same system prompt
`pikuri-chat` uses:

```ruby
require 'pikuri-core'  # use 'pikuri' if you installed the metagem

RubyLLM.configure do |c|
  c.openai_api_base = 'http://localhost:8080/v1'  # llama.cpp default
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
    Pikuri::Agent::Listener::Terminal.new,
    Pikuri::Agent::Listener::StepLimit.new(max: 20)
  ])
)

agent.run_loop(user_message: 'What is 17 * 23?')
```

`pikuri-core/bin/pikuri-chat`, `pikuri-code/bin/pikuri-code`, and
`pikuri-assistant/bin/pikuri-assistant` in this repo are the
canonical working examples — they're dev/demo scripts (not
installed by `gem install pikuri-*`), but they're the easiest place
to crib wiring from. Each gem's bundled system prompts under its
own `prompts/` are loadable as a starting point via
`Pikuri.prompt(name)`.

## Why this exists

The existing self-hosted agent stacks have grown big and now have a
steep learning curve — a privacy-conscious user arriving fresh hits a
wall of JSON configuration before the first conversation. Pikuri is
the deliberate counter-move:

- **Privacy-first.** Defaults wire a local `llama.cpp` server. No
  cloud account, no API key, no telemetry, no request leaving the
  machine — unless you explicitly opt in by configuring an external
  provider, or the model calls a network tool like `web_search`.
- **Simple.** Two short scripts, sane defaults, no config file required
  to get the first conversation going.
- **Gentle learning curve.** Defaults work without a config file. The
  surface area grows as you grow into it: start by chatting, then add
  a search API key when you want better results, then edit the system
  prompt when you want to specialise behaviour.
- **Teaches you how to use it.** [GETTING_STARTED.md](GETTING_STARTED.md)
  walks you from zero — a fresh checkout, no model running — to a
  working personal assistant: installing the local model server,
  asking your first question, understanding what each bundled tool
  does, and choosing a search backend that matches your privacy
  comfort level.

## Curious how the agentic loop actually works?

Pikuri sits on top of [ruby_llm](https://rubyllm.com), which owns the
Thought → Tool-call → Observation loop. If you want to *learn* how
that loop works internally — minimal code, no extension surface,
nothing to wade through — read
[agentic-loop-demo](https://codeberg.org/mvysny/agentic-loop-demo).
It's the same author's small didactic project, written precisely so
the source is the lesson. Pikuri is the production-shaped sibling:
same loop, plus tools, listeners, sub-agents, and ergonomics.

## Beyond the toy

`pikuri-chat` builds your understanding of pikuri's underpinnings,
but it's just a toy. The real fun lives in the sibling gems —
each one's README walks through what it adds:

- [`pikuri-code`](pikuri-code/README.md) — an in-repo coding
  agent (read/write/edit/grep/glob/bash + sub-agents + Agent
  Skills). The README covers wiring, the REPL, and a candid
  threat-model section: this is a tech demo, not a hardened
  tool. **Read the security notes before you point it at a
  sensitive checkout.**
- [`pikuri-assistant`](pikuri-assistant/README.md) — an
  MCP-aware demo binary. The intended endgame is an assistant
  with access to your private documents, email, and memory; for
  now it's a `pikuri-chat` lookalike that connects to whatever
  MCP servers you wire into its `Pikuri::Mcp::Registry`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run the test
suite and how releases work.
