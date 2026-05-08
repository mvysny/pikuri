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

- `lib/agent.rb` — the Thought / Tool-call / Observation loop. `Agent#run_loop`
  appends a user turn to its `ChatLog`, asks the model, runs any tool calls,
  feeds observations back, and repeats until `:stop` or `max_steps`. Prints
  reasoning (dim), assistant messages (Markdown via tty-markdown), and tool
  invocations (cyan) as they happen.
- `lib/chat_log.rb` — append-only conversation history. `ChatLog::Message` is a
  validated `Data.define` covering the four roles (`:system`, `:user`,
  `:assistant`, `:tool`); illegal role/field combinations raise in the
  constructor so any `Message` that exists is structurally legal. Protocol-
  agnostic: knows nothing about OpenAI wire format.
- `lib/openai_client.rb` — thin Faraday wrapper around `POST /chat/completions`.
  Owns the `ChatLog` → request-body translation (the per-role wire shape lives
  in `request_body`/`message_to_h`), and delegates response parsing to
  `ChatParser`.
- `lib/chat_response.rb` — `ChatResponse` Data object plus `ChatParser`. Parses
  one non-streaming choice into `finish_reason` (`:stop`, `:tool_calls`,
  `:length`, `:content_filter`), `message`, `reasoning` (`reasoning_content`
  from thinking models, e.g. Qwen3), and resolved `ChatResponse::ToolCall`s.
- `lib/tool.rb` — `Tool` value object (`Data.define(:name, :description,
  :parameters, :execute)`). Tools are stateless single-instance constants, not
  subclasses. `Tool#run(args)` validates against the schema and calls `execute`.
- `lib/tool/parameters.rb` — `Tool::Parameters`: fluent builder
  (`required_string`, `optional_integer`, `required_number`, …) that emits
  OpenAI JSON-Schema via `to_h` and validates LLM-supplied argument hashes via
  `validate`. Strict: unknown keys rejected (with DidYouMean suggestions),
  wrong types rejected, all errors collected and reported together with the
  schema reprinted — so the message can be fed back to the LLM verbatim as the
  next observation.
- `lib/tool/` — bundled tool implementations, each reopening `class Tool` to
  add a module + a single `Tool` constant. Currently: `Tool::CALCULATOR`
  (Dentaku-backed arithmetic, with `**` → `^` rewriting and BigDecimal results
  rounded to 3 places) and `Tool::WEB_SEARCH` (DuckDuckGo HTML scrape via
  Nokogiri, throttled to one request every 2s, rendered as smolagents-style
  Markdown). Required explicitly by the scripts that use them.
- `run.rb` — minimal smoke test: a single inline `get_weather` tool against a
  local llama.cpp server, exercising the full agent loop end-to-end.
- `run-leopard.rb` — fuller smoke test using `Tool::WEB_SEARCH` +
  `Tool::CALCULATOR` and the smolagents-style system prompt.
- `smolagents-system-prompt.txt` / `smolagents-system-prompt-original.txt` —
  the prompt actually used by `run-leopard.rb`, plus the verbatim original
  from upstream smolagents kept as a reference fixture.

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
