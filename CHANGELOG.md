# Changelog

All notable changes to pikuri are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
uses semver as documented in `lib/pikuri/version.rb`.

## [Unreleased]

## [0.0.3] - 2026-05-22 — monorepo split + extension protocol + MCP

Pikuri now ships as seven sibling gems under a Rails-shape monorepo
instead of one. The minimal core is `pikuri-core`; everything else
(skills, MCP, filesystem tools, the in-repo coding agent, the
MCP-aware assistant binary) lives in opt-in extension gems. The
convenience metagem `pikuri` depends on every sibling so `gem
install pikuri` still pulls the whole family in. A privacy-conscious
user who wants the smallest audit surface installs `pikuri-core`
directly and opts into extension gems à la carte.

`0.0.2` was an internal version bumped during the monorepo split
and never released; it is skipped intentionally.

### Added
- **Seven-gem monorepo.** `pikuri-core` (lean foundation),
  `pikuri-skills`, `pikuri-mcp`, `pikuri-workspace` (filesystem tools
  + Workspace/Confirmer seams), `pikuri-code` (Bash + `bin/pikuri-code`),
  `pikuri-assistant` (`bin/pikuri-assistant`), and the `pikuri`
  metagem. Per-gem `README.md` + `lib/`/`spec/`/`<gem>.gemspec`. The
  top-level `Rakefile` fans `rake test` out across each gem and
  orchestrates lockstep `rake release`.
- **Configurator + Extension protocol.** `Pikuri::Agent.new` now
  takes a block yielding a `Pikuri::Agent::Configurator`; hosts and
  extensions call `add_tool` / `add_listener` /
  `append_system_prompt` / `add_extension` / `allow_sub_agent` /
  `on_close` on it. `Pikuri::Agent::Extension` is the duck-typed
  mixin (`configure(c)` + `bind(agent)`) that extension gems
  implement. Sub-agents inherit the parent's extension list, so each
  inherited extension's `bind` fires on the sub-agent.
- **MCP (Model Context Protocol) support** in `pikuri-mcp`:
  `Pikuri::Mcp::Registry` (stdio + HTTP entries),
  `Pikuri::Mcp::Servers` runtime, `Pikuri::Mcp::Extension` wire-in,
  `Pikuri::Mcp::Synthesizer` (LLM-fills missing server descriptions
  with on-disk cache keyed on the full server surface),
  `Pikuri::Mcp::Verifier` (pre-flight injection check across every
  text field — mechanical Unicode pre-pass plus LLM inspection for
  instruction-override / exfiltration / tool-chain hijack
  patterns), and `Pikuri::Mcp::ClientWrapper` (restart-on-stdio-death
  retry). `bin/pikuri-assistant` ships as the MCP-aware demo binary.
- **Opt-in streaming.** `Pikuri::Agent.new(..., streaming: true)`
  threads a streaming block through `Chat#ask` and emits
  `Event::ThinkingDelta` / `Event::AssistantDelta` per chunk
  alongside the message-level bookends. Propagates through
  `Synthesizer.run` and `Tool::SubAgent` so the whole agent tree
  streams consistently. `Listener::Terminal` renders deltas live
  when given `streaming: true`; `Listener::RateLimited` coalesces
  delta floods to an fps cap. Mid-thinking cancellation is honored
  because the streaming block polls the `Cancellable` control.
- **Cooperative cancellation + mid-loop user input.** Two new
  host-facing controls: `Pikuri::Agent::Control::Cancellable` (the
  agent polls it between tool calls and inside the streaming block;
  Ctrl+C raises a `Cancelled` event without leaving the loop in a
  half-state) and `Pikuri::Agent::Control::Interloper` (host can
  push a user message mid-loop; the agent drains pending messages
  at the next boundary and emits `UserTurn(mid_loop: true)`).
- **Workspace + Confirmer seams** in `pikuri-workspace`:
  `Pikuri::Tool::Workspace` (abstract base + bundled `Cwd` that
  scopes reads + writes to a chosen root, rejecting `..`-escapes
  and out-of-root symlinks) and `Pikuri::Tool::Confirmer` (abstract
  base + bundled `TERMINAL` and `AUTO_APPROVE`). The five file
  tools (`Read`/`Write`/`Edit`/`Grep`/`Glob`) take both via
  constructor so future TUI / IDE hosts plug in by writing a new
  subclass rather than editing tool internals.
- **`Pikuri::Agent::Synthesizer`** — step-exhaustion rescue: when
  the agent hits `max_steps` mid-task it gets one last call to
  summarize what it knows so far instead of returning a truncated
  conversation.
- **`Pikuri::Agent::ContextWindowDetector`** — resolves the model's
  context-window cap from override → ruby_llm registry → llama.cpp
  `/props` probe at construction time; emits `Event::ContextCap`.
- **`Pikuri::Agent::ChatTransport`** — value bundle
  (`model` / `provider` / `assume_model_exists`) passed to every
  `RubyLLM.chat` originating from an agent or sub-agent.
- **`Agent#close` + `Agent.open` block form** — ownership-based
  resource cleanup. Extensions register `on_close` callbacks via the
  Configurator; closing the parent agent fans out to every
  registered handler. Demo bins use the `at_exit { agent.close }`
  pattern.
- **`Pikuri::Subprocess.spawn` chokepoint** — single point in any
  `pikuri-*` `lib/` where subprocesses spawn. Forces a new process
  group per invocation, tracks pgids globally, SIGTERMs everything
  tracked via `at_exit` so backgrounded shell children don't
  outlive pikuri uncontrolled. Documented exception:
  `Pikuri::Mcp::ClientWrapper` (the `mcp` gem owns stdio MCP
  subprocess lifecycle).
