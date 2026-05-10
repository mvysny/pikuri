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

- `lib/pikuri.rb` — boot file. Configures a Zeitwerk loader over the
  whole `lib/` tree and eager-loads it, so `require 'pikuri'` is the
  one require any caller needs. Inflector overrides cover the
  acronym/camelCase mismatches (`HTML`, `PDF`, `DuckDuckGo`); eager-
  loading is the design choice that lets `Tool::CALCULATOR` /
  `WEB_SEARCH` / `WEB_SCRAPE` / `FETCH` be `ALL_CAPS` value constants
  rather than classes Zeitwerk could autoload on its own.
- `lib/agent.rb` — thin wrapper around `RubyLLM::Chat`. The ctor builds
  a Chat, registers system prompt and tools on it, and installs three
  listeners: `after_message` renders reasoning (dim) + assistant
  content (Markdown via tty-markdown), `before_tool_call` prints the
  cyan `→ name(args)` line and increments the `max_steps` counter
  (raises on overrun — ruby_llm has no built-in step budget),
  `after_tool_result` prints the cyan `= result` line.
  `Agent#run_loop(user_message:)` resets the counter and forwards to
  `Chat#ask`. `Agent#last_assistant_content` walks `Chat#messages` for
  the sub-agent's final-reply needs.
- `lib/tool.rb` — `Tool` is a plain value class with `name`,
  `description`, `parameters`, and an `execute` Proc. `Tool#run(args)`
  validates via `Parameters#validate` and forwards to `execute`,
  catching `Parameters::ValidationError` and returning it as
  `"Error: ..."` so the LLM sees a self-correctable observation.
  `Tool#to_ruby_llm_tool` is the named adapter the `Agent` calls when
  wiring a tool into the underlying `RubyLLM::Chat`: it builds an
  anonymous `RubyLLM::Tool` subclass whose `execute(**args)` delegates
  back to `#run` on the originating instance. The `**args` keyrest
  signature makes ruby_llm's keyword-presence checker no-op so
  pikuri's `Parameters` validator (DidYouMean, type coercion, all
  errors collected) is what the LLM sees on bad input.
- `lib/tool/parameters.rb` — `Tool::Parameters`: fluent builder
  (`required_string`, `optional_integer`, `required_number`, …) that
  emits OpenAI JSON-Schema via `to_h` and validates LLM-supplied
  argument hashes via `validate`. Strict: unknown keys rejected (with
  DidYouMean suggestions), wrong types rejected, all errors collected
  and reported together with the schema reprinted — so the message
  can be fed back to the LLM verbatim as the next observation.
- `lib/tool/sub_agent.rb` — `Tool::SubAgent.build(model:,
  system_prompt:, tools:, max_steps:)` factory (with a one-line
  `Tool.sub_agent` alias at the `Tool` level). Each call returns a
  fresh `Tool` whose `execute` Proc spawns a fresh `Agent` (and
  therefore a fresh `RubyLLM::Chat` with its own
  `messages`/`tools`/listeners), runs the requested task on a clean
  conversation, and returns only the sub-agent's final assistant
  message back as the parent's next observation. Wired in via
  `Agent#allow_sub_agent`.
- `lib/tool/` — bundled tool implementations, each reopening
  `class Tool` to add a module + a single `Tool` constant. Currently:
  `Tool::CALCULATOR` (Dentaku-backed arithmetic, with `**` → `^`
  rewriting and BigDecimal results rounded to 3 places),
  `Tool::WEB_SEARCH` (LLM-facing web-search tool; see
  `lib/tool/web_search.rb` plus `lib/tool/search/engines.rb` for the
  cascade and `lib/tool/search/` for individual providers),
  `Tool::WEB_SCRAPE` and `Tool::FETCH` (HTML/PDF→Markdown via Faraday
  + readability + reverse_markdown; see `lib/tool/scraper/`), and the
  `Tool.sub_agent(...)` factory described above.
- `lib/tool/search/engines.rb` — `Tool::Search::Engines`: the
  search-orchestration entry point. Defines
  `Tool::Search::Engines::Unavailable` (raised by providers on
  rate-limit / bot-block / quota-exhausted), `Engines.providers`
  (DuckDuckGo always, Brave when `BRAVE_SEARCH_API_KEY` is set,
  recomputed every call), and `Engines.search`, which runs the
  cascade: shuffles `providers` randomly, tries each until one
  succeeds, falling back only on `Unavailable`. Anything else (network
  errors, parse failures, bad API keys returning 401/403) bubbles up
  as the original exception. If every provider reports `Unavailable`,
  returns an `"Error: ..."` string so the agent loop can feed the
  failure back to the model as the next observation. The `Tool::Search`
  namespace itself is implicit — Zeitwerk creates it from the
  directory's existence.
- `lib/tool/web_search.rb` — defines the LLM-facing `Tool::WEB_SEARCH`
  constant (a thin wrapper that calls `Tool::Search::Engines.search`).
  The cascade itself lives in `lib/tool/search/engines.rb`; this
  file owns only the OpenAI tool-call shape.
- `lib/tool/search/` — search-provider modules. Each exposes
  `.search(query, max_results:)` returning the same smolagents-style
  Markdown shape so the LLM sees a stable format, and raises
  `Tool::Search::Engines::Unavailable` on rate-limit / bot-block /
  quota signals (DDG anomaly modal, HTTP 429, HTTP 5xx). Currently:
  `Tool::Search::DuckDuckGo` (HTML scrape of `html.duckduckgo.com`,
  throttled to one request every 2s, prone to IP soft-blocks) and
  `Tool::Search::Brave` (official Web Search API with
  `X-Subscription-Token`).
