# CLAUDE.md

## What this project is

A Ruby implementation of an AI assistant, shipped as two binaries on a
shared core: `bin/pikuri-chat` (general-purpose chat — web search,
scraping, calculator, sub-agents) and `bin/pikuri-code` (in-repo coding
agent — read/write/edit/grep/glob/bash, plus the web tools). Both wire
the same `Agent`, the same `Tool` framework, and the same ruby_llm
runtime; they differ only in their system prompt and which tools they
register.

Pikuri sits on top of [ruby_llm](https://rubyllm.com) — the gem owns
the transport and the Thought / Tool-call / Observation loop — and
adds the *extension surface*: strict tool-argument validation with
LLM-actionable error messages, listener-based rendering of reasoning /
assistant Markdown / tool calls, a `max_steps` budget, sub-agents, and
a small set of solid bundled tools.

## Why this exists

The motivating frustration: the existing agent stacks (the "PI" and
"OpenClaw" projects) have grown big and now have a very steep
learning curve. A privacy-conscious user arriving fresh hits a wall
of massive JSON configuration with no clear start-here. Pikuri is
the deliberate counter-move:

- **Start slowly.** Sane defaults out of the box, two small binaries,
  no config file required to get a first conversation going. The
  surface area grows as the user grows into it, not before.
- **Privacy-first.** Defaults wire the local llama.cpp server — no
  cloud account, no API key, no telemetry, no request leaving the
  machine unless the user explicitly opts in by configuring an
  external provider via ruby_llm.
- **Educates along the way.** The code is meant to be read: per-file
  YARD headers explain *why* each piece exists, the system prompts
  are plain text checked into `prompts/`, and the conventions in this
  document are deliberately verbose so the project doubles as a tour
  of how a small agent runtime actually works.
- **Small enough to audit.** A privacy-conscious user should be able
  to read pikuri's sources end-to-end in an evening — and then decide
  it's safe to run on their actual machine, outside any sandbox.
  That target sets a hard ceiling on scope: every new feature is
  weighed against the line count it adds to the read-it-yourself
  surface. Abstraction layers that exist "just in case" lose every
  argument; concrete code that does one named thing wins. The
  reference points to learn from (opencode, PI; see below) are
  studied for ideas, not copied at scale.

## Reference projects

When designing new pikuri features, the closest prior art to mine for
good ideas is:

- **opencode** — <https://github.com/anomalyco/opencode/>. TypeScript /
  Effect-TS / Bun. Worth studying for: tool registry shape, skill loading
  (dedicated `skill` tool whose description is dynamically populated with
  the available-skill list), permission system.
- **PI** — <https://github.com/earendil-works/pi>. TypeScript / Bun.
  Worth studying for: Agent Skills standard implementation (skill
  discovery + validation + `<available_skills>` injection into the
  system prompt), `.agents/` cross-harness skill directory convention.

Both implement the [Agent Skills standard](https://agentskills.io/specification),
which is also what Claude Code follows — useful baseline if pikuri ever
grows a skill system.

## Scope decisions

- **Reuse ruby_llm as runtime; pikuri owns the extension surface and
  the strict validation.** ruby_llm 1.15 handles the chat loop, tool
  invocation, reasoning extraction, and the OpenAI / Anthropic /
  local-server matrix. Pikuri's job is the layer above: tool ergonomics
  (`Pikuri::Tool.new` + `Pikuri::Tool::Parameters`), the rendering
  callbacks, sub-agent isolation, and the LLM-actionable error messages
  the model sees on bad arguments.

- **The seam.** All `RubyLLM::*` references are confined to four
  files: `bin/pikuri-chat` and `bin/pikuri-code` (boot/wiring — call
  `RubyLLM.configure`), `lib/pikuri/agent.rb` (constructs the Chat,
  attaches listeners, calls `ask`), and `lib/pikuri/tool.rb` (the
  `Pikuri::Tool` value class plus its `#to_ruby_llm_tool` adapter that
  emits a synthetic `RubyLLM::Tool` subclass on demand). Everything
  else in `lib/` (bundled tools, scrapers, search providers) talks to
  pikuri's surface (`Pikuri::Tool.new`, `Pikuri::Tool::Parameters`, …)
  and never references ruby_llm. This is the fork-or-swap contingency:
  replacing the loop becomes a fixed-cost rewrite of those two `lib/`
  files.

- **Subprocess seam.** All subprocess spawning in `lib/` goes through
  `Pikuri::Subprocess.spawn`. Direct `Process.spawn` / `Open3.*` /
  `system` / backticks anywhere in `lib/` are bugs. The chokepoint
  forces a new process group per invocation, tracks pgids in a
  process-global set, and SIGTERMs everything tracked via `at_exit`
  so backgrounded shell children don't outlive pikuri uncontrolled.
  Timeouts are the caller's job — wrap argv with coreutils' `timeout`
  binary; the chokepoint deliberately doesn't implement a Ruby-side
  timeout (can't kill subprocesses cleanly). Grep-enforceable:
  `grep -rn 'Process\.spawn\|Open3\|system' lib/` should only hit
  `lib/pikuri/subprocess.rb`.

  *Carve-out:* `Pikuri::McpServers` is the documented exception, and
  only for stdio MCP entries (`McpRegistry::StdioEntry`). The `mcp` gem
  spawns the server via its own `MCP::Client::Stdio` transport —
  routing that through `Subprocess.spawn` would mean forking the gem
  or threading custom IO pipes through its API, duplicating work the
  gem exists to do. Instead, `McpServers#initialize` registers
  `at_exit { close }` and `#close` calls the gem's per-transport
  `close` (which closes stdin → server hits EOF and self-terminates
  per spec). The grep invariant above still holds because the spawn
  happens inside the gem, not in pikuri's `lib/`. HTTP MCP entries
  (`McpRegistry::HttpEntry`) don't fall under the carve-out — they're
  plain Faraday inside the gem, no subprocess involved. See IDEAS.md
  §"v1 implementation shape" / "Subprocess lifecycle" for the full
  rationale.

- **Workspace seam.** Tools that touch files (`Read`, `Write`, `Edit`,
  `Grep`, `Glob`, `Bash`) take a `Pikuri::Tool::Workspace` via
  constructor and route every path through `#resolve_for_read(path)` /
  `#resolve_for_write(path)` before touching the filesystem. The
  bundled `Pikuri::Tool::Workspace::Cwd.new(root:)` locks reads +
  writes to the launch directory's subtree, rejecting `..`-escapes
  and symlinks that resolve outside the root. The seam exists so a
  future in-editor pikuri can swap in a workspace mirroring the IDE's
  open project root or a virtual filesystem without rewriting tool
  guts.

- **Confirmer seam.** Tools that mutate user state (`Write`, `Bash`)
  take a `Pikuri::Tool::Confirmer` via constructor and route every
  prompt through `#confirm?(prompt:)` — never `gets` / `puts` /
  `$stdin` / `$stdout` directly. Two bundled implementations:
  `Pikuri::Tool::Confirmer::TERMINAL` (prompts on stdin/stdout) and
  `Pikuri::Tool::Confirmer::AUTO_APPROVE` (yes-to-everything; used by
  `--yolo` mode and specs). Same rationale as the workspace seam: a
  later TUI / IDE host plugs in by writing a new `Confirmer` subclass,
  not by editing tool internals.

- **Streaming is opt-in via `Agent.new(..., streaming: true)`.** When
  true, `Agent#run_loop` passes a streaming block to `Chat#ask` and
  the per-chunk `Event::ThinkingDelta` / `Event::AssistantDelta`
  deltas flow on the listener stream alongside the message-level
  `Event::Thinking` / `Event::Assistant` bookends. The flag
  propagates to `Synthesizer.run` and `Tool::SubAgent` so the whole
  agent tree streams or doesn't, consistently. Defaults to `false`
  because the bundled `Terminal` listener still renders the full
  message on `Event::Assistant`; a future delta-renderer mode will
  flip the bundled bins to `streaming: true`.

- **Multi-provider config, vision/audio, embeddings — out of scope.**
  Available via ruby_llm if/when needed; not part of pikuri today.

- **Linux-first; macOS may work; Windows is unsupported.** Pikuri
  targets Linux as the primary platform. macOS will probably keep
  working day-to-day, but the test matrix is Linux and the eventual
  sandbox layer (Docker / bubblewrap for the Bash tool) is Linux-
  specific. Windows is out of scope — pikuri assumes a POSIX shell,
  GNU coreutils' +timeout+, XDG cache layout, and SIGTERM-based
  process-group cleanup; porting these would dilute the rest of the
  project. CI and bug reports follow the same prioritization.

## Layout

Per-file rationale lives in each source file's YARD header — this is just the
package map. Everything pikuri ships lives under the `Pikuri::` namespace:
`lib/pikuri.rb` is the boot file, and `lib/pikuri/**/*.rb` is loaded by
Zeitwerk into the matching `Pikuri::*` constants. The two halves of the
codebase are the agent runtime (`lib/pikuri/agent.rb` + `lib/pikuri/agent/`)
and the tool framework with its bundled tools (`lib/pikuri/tool.rb` +
`lib/pikuri/tool/`); the rest of `lib/pikuri/` is the subprocess chokepoint
and a small shared cache.

- `lib/pikuri.rb` — Zeitwerk loader + eager-load over `lib/`; one require for
  callers. Inflector overrides cover acronym mismatches (`HTML`, `PDF`,
  `DuckDuckGo`).
- `lib/pikuri/agent.rb`, `lib/pikuri/agent/` — `Pikuri::Agent`,
  `Pikuri::Agent::ChatTransport` (the `model`/`provider`/`assume_model_exists`
  value bundle passed to every `RubyLLM.chat` originating from an agent),
  `Pikuri::Agent::ContextWindowDetector` (resolves the model's context-window
  cap from override → ruby_llm registry → llama.cpp `/props` probe at
  construction time), `Pikuri::Agent::ListenerList`, the
  `Pikuri::Agent::Event` variants
  (`UserTurn`/`Thinking`/`ThinkingDelta`/`Assistant`/`AssistantDelta`/`ToolCall`/`ToolResult`/`Tokens`/`ContextCap`/`FallbackNotice`/`Cancelled`;
  `UserTurn` carries a `mid_loop` flag — `false` for turn-starting input,
  `true` for `Interloper`-drained mid-loop injections; `*Delta` variants
  only fire when the agent was constructed with `streaming: true`), the pure-consumer
  `Pikuri::Agent::Listener::*` set (`Base`, `Terminal`,
  `InMemoryEventList`, `TokenLog`, `RateLimited`), the host-facing
  `Pikuri::Agent::Control::*` set (`StepLimit`, `Cancellable`,
  `Interloper`), and `Pikuri::Agent::Synthesizer` (the step-exhaustion
  rescue). The Thought/Tool-call/Observation loop lives in ruby_llm;
  the `Agent` wires three callbacks on the chat (via `Agent.wire_chat`
  — used by both `Agent#initialize` and `Synthesizer.run`), emits the
  `Event` stream, and pokes controls at the right boundaries
  (`step_limit.tick!`/`reset!`, `cancellable.check!`/`reset!`,
  `interloper.drain!`). Listeners are pure consumers — they override
  one `on_event(event)` method and never write back; the `Agent` is
  the sole emitter. Two `ListenerList` conventions stay duck-typed
  across the listener set: defining `for_sub_agent(**)` to return
  `self` / a fresh instance / `nil` controls how the listener
  propagates to sub-agents (used by `Terminal` for padding, `TokenLog`
  for name + zero-snapshot). Controls have their own `for_sub_agent`
  per-class — fresh `StepLimit`, shared `Cancellable`, `nil`
  `Interloper`.
- `lib/pikuri/tool.rb`, `lib/pikuri/tool/parameters.rb`,
  `lib/pikuri/tool/sub_agent.rb` — `Pikuri::Tool` value class with its
  `#to_ruby_llm_tool` adapter, the strict `Pikuri::Tool::Parameters`
  builder/validator, and `Pikuri::Tool::SubAgent < Pikuri::Tool` —
  instantiated by `Pikuri::Agent#allow_sub_agent` with the parent agent
  itself, no kwargs explosion.
- `lib/pikuri/tool/calculator.rb`, `lib/pikuri/tool/web_search.rb`,
  `lib/pikuri/tool/web_scrape.rb`, `lib/pikuri/tool/fetch.rb` — bundled
  tool constants (`Pikuri::Tool::CALCULATOR`, `Pikuri::Tool::WEB_SEARCH`,
  `Pikuri::Tool::WEB_SCRAPE`, `Pikuri::Tool::FETCH`).
- `lib/pikuri/tool/search/` — search providers (`DuckDuckGo`, `Brave`,
  `Exa`), the shared `Result` value type they all return, the `RateLimiter`
  pacing + circuit-breaker wrapper a provider can wire in, and the
  `Engines` cascade with its `Unavailable` fallback protocol.
- `lib/pikuri/tool/scraper/` — `Simple` content-type-dispatching fetcher,
  the pure `HTML` and `PDF` extractors, and the shared `FetchError`.
- `lib/pikuri/tool/confirmer.rb`, `lib/pikuri/tool/workspace.rb` — abstract
  bases + bundled implementations for the two coding-tool seams (see Scope
  decisions). `Confirmer` ships `TERMINAL` / `AUTO_APPROVE`; `Workspace`
  ships `Cwd`.
- `lib/pikuri/tool/read.rb`, `lib/pikuri/tool/write.rb`,
  `lib/pikuri/tool/edit.rb`, `lib/pikuri/tool/grep.rb`,
  `lib/pikuri/tool/glob.rb`, `lib/pikuri/tool/bash.rb` — the six coding
  tools. Each is a `Pikuri::Tool` subclass instantiated per-binary with the
  constructor wiring (workspace + confirmer where needed) — same pattern
  as `Pikuri::Tool::SubAgent`, not the bare `ALL_CAPS` constant style used
  by the stateless web/calc tools.
- `lib/pikuri/tool/skill_catalog.rb`, `lib/pikuri/tool/skill.rb` —
  pikuri's implementation of the [Agent Skills standard](https://agentskills.io/specification).
  `Pikuri::Tool::SkillCatalog` is the discovery + validation layer
  (abstract base + bundled `Empty`/`EMPTY` and `Bundled` scanners that
  walk `.pikuri/skills`, `.claude/skills`, `.agents/skills`).
  `Pikuri::Tool::Skill < Pikuri::Tool` is the loading tool, instantiated
  by `Agent#initialize` whenever the wired-in catalog is non-empty;
  same constructor-wiring pattern as `SubAgent` and the coding tools.
  Catalog + tool form a seam: a future host can plug in a synthetic
  catalog (virtual filesystem, in-memory test fixture) without touching
  `Tool::Skill` or `Agent`.
- `lib/pikuri/mcp_registry.rb`, `lib/pikuri/mcp_servers.rb` — MCP
  (Model Context Protocol) support. `Pikuri::McpRegistry` is the pure
  config layer (`Entry = Data.define(:id, :command)`, `EMPTY`
  singleton — same shape as `SkillCatalog::EMPTY`).
  `Pikuri::McpServers` is the runtime: constructed from a registry,
  eager-starts every configured server via the `mcp` gem's
  `MCP::Client::Stdio`, holds the live clients, emits an INFO audit
  log per server, registers `at_exit { close }` for cleanup.
  `McpServers::View` is the sub-agent facade (shares clients,
  delegates lifecycle), and `McpServers::McpConnect` is the private
  inner `Pikuri::Tool` subclass auto-instantiated by `Agent#initialize`
  when the registry is non-empty. MCP tools bypass `Pikuri::Tool`
  entirely — they're synthesised as raw `RubyLLM::Tool` subclasses
  inside `McpServers` and fed in via `Agent#internal_add_tool`. This
  is also the documented exception to the `Subprocess.spawn`
  chokepoint (see Scope decisions). See IDEAS.md §"v1 implementation
  shape" for the full rationale.
- `lib/pikuri/subprocess.rb` — `Pikuri::Subprocess.spawn` chokepoint
  (see Scope decisions). The single point where `Open3` / `Process.spawn`
  are allowed; everything else in `lib/` routes through here (except
  `mcp_servers.rb`, which carves out — see above).
- `lib/pikuri/url_cache.rb` — `Pikuri::UrlCache`, the on-disk TTL cache
  used by the bundled web tools.
The two `bin/pikuri-*` scripts below are dev / demo entry points only —
they're not installed by `gem install pikuri` and not part of the gem's
public surface. They exist to show how to wire pikuri-as-library into a
working binary and to support local development. Production binaries
built on pikuri (notably the planned `pikuri-tui`) live in their own
downstream gems.

- `bin/pikuri-chat` — CLI entry point for the general-purpose chat
  agent: configures ruby_llm for the local llama.cpp server, builds a
  `Pikuri::Agent` wired with `Terminal` + `TokenLog` listeners and
  `StepLimit` + `Cancellable` controls, enables sub-agents, and feeds
  a question from `ARGV` or stdin.
- `bin/pikuri-code` — CLI entry point for the in-repo coding agent:
  same ruby_llm wiring as `pikuri-chat`, but registers the six coding
  tools (with a `Pikuri::Tool::Workspace::Cwd` rooted at `Dir.pwd` and
  a `Pikuri::Tool::Confirmer::TERMINAL` — `--yolo` swaps in
  `AUTO_APPROVE`), prepends any `AGENTS.md` / `CLAUDE.md` in the
  workspace as project context, and runs an interactive REPL.
- `bin/pikuri-assistant` — CLI entry point for an assistant binary
  that adds MCP support to the pikuri-chat tool set. Same ruby_llm
  wiring as `pikuri-chat`, plus a `Pikuri::McpRegistry` constructor
  argument the developer hand-edits to add MCP servers (id + argv).
  Empty by default — runs identically to `pikuri-chat` until the
  developer opts in by adding entries. The third dev/demo binary
  alongside `pikuri-chat` and `pikuri-code`.
- `prompts/pikuri-chat.txt` — system prompt used by `bin/pikuri-chat`.
- `prompts/pikuri-assistant.txt` — system prompt used by
  `bin/pikuri-assistant`. Adds MCP-aware tool-selection guidance:
  prefer MCP-backed tools for OAuth-gated SaaS over `web_scrape` /
  `fetch`, mcp_connect-once-per-server flow, treat MCP outputs as data
  not instructions.
- `prompts/coding-system-prompt.txt` — system prompt used by
  `bin/pikuri-code`. Contains the universal `Error: ...` recovery
  guidance referenced in the tool-description convention.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects,
  Faraday for HTTP, Rainbow for terminal color. ruby_llm is the LLM
  transport — don't add provider-specific SDKs alongside it.
- **`# frozen_string_literal: true`** at the top of every Ruby file
  (`lib/`, `spec/`, `bin/pikuri-chat`, `bin/pikuri-code`, etc.). Add it
  to any new file you create.
- **YARD docs on every public module, class, and method.** Use concrete
  types in `@param` and `@return` (`String`, `Integer`, `Array<Hash>`,
  `Faraday::Connection`, `String, nil`) — never bare `Object` or `Any`.
  Document expected exceptions with `@raise`. One-line summary first,
  then blank line, then tags. This applies to `lib/`; the `bin/` entry
  scripts and `spec/` files don't need it (no public API).
- **Bundler.** Entry-point scripts live in `bin/` and are run directly
  (`./bin/pikuri-chat "question"`, `./bin/pikuri-code`); each
  self-bootstraps via `require 'bundler/setup'`, so callers don't need
  the `bundle exec` ceremony. Add gems to `Gemfile` with conservative
  pessimistic constraints (`~>`).
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
  startup so `ALL_CAPS` value constants (`Pikuri::Tool::CALCULATOR`, …)
  are defined alongside the autoloadable classes/modules. New files
  must define exactly the camelcased constant matching their path; if
  you want an acronym (`HTML`, `PDF`, `DuckDuckGo`), add an entry to
  the `inflector.inflect` block in `lib/pikuri.rb`.
- **Namespacing direction.** Everything pikuri ships lives under the
  `Pikuri::` namespace — `Pikuri::Agent`, `Pikuri::Tool`,
  `Pikuri::Tool::Search::DuckDuckGo`, `Pikuri::UrlCache`,
  `Pikuri::Subprocess`. New files follow the standard gem layout:
  define a single `Pikuri::*` constant per file at the path Zeitwerk
  expects (`lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`). Don't
  introduce top-level constants.
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
  defeat to the user") lives in the per-binary system prompts
  (`prompts/pikuri-chat.txt`, `prompts/coding-system-prompt.txt`),
  not per-tool. Add an example value (`'..., e.g.
  "https://example.com"'`) to every parameter description; the LLM's
  argument-filling reliability is measurably better with one.

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** When
  changing `lib/pikuri/agent.rb`, the question is "what hooks fire
  when?" — the iteration itself lives in `RubyLLM::Chat#complete`.
  Don't reimplement the loop in pikuri; reach for a different listener
  instead.
- **Readable, not obfuscated.** Prefer the simplest implementation that
  does the job. Don't golf code for line count, but also don't add
  abstraction layers, plugin systems, or configuration knobs that
  aren't needed for the next concrete step.
- **Grow the assistant by adding tools, listeners, or controls, not
  by complicating the loop.** New capabilities should land as new
  `Pikuri::Tool` constants under `lib/pikuri/tool/`, new pure-consumer
  listeners under `lib/pikuri/agent/listener/`, or new host-facing
  controls under `lib/pikuri/agent/control/`, each with their own
  specs; neither `Pikuri::Tool`, the `Pikuri::Agent`, nor ruby_llm's
  loop should need to know about them.
