# CLAUDE.md

## What this project is

A Ruby implementation of a general-purpose AI assistant. Pikuri sits on
top of [ruby_llm](https://rubyllm.com) — the gem owns the transport and
the Thought / Tool-call / Observation loop — and adds the *extension
surface*: strict tool-argument validation with LLM-actionable error
messages, listener-based rendering of reasoning / assistant Markdown /
tool calls, a `max_steps` budget, sub-agents, and a small set of solid
bundled tools.

## Scope decisions

- **Reuse ruby_llm as runtime; pikuri owns the extension surface and
  the strict validation.** ruby_llm 1.15 handles the chat loop, tool
  invocation, reasoning extraction, and the OpenAI / Anthropic /
  local-server matrix. Pikuri's job is the layer above: tool ergonomics
  (`Tool.new` + `Tool::Parameters`), the rendering callbacks, sub-agent
  isolation, and the LLM-actionable error messages the model sees on
  bad arguments.

- **The seam.** All `RubyLLM::*` references are confined to three
  files: `bin/pikuri` (boot/wiring — calls `RubyLLM.configure`),
  `lib/agent.rb` (constructs the Chat, attaches listeners, calls
  `ask`), and `lib/tool.rb` (the `Tool` value class plus its
  `#to_ruby_llm_tool` adapter that emits a synthetic `RubyLLM::Tool`
  subclass on demand). Everything else in `lib/` (bundled tools,
  scrapers, search providers) talks to pikuri's surface (`Tool.new`,
  `Tool::Parameters`, …) and never references ruby_llm. This is the
  fork-or-swap contingency: replacing the loop becomes a fixed-cost
  rewrite of those two `lib/` files.

- **Streaming, multi-provider config, vision/audio, embeddings — out
  of scope.** Available via ruby_llm if/when needed; not part of
  pikuri today.

## Layout

Per-file rationale lives in each source file's YARD header — this is just the
package map. The two halves of the codebase are the agent runtime (`lib/agent.rb`
+ `lib/agent/`) and the tool framework with its bundled tools (`lib/tool.rb` +
`lib/tool/`); the rest of `lib/` is boot and a small shared cache.

- `lib/pikuri.rb` — Zeitwerk loader + eager-load over `lib/`; one require for
  callers. Inflector overrides cover acronym mismatches (`HTML`, `PDF`,
  `DuckDuckGo`).
- `lib/agent.rb`, `lib/agent/` — `Agent`, `ListenerList`, the `Message`
  variants (`User`/`Thinking`/`Assistant`/`ToolCall`/`ToolResult`/`FallbackNotice`),
  the `Listener::*` set (`MessageListener` base, `Terminal`, `InMemoryList`,
  `StepLimit`), and `Synthesizer` (the step-exhaustion rescue). The
  Thought/Tool-call/Observation loop lives in ruby_llm; everything here is the
  listener surface around it.
- `lib/tool.rb`, `lib/tool/parameters.rb`, `lib/tool/sub_agent.rb` — `Tool`
  value class with its `#to_ruby_llm_tool` adapter, the strict `Parameters`
  builder/validator, and `Tool::SubAgent < Tool` — instantiated by
  `Agent#allow_sub_agent` with the parent agent itself, no kwargs explosion.
- `lib/tool/calculator.rb`, `lib/tool/web_search.rb`, `lib/tool/web_scrape.rb`,
  `lib/tool/fetch.rb` — bundled tool constants (`Tool::CALCULATOR`,
  `Tool::WEB_SEARCH`, `Tool::WEB_SCRAPE`, `Tool::FETCH`).
- `lib/tool/search/` — search providers (`DuckDuckGo`, `Brave`, `Exa`) plus
  the `Engines` cascade and its `Unavailable` fallback protocol.
- `lib/tool/scraper/` — `Simple` content-type-dispatching fetcher, the pure
  `HTML` and `PDF` extractors, and the shared `FetchError`.
- `lib/url_cache.rb` — on-disk TTL cache used by the bundled web tools.
- `bin/pikuri` — CLI entry point: configures ruby_llm for the local llama.cpp
  server, builds an `Agent` wired with `Terminal` + `StepLimit` listeners,
  enables sub-agents, and feeds a question from `ARGV` or stdin.
- `smolagents-system-prompt.txt` / `smolagents-system-prompt-original.txt` —
  the system prompt used by `bin/pikuri`, plus a verbatim upstream reference
  fixture kept under its original filename for traceability.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects,
  Faraday for HTTP, Rainbow for terminal color. ruby_llm is the LLM
  transport — don't add provider-specific SDKs alongside it.
- **`# frozen_string_literal: true`** at the top of every Ruby file
  (`lib/`, `spec/`, `bin/pikuri`, etc.). Add it to any new file you
  create.
- **YARD docs on every public module, class, and method.** Use concrete
  types in `@param` and `@return` (`String`, `Integer`, `Array<Hash>`,
  `Faraday::Connection`, `String, nil`) — never bare `Object` or `Any`.
  Document expected exceptions with `@raise`. One-line summary first,
  then blank line, then tags. This applies to `lib/`; `bin/pikuri` and
  `spec/` files don't need it (no public API).
