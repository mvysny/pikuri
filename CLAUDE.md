# CLAUDE.md

## What this project is

A Ruby implementation of a general-purpose AI assistant built around the
Thought / Tool-call / Observation loop, talking to any OpenAI-compatible
backend. The aim is a usable, well-structured assistant: a clean agent loop,
a small set of solid tools, and code that stays readable as the surface
area grows.

## Scope decisions

- **OpenAI-compatible APIs only.** Target backends are local
  [llama.cpp](https://github.com/ggml-org/llama.cpp) (its OpenAI-compatible
  HTTP server) and [x.ai](https://x.ai). Both speak the OpenAI Chat
  Completions shape, so `OpenAIClient` is the single transport. No
  provider-specific SDKs.

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
  rounded to 3 places), `Tool::WEB_SEARCH` (provider-pluggable web search;
  see `lib/tool/websearch.rb` and `lib/tool/search/`), and
  `Tool.delegate(...)` (factory: spawns a fresh sub-`Agent` on a clean
  `ChatLog` and returns only its final assistant message as the parent's
  next observation).
- `lib/tool/websearch.rb` — defines `Tool::WEB_SEARCH` and `Tool::Search.provider`,
  which picks a provider based on which API tokens are present in ENV
  (Brave when `BRAVE_SEARCH_API_KEY` is set, otherwise DuckDuckGo). The
  selection is by-token, not runtime cascade — if the chosen provider
  fails the call fails.
- `lib/tool/search/` — search-provider modules. Each exposes
  `.search(query, max_results:)` returning the same smolagents-style Markdown
  shape so the LLM sees a stable format. Currently: `Tool::Search::DuckDuckGo`
  (HTML scrape of `html.duckduckgo.com`, throttled to one request every 2s,
  prone to IP soft-blocks) and `Tool::Search::Brave` (official Web Search API
  with `X-Subscription-Token`).
- `pikuri.rb` — entry-point script. Wires `OpenAIClient` to a local llama.cpp
  server, builds an `Agent` with `Tool::WEB_SEARCH` + `Tool::CALCULATOR` and
  delegation enabled, and feeds it a question from `ARGV` or stdin.
- `smolagents-system-prompt.txt` / `smolagents-system-prompt-original.txt` —
  the system prompt used by `pikuri.rb`, plus a verbatim upstream reference
  fixture kept under its original filename for traceability.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Faraday
  for HTTP, Rainbow for terminal color.
- **`# frozen_string_literal: true`** at the top of every Ruby file (`lib/`,
  `spec/`, `pikuri.rb`, etc.). Add it to any new file you create.
- **YARD docs on every public module, class, and method.** Use concrete
  types in `@param` and `@return` (`String`, `Integer`, `Array<Hash>`,
  `Faraday::Connection`, `String, nil`) — never bare `Object` or `Any`.
  Document expected exceptions with `@raise`. One-line summary first, then
  blank line, then tags. This applies to `lib/`; `pikuri.rb` and `spec/`
  files don't need it (no public API).
- **Bundler.** Run things via `bundle exec ruby pikuri.rb`. Add gems to
  `Gemfile` with conservative pessimistic constraints (`~>`).
- **Errors are loud.** On unexpected API responses, raise with the offending
  body included — silent fallbacks hide what the model actually did.
- **Tests: rspec-core with minitest-style asserts.** Use the `rspec-core`
  runner (`describe`/`it`) but write assertions in the minitest style
  (`assert_equal`, `assert`, `refute`, …) rather than RSpec matchers
  (`expect(...).to eq`). When adding the test stack, wire `rspec-core` +
  `minitest/assertions` together; don't pull in `rspec-expectations`.

## Working on this codebase

- **The agent loop is the spine.** The Thought / Tool-call / Observation
  cycle is what everything else hangs off — keep it legible at a glance
  when touching `lib/agent.rb`.
- **Readable, not obfuscated.** Prefer the simplest implementation that
  does the job. Don't golf code for line count, but also don't add
  abstraction layers, plugin systems, or configuration knobs that aren't
  needed for the next concrete step.
- **Grow the assistant by adding tools, not by complicating the loop.** New
  capabilities should land as new `Tool` constants under `lib/tool/` with
  their own specs; the loop itself shouldn't need to know about them.
