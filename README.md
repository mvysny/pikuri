# pikuri

A small Ruby AI assistant you run on your own machine. `bin/pikuri-chat`
is a general-purpose chatbot with a calculator, web search, web
scraping, and a fetch tool — wired by default to a
[llama.cpp](https://github.com/ggml-org/llama.cpp) server running
locally, so the conversation never leaves your computer unless the
model itself decides to call a tool.

## Quick start

```sh
git clone https://github.com/mvysny/pikuri.git
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

## Tests

```sh
bundle exec rspec
```