- **Bundler.** The entry-point script lives in `bin/` and is run
  directly (`./bin/pikuri "question"`); it self-bootstraps via
  `require 'bundler/setup'`, so callers don't need the `bundle exec`
  ceremony. Add gems to `Gemfile` with conservative pessimistic
  constraints (`~>`).
- **Diagnostics go through per-module loggers from
  `Pikuri.logger_for('Name')`.** Each subsystem holds its own
  memoized stdlib `Logger`, tagged with a `progname:` (e.g.
  `LOGGER = Pikuri.logger_for('Engines')`), all writing through
  `Pikuri.log_io` (default `$stderr`). Level resolves as
  `PIKURI_LOG_<NAME>` (e.g. `PIKURI_LOG_ENGINES=debug`) →
  `PIKURI_LOG` → `INFO`. Use these instead of
  `puts`/`warn`/`$stderr.puts` for anything that's a log line rather
  than user-facing output. Listener-driven rendering of the LLM
  stream (assistant Markdown, tool calls, observations) stays on
  stdout via the `Terminal` listener — that's not logging.
- **Errors are loud.** On unexpected internal state, raise with the
  offending data included — silent fallbacks hide what actually
  happened. Tools split this into two buckets: failures the LLM can
  react to (bad arguments, HTTP 4xx/5xx, network blips, search rate-
  limits, division by zero) come back as `"Error: <message>"` Strings
  and become the next observation; bugs in pikuri's own code (parser
  regressions, schema misuse, misconfigured clients) keep raising. The
  LLM cannot fix the second category — a human needs to. ruby_llm
  passes the String through verbatim, so this convention is what the
  model sees. The carve-out: third-party bugs in rendering/display
  paths *secondary to the loop* (e.g. `tty-markdown` choking on an
  ANSI-in-table edge case while rendering assistant output) get
  rescued narrowly, logged as a warning via `Pikuri.logger_for(...)`
  with the exception class and message, and fall back to a degraded
  rendering. Raising would abort an in-flight conversation over a
  cosmetic upstream bug we can't fix from here. This does **not**
  extend to errors from libraries on the actual chat path (ruby_llm,
  Faraday inside a tool) — those stay loud.
- **Zeitwerk autoloads everything under `lib/`.** Don't add
  `require_relative` chains inside `lib/`; let the loader resolve
  internal references. The boot file (`lib/pikuri.rb`) eager-loads at
  startup so `ALL_CAPS` value constants (`Tool::CALCULATOR`, …) are
  defined alongside the autoloadable classes/modules. New files must
  define exactly the camelcased constant matching their path; if you
  want an acronym (`HTML`, `PDF`, `DuckDuckGo`), add an entry to the
  `inflector.inflect` block in `lib/pikuri.rb`.
- **Tests: rspec-core with minitest-style asserts.** Use the
  `rspec-core` runner (`describe`/`it`) but write assertions in the
  minitest style (`assert_equal`, `assert`, `refute`, …) rather than
  RSpec matchers (`expect(...).to eq`). rspec-mocks is *not* in the
  closure — to stub a module method like `RubyLLM.chat` in a spec,
  replace the singleton method with `define_singleton_method` in
  `before` and restore in `after`. See `spec/agent_spec.rb` for the
  pattern.

- **Tool descriptions follow opencode-shape: summary + `Usage:` bullets.**
  A `description:` heredoc with a one-line summary, a blank line,
  then a `Usage:` bullet list. Use `Do NOT` / `ALL` capitalization
  sparingly on bullets where the LLM commonly errs. Keep facts in
  their semantic home — the tool description is for "when do I pick
  this? how does it chain with other tools?"; per-argument constraints
  (defaults, caps, value format) live in the parameter description and
  must NOT be duplicated in the tool description. Universal failure-
  recovery guidance ("on `Error: ...`, use what you have or admit
  defeat to the user") lives in `smolagents-system-prompt.txt`, not
  per-tool. Add an example value (`'..., e.g. "https://example.com"'`)
  to every parameter description; the LLM's argument-filling reliability
  is measurably better with one.

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** When
  changing `lib/agent.rb`, the question is "what hooks fire when?" —
  the iteration itself lives in `RubyLLM::Chat#complete`. Don't
  reimplement the loop in pikuri; reach for a different listener
  instead.
- **Readable, not obfuscated.** Prefer the simplest implementation that
  does the job. Don't golf code for line count, but also don't add
  abstraction layers, plugin systems, or configuration knobs that
  aren't needed for the next concrete step.
- **Grow the assistant by adding tools and listeners, not by
  complicating the loop.** New capabilities should land as new `Tool`
  constants under `lib/tool/` or new listeners under
  `lib/agent/listener/`, each with their own specs; neither `Tool`,
  the `Agent`, nor ruby_llm's loop should need to know about them.
