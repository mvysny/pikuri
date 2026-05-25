# CLAUDE.md

## What this project is

A Ruby implementation of an AI assistant, shipped as a family of
eight gems in a monorepo. The lean core (`pikuri-core`) provides the
`Agent` runtime, the `Tool` framework with strict argument
validation, the Extension protocol, the listener event stream, and
four stateless bundled tools (calculator, web search, web scrape,
fetch) + `bin/pikuri-chat` as the demo binary. Extensions live in
sibling gems and opt in à la carte: `pikuri-skills`, `pikuri-mcp`,
`pikuri-workspace` (filesystem tools + Confirmer/Workspace seams),
`pikuri-code` (Bash + `bin/pikuri-code`), `pikuri-subagents` (the
`agent` tool / `Persona` record / `SubAgent::Extension` — the whole
delegation feature, plus the bundled `RESEARCHER` persona and
`bin/pikuri-minions` as the fan-out demo), `pikuri-assistant` (the
MCP-aware `bin/pikuri-assistant`). A convenience `pikuri` metagem
declares deps on all seven so `gem install pikuri` brings the whole
family in.

Pikuri sits on top of [ruby_llm](https://rubyllm.com) — the gem owns
the transport and the Thought / Tool-call / Observation loop — and
adds the *extension surface*: the strict `Tool::Parameters`
validator, the Configurator + Extension protocol that hosts use to
wire extra capabilities into an `Agent` via the `Agent.new` block,
listener-based rendering of reasoning / assistant Markdown / tool
calls, a `max_steps` budget, and a fixed deliberate set of bundled
tools. Sub-agents are an extension (`pikuri-subagents`), not a core
feature.

## Why this exists

The motivating frustration: the existing agent stacks (the "PI" and
"OpenClaw" projects) have grown big and now have a very steep
learning curve. A privacy-conscious user arriving fresh hits a wall
of massive JSON configuration with no clear start-here. Pikuri is
the deliberate counter-move:

- **Start slowly.** Sane defaults out of the box, three small
  demo binaries, no config file required to get a first conversation
  going. The surface area grows as the user grows into it — start
  with `pikuri-core` + `bin/pikuri-chat`, opt into skills / MCP /
  the coding stack as the need shows up.
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

- **The seam.** The *loop* lives in ruby_llm, and pikuri's wrapper
  around it is confined to a small set of files: the three
  `bin/pikuri-*` scripts (boot/wiring — call `RubyLLM.configure`),
  `pikuri-core/lib/pikuri/agent.rb` (constructs the Chat, attaches
  callbacks, calls `ask`), and `pikuri-core/lib/pikuri/tool.rb` (the
  `Pikuri::Tool` value class plus its `#to_ruby_llm_tool` adapter
  that emits a synthetic `RubyLLM::Tool` subclass on demand). New
  loop-wiring code lands in those files; don't construct a `Chat` or
  attach callbacks from anywhere else.

  *Value types are not part of the seam.* Anywhere in pikuri-*
  `lib/` may reference ruby_llm **value types** —
  `RubyLLM::Content`, `RubyLLM::Attachment`, `RubyLLM::Message` —
  when the alternative is reimplementing functionality ruby_llm
  already provides. The rule of preference: reach for the pikuri
  API first; if none exists and one fits pikuri's objective,
  propose adding it; if the wrapper would be a transparent
  passthrough that adds no behavior of its own, use the ruby_llm
  type directly. The fork-or-swap contingency still holds — the
  loop is the swap point — but value types travel with whoever
  drives them, so wrapping them buys nothing and costs us every
  feature that wants to use them.

  The pre-existing carve-out for `pikuri-mcp/lib/pikuri/mcp/
  servers.rb` (which synthesizes `RubyLLM::Tool` subclasses
  directly to absorb arbitrary JSON Schema from MCP servers) is
  unchanged.

- **Subprocess seam.** All subprocess spawning in any pikuri-*
  `lib/` goes through `Pikuri::Subprocess.spawn`. Direct
  `Process.spawn` / `Open3.*` / `system` / backticks anywhere in
  `lib/` are bugs. The chokepoint forces a new process group per
  invocation, tracks pgids in a process-global set, and SIGTERMs
  everything tracked via `at_exit` so backgrounded shell children
  don't outlive pikuri uncontrolled. Timeouts are the caller's
  job — wrap argv with coreutils' `timeout` binary; the chokepoint
  deliberately doesn't implement a Ruby-side timeout (can't kill
  subprocesses cleanly). Grep-enforceable:
  `grep -rn 'Process\.spawn\|Open3\|system' pikuri-*/lib/` should
  only hit `pikuri-core/lib/pikuri/subprocess.rb`.

  *Carve-out:* `pikuri-mcp` is the documented exception, and only
  for stdio MCP entries (`Mcp::Registry::StdioEntry`). The `mcp`
  gem spawns the server via its own `MCP::Client::Stdio`
  transport — routing that through `Subprocess.spawn` would mean
  forking the gem or threading custom IO pipes through its API,
  duplicating work the gem exists to do. Instead,
  `Mcp::ClientWrapper` lets the gem own subprocess lifecycle and
  pikuri's `Mcp::Extension` registers an `on_close` handler that
  calls `Mcp::Servers#close` (which closes stdin → server hits EOF
  and self-terminates per spec). The grep invariant above still
  holds because the spawn happens inside the `mcp` gem, not in any
  pikuri-* `lib/`. HTTP MCP entries (`Mcp::Registry::HttpEntry`)
  don't fall under the carve-out — they're plain Faraday inside
  the gem, no subprocess involved.