- **`Pikuri::Agent::Event::*`** — unified event stream
  (`UserTurn` / `Thinking` / `ThinkingDelta` / `Assistant` /
  `AssistantDelta` / `ToolCall` / `ToolResult` / `Tokens` /
  `ContextCap` / `FallbackNotice` / `Cancelled`) consumed by pure-
  consumer listeners (`Base`, `Terminal`, `InMemoryEventList`,
  `TokenLog`, `RateLimited`).
- **`TokenLog#status_line`** — latest token snapshot as a single
  string for terminal status-line rendering.
- **`--server` and `--model` flags** on both `bin/pikuri-chat` and
  `bin/pikuri-code` for overriding the local llama.cpp defaults
  from the CLI.

### Changed
- **`Pikuri::Tool::SkillCatalog` → `Pikuri::Skill::Catalog`**,
  `Pikuri::Tool::Skill` → `Pikuri::Skill::SkillTool` (the `Tool`
  suffix avoids `class Tool < Pikuri::Tool` shadowing; the
  LLM-facing tool name stays `skill`). Both move into the new
  `pikuri-skills` gem with `Pikuri::Skill::Extension` as the
  wire-in surface.
- **`Pikuri::Agent::Listener::InMemoryMessageList` →
  `Pikuri::Agent::Listener::InMemoryEventList`** — listeners now
  observe the unified event stream, not just message events.
- **Listener / Control split.** Listeners are pure event consumers
  (single `on_event(event)` override); controls
  (`StepLimit` / `Cancellable` / `Interloper`) are host-facing and
  the agent pokes them at the right boundaries.
- `pikuri-core` runtime deps tightened to what the core actually
  uses (no `mcp` gem in the core's deps — that moves to
  `pikuri-mcp`).
- Agent extension list is the sole wiring path for extensions;
  the `extensions:` / `tools:` / `listeners:` kwargs on `Agent.new`
  are gone. Hosts pass everything through the Configurator block.

### Removed
- The single `pikuri.gemspec` at the repo root, replaced by per-gem
  gemspecs under each gem directory.
- Legacy `Agent.new` kwargs `tools:` / `listeners:` / `extensions:`.

## [0.0.1] - 2026-05-14 — first packaged release

The initial gem release. Pikuri is shipped as a **library** — there are
no executables installed by `gem install pikuri`. The `bin/pikuri-chat`
and `bin/pikuri-code` scripts in the source tree are dev/demo entry
points; production binaries built on pikuri (notably the planned
`pikuri-tui`) will live in their own downstream gems.

### Added
- `pikuri.gemspec` with runtime deps pulled from the previous `Gemfile`
  (one source of truth; `Gemfile` now uses `gemspec`).
- `Pikuri::VERSION` constant (`lib/pikuri/version.rb`); Zeitwerk is
  told to ignore the file since the constant is `VERSION`, not
  `Version`.
- `LICENSE` (MIT) and gemspec license metadata.
- `Pikuri::PROMPTS_DIR` and `Pikuri.prompt(name)` — downstream library
  users can read pikuri's bundled system prompts as a starting point
  for their own wiring.
- `Tool::Bash` emits a loud warning at construction: the tool runs
  commands unsandboxed under pikuri's UID and can read `~/.ssh`, AWS
  credentials, etc. A future release will gate this behind a sandbox.
- `Pikuri::Tool::SkillCatalog` + `Pikuri::Tool::Skill` — pikuri's
  implementation of the [Agent Skills standard](https://agentskills.io/specification).
  `SkillCatalog` discovers and validates `SKILL.md` files under the
  standard `.pikuri/skills`, `.claude/skills`, `.agents/skills`
  directories (precedence in that order); `Tool::Skill` is auto-
  registered by `Agent#initialize` whenever the wired-in catalog is
  non-empty, and the catalog's prompt block is appended to the system
  prompt so the LLM sees the available inventory without an extra
  round-trip.
- `mise.toml` pinning Ruby 3.3, matching the gemspec floor.
- `CHANGELOG.md` (this file).

### Changed
- **Namespace move.** Top-level `Agent`, `Tool`, and `UrlCache` are now
  `Pikuri::Agent`, `Pikuri::Tool`, `Pikuri::UrlCache`. All bundled
  tools, listeners, and helpers live under `Pikuri::*`. Standard gem
  layout: `lib/pikuri.rb` + `lib/pikuri/**/*.rb`; `spec/` mirrors it.
- `Pikuri::Agent::Listener::InMemoryList` renamed to `InMemoryMessageList`
  to clarify what it records (message events).
- `UrlCache::ROOT_DIR` follows the XDG Base Directory spec:
  `$XDG_CACHE_HOME/pikuri/url_cache` if set, else
  `~/.cache/pikuri/url_cache`. Previously `/tmp/pikuri/cache`.
- `bin/pikuri-chat` and `bin/pikuri-code` read prompts via
  `Pikuri.prompt(name)` instead of hand-rolled `__dir__` arithmetic.

### Project scope
- Pikuri targets **Linux**; macOS may work; Windows is unsupported.
  Rationale: the eventual Bash-tool sandbox (Docker / bubblewrap) and
  the existing reliance on POSIX shell + GNU coreutils + XDG layout
  make a Windows port more cost than benefit.
- Hard ceiling on source size: a privacy-conscious user should be able
  to read pikuri end-to-end in an evening and decide whether to trust
  it outside a sandbox. New features compete against that budget.
