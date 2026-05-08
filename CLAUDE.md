# CLAUDE.md

## What this project is

A small, educational Ruby reimplementation of HuggingFace's
[smolagents](https://github.com/huggingface/smolagents). The goal is for the
author to learn, hands-on, how LLMs accomplish tasks by calling tools — not to
ship a production agent framework. Keep code compact and readable; favor clarity
over generality.

## Scope decisions

- **ToolCallingAgent only.** The classic agent loop where the LLM emits a
  structured tool call, the host executes the tool, and the result is fed back
  as the next observation.
- **No CodeAgent.** smolagents' CodeAgent has the model emit Python that the
  host executes; sandboxing that safely (containers, syscall filters) is out of
  scope for a learning project. Don't add it.
- **OpenAI-compatible APIs only.** Target backends are local
  [llama.cpp](https://github.com/ggml-org/llama.cpp) (its OpenAI-compatible HTTP
  server) and [x.ai](https://x.ai). Both speak the OpenAI Chat Completions
  shape, so `OpenAIClient` is the single transport. No provider-specific SDKs.

## Layout

- `lib/openai_client.rb` — thin Faraday wrapper around `POST /chat/completions`.
  Returns a `Response` Data object with `message` and `reasoning` (the latter
  carries `reasoning_content` from models that expose it, e.g. Qwen3 thinking).
- `run.rb` — manual smoke-test entry point. Points at a local llama.cpp server,
  loads `prompt.txt`, prints the model's reasoning (dim) and final message.
- `prompt.txt` / `prompt0.txt` — captured smolagents-style system prompts used
  as fixtures while studying the prompt structure.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Faraday
  for HTTP, Rainbow for terminal color.
- **`# frozen_string_literal: true`** at the top of every Ruby file (`lib/`,
  `spec/`, `run.rb`, etc.). Add it to any new file you create.
- **YARD docs on every public module, class, and method.** Use concrete
  types in `@param` and `@return` (`String`, `Integer`, `Array<Hash>`,
  `Faraday::Connection`, `String, nil`) — never bare `Object` or `Any`.
  Document expected exceptions with `@raise`. One-line summary first, then
  blank line, then tags. This applies to `lib/`; `run.rb` and `spec/` files
  don't need it (no public API).
- **Bundler.** Run things via `bundle exec ruby run.rb`. Add gems to `Gemfile`
  with conservative pessimistic constraints (`~>`).
- **Errors are loud.** On unexpected API responses, raise with the offending
  body included — this is a learning tool, silent fallbacks hide what the model
  actually did.
- **Tests: rspec-core with minitest-style asserts.** Use the `rspec-core`
  runner (`describe`/`it`) but write assertions in the minitest style
  (`assert_equal`, `assert`, `refute`, …) rather than RSpec matchers
  (`expect(...).to eq`). When adding the test stack, wire `rspec-core` +
  `minitest/assertions` together; don't pull in `rspec-expectations`.

## Working on this codebase

- This is a study project — prefer the simplest implementation that
  demonstrates the concept. Don't add abstraction layers, plugin systems, or
  configuration knobs that aren't needed for the next concrete step.
- Don't introduce non-OpenAI-compatible providers or a CodeAgent path without
  an explicit ask.
- When touching the agent loop, keep the Thought / Tool-call / Observation
  cycle visible in the code structure — readability beats cleverness.