- **Workspace seam.** Tools that touch files (`Read`, `Write`, `Edit`,
  `Grep`, `Glob`, `Bash`) take a `Pikuri::Workspace::Filesystem` via
  constructor and route every path through `#resolve_for_read(path)` /
  `#resolve_for_write(path)` before touching the filesystem.
  `Pikuri::Workspace::Filesystem.new(project_root:, readable: [],
  writable: [], temp: false)` is the default concrete class:
  `project_root` is the writable containment ceiling AND the
  relative-path base AND the chdir target for Bash/Grep/Glob — a
  single anchor, no separate cwd concept (hosts that want the agent
  scoped to a subtree pass that subtree as `project_root`),
  `readable`/`writable` add extra roots, and `temp: true` mints an
  `at_exit`-cleaned playground. Every path is resolved against those
  roots, rejecting `..`-escapes and symlinks that land outside.
  `Pikuri::Workspace::Filesystem::AllowAll` is the unrestricted variant
  for dev-container / Docker mode where the container is the security
  boundary — same accessor surface, but `resolve_for_*` accept any
  path *except* those under a hardcoded credential denylist
  (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`, `~/.kube`, `~/.netrc`,
  `/etc/shadow`, plus `/root` variants) so a prompt-injection
  exfiltration of host-mounted credentials still gets blocked. Pairs
  with `--yolo` and `Code::Bash::Sandbox::NONE`; combining `AllowAll`
  with `Bubblewrap` defeats both layers. Hosts that need a different
  policy subclass either; an in-editor pikuri can mirror the IDE's
  open project root or a virtual filesystem without rewriting tool
  guts.

- **Confirmer seam.** Tools that mutate user state (`Write`, `Bash`)
  take a `Pikuri::Workspace::Confirmer` via constructor and route every
  prompt through `#confirm?(prompt:)` — never `gets` / `puts` /
  `$stdin` / `$stdout` directly. Two bundled implementations:
  `Pikuri::Workspace::Confirmer::TERMINAL` (prompts on stdin/stdout) and
  `Pikuri::Workspace::Confirmer::AUTO_APPROVE` (yes-to-everything; used
  by `--yolo` mode and specs). Same rationale as the workspace seam: a
  later TUI / IDE host plugs in by writing a new `Confirmer` subclass,
  not by editing tool internals.

- **Sandbox seam.** `Pikuri::Code::Bash` takes a
  `Pikuri::Code::Bash::Sandbox` (default `Sandbox::NONE`) and wraps
  every spawned argv through `#wrap(argv)` — the *filesystem view* of
  the bash subprocess is the sandbox's concern, distinct from the
  `Workspace`'s "what the LLM observes via Read/Write/Edit/Grep/Glob."
  `Sandbox::Bubblewrap` is the bundled non-identity implementation: it
  composes a `bwrap` argv from `workspace.readable` / `writable` plus
  a curated `/etc` baseline (TLS certs, DNS, timezone, hosts file),
  and overlays each `ephemeral_overlay:` path
  (`Pikuri::Code::ToolchainPaths.ephemeral_overlay` — `~/.gradle/caches`,
  `~/.gradle/wrapper/dists`, `~/.gradle/jdks`, `~/.m2/repository`,
  `~/.cargo/registry`, `~/.ivy2/cache`, …) with a per-session RW
  upper layer under `workspace.internal_temp`, so toolchain caches
  survive across bash calls within one session but never pollute
  the host's real caches. Every entry is a content-only subdir,
  deliberately *not* the toolchain's whole `$HOME` directory: that
  way `~/.gradle/gradle.properties` (signing keys, OSSRH /
  Develocity tokens), `~/.gradle/init.d` (persistence vector),
  `~/.ivy2/.credentials`, `~/.m2/settings.xml`,
  `~/.cargo/credentials.toml`, etc. never appear in the sandbox at
  all. The threat model: blast-radius containment for the bash
  subprocess + prevention of cross-project contamination via
  shared `$HOME` caches (a poisoned session can't reach
  `~/.gradle/init.d` to plant a script for a future `gradle`
  invocation, and even the cache writes it does make vanish at
  session exit). It is NOT a malware-resistant boundary — prompt
  injection can still modify project source, inject malicious
  dependencies into the project's own build file, or exfiltrate over
  the network (`--share-net` is intentional so `git pull` / `mvn` /
  `curl` work). Users who need adversarial isolation run pikuri-code
  inside a container; the container is the outer boundary, bwrap is
  the inner one.

  *Container-socket footgun.* Exposing a container or VM control
  socket (`/var/run/docker.sock`, `containerd.sock`, `podman.sock`,
  `libvirt-sock`, …) to the sandbox effectively undoes it: from
  inside, `docker run --privileged -v / /host` is a one-step root
  escape. The pikuri default workspace never binds `/var/run` or
  `/run`, but `Sandbox::Bubblewrap`'s constructor walks
  `workspace.readable + workspace.writable` against
  `DENIED_CONTAINER_SOCKETS` and refuses to construct if any
  workspace root *contains* (equals or is an ancestor of) a known
  socket. Downstream hosts that genuinely intend the agent to drive
  a container daemon must pass `Sandbox::NONE` (and accept the
  consequences). The list is conservative — common Linux engines
  only — and a host with an unusual setup can subclass to extend.

- **Streaming is opt-in via `Agent.new(..., streaming: true)`.** When
  true, `Agent#run_loop` passes a streaming block to `Chat#ask` and
  the per-chunk `Event::ThinkingDelta` / `Event::AssistantDelta`
  deltas flow on the listener stream alongside the message-level
  `Event::Thinking` / `Event::Assistant` bookends. The flag
  propagates to `Synthesizer.run` and to spawned sub-agents (via the
  `agent` tool in `pikuri-subagents`) so the whole agent tree streams
  or doesn't, consistently. Defaults to `false` because the bundled
  `Terminal` listener still renders the full message on
  `Event::Assistant`; a future delta-renderer mode will flip the
  bundled bins to `streaming: true`.

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

Pikuri ships as a Rails-shape monorepo: eight gems live in
sibling subdirectories under the repo root. Each gem owns its own
`lib/`, `spec/`, `<gem>.gemspec`, entry file, and (where relevant)
`bin/` + `prompts/` — same convention Rails uses for actionpack/
activerecord/etc. The top-level `Gemfile` wires every gem via
`gemspec path: '<gem>'` for dev mode; the top-level `Rakefile`
fans out `rake test` across each gem and orchestrates `rake release
VERSION=x.y.z` in lockstep.

Everything pikuri ships lives under the `Pikuri::` namespace,
contributed cooperatively by each gem's own Zeitwerk loader. Each
gem's entry file (`<gem>/lib/<gem-name>.rb`) sets up a per-gem
loader; loaders coexist because they manage non-overlapping file
trees. The `Pikuri::PROMPT_DIRS` list is similarly cooperative:
each gem appends its own `prompts/` directory at boot, so
`Pikuri.prompt(name)` searches across every loaded gem.

Per-file rationale lives in each source file's YARD header — this
is just the package map. Per-gem layout below:

### `pikuri-core/` — gem name `pikuri-core`

The lean foundation. Agent runtime + Tool framework + Configurator +
Extension protocol + listener stream + four stateless tools.
Runtime deps: ruby_llm, Faraday, Rainbow, tty-markdown, Zeitwerk,
Nokogiri, pdf-reader, reverse_markdown, ruby-readability, dentaku,
tsort. No subprocess-spawning tools.

- `lib/pikuri-core.rb` — gem entry. Defines `Pikuri::PROMPT_DIRS`,
  the logger machinery, and the `pikuri-core` Zeitwerk loader.
  Inflector overrides cover acronym mismatches (`HTML`, `PDF`,
  `DuckDuckGo`).
- `lib/pikuri/agent.rb`, `lib/pikuri/agent/` — `Pikuri::Agent`,
  `Pikuri::Agent::ChatTransport` (the `model`/`provider`/`assume_model_exists`
  value bundle passed to every `RubyLLM.chat` originating from an agent),
  `Pikuri::Agent::ContextWindowDetector` (resolves the model's context-window
  cap from override → ruby_llm registry → llama.cpp `/props` probe at
  construction time), `Pikuri::Agent::Configurator` (the build-time
  collector yielded into the `Agent.new` block; receives
  `add_tool` / `add_listener` / `append_system_prompt` /
  `add_extension` / `on_close` calls from both hosts and extensions),
  `Pikuri::Agent::Extension` (the mixin module defining the
  duck-typed `configure(c)` + `bind(agent)` hooks with empty
  defaults — extensions in `pikuri/skill/`, `pikuri/mcp/`,
  `pikuri/sub_agent/` etc. `include` it),
  `Pikuri::Agent::ListenerList`, the `Pikuri::Agent::Event` variants
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
  the sole emitter. **Listener/control asymmetry on sub-agent
  propagation:** listeners define `for_sub_agent(**)` as a duck-typed
  protocol (`Terminal` for padding, `TokenLog` for id-tagged
  zero-snapshot, `RateLimited` for token-budget split) — the call site
  is in `pikuri-subagents`, but the protocol lives here so user-defined
  listeners can opt in. Controls do **not** define `for_sub_agent` —
  the propagation policy ("fresh `StepLimit` at the persona's
  `max_steps`, shared `Cancellable`, `nil` `Interloper`") is inlined
  in `SubAgentTool#execute` rather than dispatched per-control,
  because the three controls are a fixed set and the policy is
  sub-agent-specific. Sub-agents do **not** inherit extensions: each
  persona owns its toolset and system prompt verbatim, so
  `Extension#bind(agent)` fires once per parent agent only
  (Skills' `configure` is enough; MCP's `bind` adds the parent's
  `mcp_connect` tool; SubAgent's `bind` adds the `agent` tool).
- `lib/pikuri/tool.rb`, `lib/pikuri/tool/parameters.rb` —
  `Pikuri::Tool` value class with its `#to_ruby_llm_tool` adapter
  and the strict `Pikuri::Tool::Parameters` builder/validator. The
  sub-agent (`agent`) tool itself lives in `pikuri-subagents` —
  `pikuri-core` knows nothing about delegation; if no host wires in
  a `Pikuri::SubAgent::Extension`, no `agent` tool exists.
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
- `lib/pikuri/subprocess.rb` — `Pikuri::Subprocess.spawn` chokepoint
  (see Scope decisions). The single point where `Open3` /
  `Process.spawn` are allowed; everything else in any pikuri-* gem's
  `lib/` routes through here (except `pikuri-mcp/lib/pikuri/mcp/
  client_wrapper.rb`, which carves out — see below).
- `lib/pikuri/url_cache.rb` — `Pikuri::UrlCache`, the on-disk TTL
  cache used by the bundled web tools and by `pikuri-mcp`'s caches.
- `lib/pikuri/file_type.rb` — `Pikuri::FileType` magic-byte content
  sniffer: `.detect_mime(bytes)` recognises PDF + the four supported
  image formats, `.binary?(bytes)` is the heuristic text-vs-binary
  classifier. Shared by `Workspace::Read` (routing to format_pdf /
  format_image / format_slice) and `Workspace::Edit` (binary refusal).
- `bin/pikuri-chat` — CLI entry point for the general-purpose chat
  agent: configures ruby_llm for the local llama.cpp server, builds
  a `Pikuri::Agent` wired with `Terminal` + `TokenLog` listeners,
  `StepLimit` + `Cancellable` controls, and the four bundled tools
  (web_search, calculator, web_scrape, fetch). Feeds a question from
  `ARGV` or stdin. The smallest possible demo — no delegation, no
  skills, no MCP; users who want sub-agents graduate to
  `bin/pikuri-minions`.
- `prompts/pikuri-chat.txt` — system prompt used by `bin/pikuri-chat`.

### `pikuri-skills/` — gem name `pikuri-skills`

The [Agent Skills standard](https://agentskills.io/specification)
implementation. Depends on `pikuri-core`. No new runtime deps.

- `lib/pikuri-skills.rb` — gem entry. Sets up a per-gem Zeitwerk
  loader tagged `pikuri-skills`.
- `lib/pikuri/skill/catalog.rb` — `Pikuri::Skill::Catalog` is the
  discovery + validation layer (abstract base + bundled
  `Empty`/`EMPTY` and `Bundled` scanners that walk
  `.pikuri/skills`, `.claude/skills`, `.agents/skills`).
- `lib/pikuri/skill/skill_tool.rb` — `Pikuri::Skill::SkillTool <
  Pikuri::Tool` is the loading tool (the `Tool` suffix avoids the
  `class Tool < Pikuri::Tool` shadowing — LLM-facing name stays
  `skill`).
- `lib/pikuri/skill/extension.rb` — `Pikuri::Skill::Extension <
  Pikuri::Agent::Extension`. The wire-in surface: added via
  `c.add_extension(Pikuri::Skill::Extension.new(catalog: catalog))`
  inside the `Pikuri::Agent.new` block; auto-registers the snippet
  + the skill tool when the catalog is non-empty.

### `pikuri-workspace/` — gem name `pikuri-workspace`

The "operate on a directory tree" gem: Workspace + Confirmer seams
+ Read/Write/Edit/Grep/Glob. Depends on `pikuri-core`. No new
runtime deps (stdlib-only). No subprocess execution — `Bash` lives
in `pikuri-code` on top.

- `lib/pikuri-workspace.rb` — gem entry. Per-gem Zeitwerk loader
  mounted at this gem's `lib/` root; Zeitwerk auto-vivifies
  `Pikuri::Workspace` as a module from the `pikuri/workspace/`
  directory.
- `lib/pikuri/workspace/confirmer.rb`,
  `lib/pikuri/workspace/filesystem.rb` — the two coding-tool seams
  (see Scope decisions). `Confirmer` is an abstract base with
  bundled `TERMINAL` / `AUTO_APPROVE` implementations; `Filesystem`
  is a single concrete class parameterized by `project_root:` /
  `readable:` / `writable:` / `temp:` (subclass if a host needs a
  different containment policy).
- `lib/pikuri/workspace/read.rb`, `lib/pikuri/workspace/write.rb`,
  `lib/pikuri/workspace/edit.rb`, `lib/pikuri/workspace/grep.rb`,
  `lib/pikuri/workspace/glob.rb` — the five file tools. Each is a
  `Pikuri::Tool` subclass (defined under the `Pikuri::Workspace`
  namespace) instantiated per-binary with the constructor wiring
  (workspace + confirmer where needed).

### `pikuri-code/` — gem name `pikuri-code`

Bash + the in-repo coding-agent binary. Depends on `pikuri-core` +
`pikuri-workspace` + `pikuri-subagents` (`bin/pikuri-code` wires
`Pikuri::SubAgent::SCOUT` via `Pikuri::SubAgent::Extension` so the
parent agent can delegate read-only code recon to a
privilege-separated child).

- `lib/pikuri-code.rb` — gem entry. Per-gem Zeitwerk loader
  rooted plainly at this gem's `lib/`, plus appends `prompts/` to
  `Pikuri::PROMPT_DIRS`.
- `lib/pikuri/code/bash.rb`, `lib/pikuri/code/bash/sandbox.rb` —
  `Pikuri::Code::Bash` (shell tool via the `Subprocess.spawn`
  chokepoint + `Confirmer` gate) and its filesystem-sandbox seam
  (`Sandbox::NONE` / `Sandbox::Bubblewrap`).
- `lib/pikuri/code/toolchain_paths.rb` — `Pikuri::Code::ToolchainPaths`
  helper that enumerates the read-only filesystem prefixes a coding
  agent benefits from (system toolchains + per-user dependency caches).
- `bin/pikuri-code` — CLI entry point for the in-repo coding
  agent: discovers `project_root` via `Workspace::ProjectRoot.find`
  from the launch `Dir.pwd`, `Dir.chdir`'s the Ruby process to it
  if needed (so process cwd and workspace agree on one anchor),
  then registers the file/shell stack (`Workspace` anchored at the
  discovered root + `temp: true` for a scratch playground +
  `Confirmer::TERMINAL` — `--yolo` swaps in `AUTO_APPROVE`),
  adds `Pikuri::Skill::Extension` (catalog
  discovered from `.pikuri/skills` / `.claude/skills` /
  `.agents/skills`), `Pikuri::Mcp::Extension` (empty registry
  by default — hand-edit to add servers), and
  `Pikuri::SubAgent::Extension` with the read-only fs-recon
  `Pikuri::SubAgent::SCOUT` persona via the `Agent.new`
  block, prepends any `AGENTS.md` / `CLAUDE.md` in the workspace
  as project context, and runs an interactive REPL.
- `prompts/coding-system-prompt.txt` — system prompt used by
  `bin/pikuri-code`. Contains the universal `Error: ...` recovery
  guidance referenced in the tool-description convention.

### `pikuri-mcp/` — gem name `pikuri-mcp`

MCP (Model Context Protocol) support. Depends on `pikuri-core` +
the `mcp` gem. The only extension gem that adds a non-stdlib
runtime dep.

- `lib/pikuri-mcp.rb` — gem entry. Per-gem Zeitwerk loader tagged
  `pikuri-mcp`.
- `lib/pikuri/mcp/registry.rb` — `Pikuri::Mcp::Registry`, the pure
  config layer (`StdioEntry`/`HttpEntry` data classes, `EMPTY`
  singleton — same shape as `Pikuri::Skill::Catalog::EMPTY`).
- `lib/pikuri/mcp/servers.rb` — `Pikuri::Mcp::Servers`, the
  runtime: constructed from a registry, eager-starts every
  configured server via the `mcp` gem's `MCP::Client::Stdio` /
  `MCP::Client::HTTP`, holds the live clients, emits an INFO audit
  log per server. `Mcp::Servers::Connect` (the `mcp_connect` tool)
  is a private inner `Pikuri::Tool` subclass auto-instantiated
  per-agent by `Mcp::Extension#bind`.
- `lib/pikuri/mcp/extension.rb` — `Pikuri::Mcp::Extension <
  Pikuri::Agent::Extension`. The wire-in surface: added via
  `c.add_extension(Pikuri::Mcp::Extension.new(registry: ...))`
  inside the `Pikuri::Agent.new` block. Its `configure(c)` builds
  the shared `Mcp::Servers`, appends the `<available_mcps>`
  snippet, and registers `c.on_close { servers.close }` for
  cleanup. Its `bind(agent)` adds a fresh per-agent `Connect`
  tool via `Agent#internal_add_tool` — sub-agents go through the
  same `bind` (one extension instance, multiple bind calls), so
  each agent gets its own connect tool keyed to itself but they
  all share the parent's live MCP clients through the extension.
- `lib/pikuri/mcp/synthesizer.rb` — `Pikuri::Mcp::Synthesizer`,
  owns the LLM-driven description summarization: the prompt, its
  `PROMPT_VERSION`, the cleanup, and the fail-soft /
  Cancelled-propagating contract. Servers delegates to its
  `#call` from `#resolve_description` when one was wired in.
- `lib/pikuri/mcp/verifier.rb` — `Pikuri::Mcp::Verifier`, the
  pre-flight injection check: mechanical Unicode pre-pass (zero-
  width / bidi / Unicode tag chars) plus an LLM-driven inspection
  of every text field for instruction-override, exfiltration,
  tool-chain hijacking, and authority-impersonation patterns.
  Wired into `start_one` after `client.tools` but before
  `resolve_description`; `Verifier::InjectionDetected` aborts
  startup for that server. Caches only `"OK"` (rejections
  re-verify on each boot).
- `lib/pikuri/mcp/cache.rb` — `Pikuri::Mcp::Cache`, the on-disk
  cache both Synthesizer and Verifier read/write. Wraps
  `Pikuri::UrlCache` (from pikuri-core) with a TTL of infinity,
  keys on the full server surface (transport, server
  name/version, every tool's name/description/schema) so any
  change auto-invalidates. Synthesizer and Verifier each get
  their own `Cache` instance pointing at a separate directory
  (`mcp_descriptions/` and `mcp_verifications/`) so the two
  caches stay independent.
- `lib/pikuri/mcp/client_wrapper.rb` — per-server transport
  wrapper with restart-on-stdio-death retry. The documented
  exception to the `Subprocess.spawn` chokepoint (see Scope
  decisions): the `mcp` gem owns its own subprocess lifecycle,
  so stdio MCP entries spawn through `mcp` rather than
  `Pikuri::Subprocess`.

MCP tools bypass `Pikuri::Tool` entirely — they're synthesised
as raw `RubyLLM::Tool` subclasses inside `Mcp::Servers` and fed
in via `Agent#internal_add_tool`. See IDEAS.md for the rationale.

### `pikuri-subagents/` — gem name `pikuri-subagents`

The sub-agent (delegation) feature top to bottom: the `agent`
tool, the `Persona` record, the `Extension` that wires both onto
an agent, the bundled `RESEARCHER` + `SCOUT` personas, and the
`bin/pikuri-minions` fan-out demo. Depends on `pikuri-core`. No
new runtime deps. The bundled personas reference their tools by
string name only (no `require` of `pikuri-workspace`), so the gem
stays decoupled from the gems whose tools they happen to use —
hosts that don't wire the matching tools just never register the
persona.

- `lib/pikuri-subagents.rb` — gem entry. Appends `prompts/` to
  `Pikuri::PROMPT_DIRS`, sets up a per-gem Zeitwerk loader tagged
  `pikuri-subagents` rooted at this gem's `lib/`, and
  `require_relative`s `pikuri/sub_agent/researcher.rb` +
  `pikuri/sub_agent/scout.rb` after eager-load (each file defines
  an `ALL_CAPS` value constant — `RESEARCHER`, `SCOUT` — not a
  `Researcher` / `Scout` module Zeitwerk's filename↔CamelCase rule
  would expect — same `ignore + require_relative` pattern
  pikuri-core uses for `version.rb`).
- `lib/pikuri/sub_agent/sub_agent_tool.rb` —
  `Pikuri::SubAgent::SubAgentTool < Pikuri::Tool`. The LLM-facing
  `agent` tool. Class name is `SubAgentTool` (peer to `Persona` /
  `Extension` under one namespace); LLM tool name stays `agent`
  because from the parent's POV it is calling another agent.
  Constructed by `SubAgent::Extension#bind`, closing over the live
  parent agent's `transport` / `tools` / `listeners` /
  `cancellable` / `context_window_cap` / `streaming`. At spawn time
  the `execute` lambda filters `parent.tools` by the picked
  persona's `tool_names` (reusing parent tool *instances* with
  their already-bound workspace/confirmer wiring) and uses
  `persona.system_prompt` verbatim. The sub-agent propagation
  policy ("fresh `StepLimit` at `persona.max_steps`, shared
  parent `Cancellable` by reference, no `Interloper`") is inlined
  here rather than dispatched to a `for_sub_agent` hook on each
  control — see the listener/control asymmetry note in the
  `pikuri-core` section.
- `lib/pikuri/sub_agent/persona.rb` — `Pikuri::SubAgent::Persona`,
  the `(name, description, tool_names, system_prompt, max_steps)`
  record bundling "what kind of agent is this." Hosts declare which
  personas an agent may spawn by handing instances to
  `SubAgent::Extension`'s `personas:` kwarg.
- `lib/pikuri/sub_agent/extension.rb` —
  `Pikuri::SubAgent::Extension < Pikuri::Agent::Extension`. The
  wire-in surface: added via
  `c.add_extension(Pikuri::SubAgent::Extension.new(personas: [...]))`
  inside the `Agent.new` block. Same MCP-shape configure/bind
  split: `configure(c)` validates every persona's `tool_names`
  against `c.tools` and appends the `<available_agents>` snippet;
  `bind(agent)` constructs the `SubAgentTool` and adds it via
  `Agent#internal_add_tool`. The constructor raises on duplicate
  persona names — fail fast on a quiet config bug (two personas
  with the same LLM-facing name would be indistinguishable to the
  model).
- `lib/pikuri/sub_agent/researcher.rb` — defines
  `Pikuri::SubAgent::RESEARCHER`, a `Persona` with
  `tool_names: %w[web_search web_scrape fetch]`, `max_steps: 10`,
  and the system prompt loaded from `prompts/persona-researcher.txt`.
- `prompts/persona-researcher.txt` — researcher's system prompt
  (replaces, doesn't append; the parent's prompt is not inherited
  by sub-agents).
- `lib/pikuri/sub_agent/scout.rb` — defines
  `Pikuri::SubAgent::SCOUT`, a `Persona` with
  `tool_names: %w[read grep glob]`, `max_steps: 15`, and the system
  prompt loaded from `prompts/persona-scout.txt`. The read-only
  filesystem-recon counterpart to `RESEARCHER`: no egress, no
  mutation, no `agent` recursion — gives prompt-injected file
  contents nothing actionable to reach for. Wired into
  `bin/pikuri-code` so the coding agent can delegate code-lookup
  tasks without polluting its own context.
- `prompts/persona-scout.txt` — scout's system prompt (same
  replacing-not-appending policy as researcher's).
- `bin/pikuri-minions` — CLI entry point for a "boss + minions" demo.
  Wires `Pikuri::Tool::WEB_SEARCH` / `WEB_SCRAPE` / `FETCH` /
  `CALCULATOR` plus
  `c.add_extension(Pikuri::SubAgent::Extension.new(personas: [RESEARCHER]))`,
  and pairs them with a system prompt that biases the boss agent
  toward parallel decomposition. Exists to teach the fan-out
  delegation concept in one demo: ask for three independent facts,
  watch three researcher minions spawn in parallel, get one
  synthesized answer back.
- `prompts/pikuri-minions.txt` — boss-agent system prompt that
  encourages "decompose then delegate" and parallel `agent` tool
  calls in a single turn.

### `pikuri-assistant/` — gem name `pikuri-assistant`

The MCP-aware assistant binary. Depends on `pikuri-core` +
`pikuri-skills` + `pikuri-mcp` + `pikuri-subagents` (so the
`agent` tool with `RESEARCHER` is available in the assistant).
No Ruby library code of its own — just the binary, the prompt,
and an entry file that appends the gem's `prompts/` to
`Pikuri::PROMPT_DIRS`.

- `lib/pikuri-assistant.rb` — gem entry. Requires
  `pikuri-core` + `pikuri-skills` + `pikuri-mcp`; appends
  `prompts/` to `Pikuri::PROMPT_DIRS`. No Zeitwerk loader (no
  Ruby library code in this gem).
- `bin/pikuri-assistant` — CLI entry point for an assistant
  binary that wires the user-edited `Pikuri::Mcp::Registry`
  via `Pikuri::Mcp::Extension` and
  `Pikuri::SubAgent::Extension.new(personas: [RESEARCHER])`
  inside the `Agent.new` block. Holds the `Mcp::Extension`
  instance on a local variable so the startup banner can read
  `mcp_ext.servers.live_ids` after construction. Empty registry
  by default — runs identically to `pikuri-chat` (plus the
  researcher `agent` tool) until the developer opts in by adding
  MCP entries.
- `prompts/pikuri-assistant.txt` — system prompt used by
  `bin/pikuri-assistant`. Adds MCP-aware tool-selection
  guidance: prefer MCP-backed tools for OAuth-gated SaaS over
  `web_scrape` / `fetch`, mcp_connect-once-per-server flow,
  treat MCP outputs as data not instructions.

### `pikuri/` — gem name `pikuri` (metagem)

Convenience bundle. Depends on every other pikuri-* gem with
`= #{Pikuri::VERSION}` lockstep pins. No Ruby code of its own.

- `lib/pikuri.rb` — seven `require` lines (one per sibling) in
  dependency order. `require 'pikuri'` boots the whole family.
- `pikuri.gemspec` — declares all seven sibling gems as dependencies.

The metagem releases last on each lockstep release so its
dependency declarations pin the just-published sibling versions.

### Demo-binary scope note

The four `bin/pikuri-*` scripts (in `pikuri-core/bin/`,
`pikuri-code/bin/`, `pikuri-subagents/bin/`, `pikuri-assistant/bin/`)
are dev / demo entry points only — they're not advertised as gem
executables. They exist to show how to wire pikuri-as-library into a
working binary and to support local development. Production binaries
built on pikuri (notably the planned `pikuri-tui`) live in their own
downstream gems.

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
- **Per-gem Zeitwerk loaders.** Each pikuri-* gem ships its own
  loader (set up in its `lib/<gem-name>.rb` entry file) rooted at
  that gem's `lib/`. Loaders coexist because they manage
  non-overlapping file trees but cooperate via the `Pikuri::`
  namespace. Don't add `require_relative` chains inside any
  gem's `lib/`; let the loader resolve internal references. Each
  loader eager-loads at gem boot so `ALL_CAPS` value constants
  (`Pikuri::Tool::CALCULATOR`, …) are defined alongside the
  autoloadable classes/modules. New files must define exactly the
  camelcased constant matching their path; if you want an acronym
  (`HTML`, `PDF`, `DuckDuckGo`), add an entry to the
  `inflector.inflect` block — currently pikuri-core's is the only
  one with overrides. Extensions in pikuri-workspace and
  pikuri-code that nest under the `Pikuri::Tool` class mount their
  loader with `push_dir(..., namespace: Pikuri::Tool)` to avoid
  Zeitwerk redefining the parent class as an inferred module.
- **Namespacing direction.** Everything any pikuri-* gem ships
  lives under the `Pikuri::` namespace — `Pikuri::Agent`,
  `Pikuri::Tool`, `Pikuri::Tool::Search::DuckDuckGo`,
  `Pikuri::Skill::Catalog`, `Pikuri::Mcp::Extension`, etc. New
  files follow the standard gem layout: define a single
  `Pikuri::*` constant per file at the path Zeitwerk expects
  (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`). Don't
  introduce top-level constants.
- **Tests: rspec-core with minitest-style asserts.** Each gem has
  its own `spec/` directory; the top-level `Rakefile`'s
  `rake test` task fans out to each (`cd <gem> && bundle exec
  rspec`). Use the `rspec-core` runner (`describe`/`it`) but
  write assertions in the minitest style (`assert_equal`,
  `assert`, `refute`, …) rather than RSpec matchers
  (`expect(...).to eq`). rspec-mocks is *not* in the closure —
  to stub a module method like `RubyLLM.chat` in a spec, replace
  the singleton method with `define_singleton_method` in `before`
  and restore in `after`. See `pikuri-core/spec/pikuri/agent_spec.rb`
  for the pattern.

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