- `lib/tool/web_scrape.rb` and `lib/tool/fetch.rb` — define
  `Tool::WEB_SCRAPE` and `Tool::FETCH`, both thin wrappers over
  `Tool::Scraper::Simple.visit`: cache the rendered Markdown on disk
  via `UrlCache`, truncate to `max_chars`, and turn
  `Scraper::FetchError` into `"Error: ..."` observations so the agent
  loop feeds the failure back to the model instead of crashing.
- `lib/tool/scraper/fetch_error.rb` — `Tool::Scraper::FetchError`,
  the shared exception raised across the scraper stack (HTTP 4xx/5xx,
  network failure, redirect-loop, missing `Location`, unsupported
  content-type, parse failure that reads as "try a different URL" to
  the LLM). Caught in `Tool::WEB_SCRAPE` / `Tool::FETCH` and turned
  into `"Error: ..."` observations; everything else bubbles up so
  genuine bugs stay visible. The `Tool::Scraper` namespace itself is
  implicit — Zeitwerk creates it from the directory's existence.
- `lib/tool/scraper/simple.rb` — content-type-dispatching HTTP scraper.
  `Simple.fetch(url)` returns a `Simple::Fetched` (`body`,
  `content_type`, final `url` after redirects); `Simple.visit(url)`
  fetches and routes the response to the right extractor by
  `content_type`. Routes `text/html`/`application/xhtml+xml` to
  `Scraper::HTML`, `application/pdf` to `Scraper::PDF`, and any other
  `text/*` body (plain text, Markdown, source files, …) is passed
  through verbatim since the LLM can already read it; remaining types
  raise `Scraper::FetchError` with a legible message. "Simple" because
  everything is one Faraday GET — no headless browser, no JS.
- `lib/tool/scraper/html.rb` — pure HTML→Markdown extractor.
  `HTML.extract(html)` runs a JSON-LD fast path (preferring schema.org
  `Product`/`Article`/`Recipe`/... nodes that carry a
  `description`/`articleBody`/`offers`) and falls back to a
  `Readability` + `reverse_markdown` rendering. No I/O — drive it from
  fixture HTML.
- `lib/tool/scraper/pdf.rb` — pure PDF→text extractor. `PDF.extract(bytes)`
  uses `pdf-reader` to walk every page and concatenate the extracted
  text. No OCR, so scanned PDFs come back empty. Re-raises
  `pdf-reader`'s `MalformedPDFError`/`InvalidPageError`/
  `UnsupportedFeatureError` as `Scraper::FetchError` so the LLM treats
  unparseable PDFs the same way it treats HTTP 4xx — try a different
  URL.
- `bin/pikuri` — entry-point script. Configures ruby_llm's OpenAI
  provider via `RubyLLM.configure { |c| c.openai_api_base = ...;
  c.openai_api_key = ... }` for the local llama.cpp server, builds an
  `Agent` with `model:`/`provider:`/`assume_model_exists:`/
  `system_prompt:`/`tools:`, enables sub-agents via
  `agent.allow_sub_agent`, and feeds it a question from `ARGV` or stdin.
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
- **Errors are loud.** On unexpected internal state, raise with the
  offending data included — silent fallbacks hide what actually
  happened. Tools split this into two buckets: failures the LLM can
  react to (bad arguments, HTTP 4xx/5xx, network blips, search rate-
  limits, division by zero) come back as `"Error: <message>"` Strings
  and become the next observation; bugs in pikuri's own code (parser
  regressions, schema misuse, misconfigured clients) keep raising. The
  LLM cannot fix the second category — a human needs to. ruby_llm
  passes the String through verbatim, so this convention is what the
  model sees.
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

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** When
  changing `lib/agent.rb`, the question is "what hooks fire when?" —
  the iteration itself lives in `RubyLLM::Chat#complete`. Don't
  reimplement the loop in pikuri; reach for a different listener
  instead.
- **Validation ordering is load-bearing.** Pikuri's
  `Parameters#validate` is what produces the LLM-facing error message;
  ruby_llm's keyword-presence checker is bypassed by the `**args`
  keyrest signature on the synthetic class's `execute` (built by
  `Tool#to_ruby_llm_tool`). When touching `lib/tool.rb`, preserve that
  — DidYouMean / coercion / all-errors-collected only work if pikuri's
  validator runs first.
- **Readable, not obfuscated.** Prefer the simplest implementation that
  does the job. Don't golf code for line count, but also don't add
  abstraction layers, plugin systems, or configuration knobs that
  aren't needed for the next concrete step.
- **Grow the assistant by adding tools, not by complicating the loop.**
  New capabilities should land as new `Tool` constants under
  `lib/tool/` with their own specs; neither `Tool` itself nor
  ruby_llm's loop should need to know about them.

## Risks worth tracking

- **`RubyLLM::Chat` API churn.** Pikuri couples to Chat semantics
  (listener names, message/thinking shapes, `with_tool` taking a
  class). Watch minor releases — 1.15 already normalized token field
  names, that's the failure mode to expect. Pin reads here would
  surface in the listener wiring or the synthetic-tool factory.
- **Synthetic-tool fragility.** If ruby_llm refactors its tool DSL
  (how `params(hash)` accepts a raw schema, the keyrest bypass on
  `validate_keyword_arguments`, or how `execute` is invoked),
  `Tool#to_ruby_llm_tool` in `lib/tool.rb` breaks. The seam contains
  the blast — the break is in one file, not spread across the
  codebase.
