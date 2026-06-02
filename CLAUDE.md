# CLAUDE.md

This file is the pointer-level orientation map. Rationale and per-file
purpose live in YARD headers on the classes/modules themselves — when
a section here says "see {ClassName}", that yardoc is the source of
truth and this file just records the invariant.

## What this project is

A Ruby implementation of an AI assistant on top of
[ruby_llm](https://rubyllm.com), shipped as ten sibling gems in
one monorepo. ruby_llm owns the chat transport and the Thought /
Tool-call / Observation loop; pikuri owns the *extension surface*:
the strict `Pikuri::Tool::Parameters` validator, the
Configurator + Extension protocol that hosts wire into via the
`Agent.new` block, the listener event stream, the `max_steps`
budget, and a deliberate set of bundled tools.

The gem inventory:

- `pikuri-core` — `Agent` runtime + `Tool` framework + Extension
  protocol + listener stream + four stateless bundled tools
  (calculator, web search, web scrape, fetch) + `bin/pikuri-chat`.
- `pikuri-skills` — Agent Skills standard implementation.
- `pikuri-tasks` — in-memory task list + four content-as-identifier
  tools (`task_create` / `task_in_progress` / `task_completed` /
  `task_delete`).
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams +
  Read/Write/Edit/Grep/Glob.
- `pikuri-code` — `Bash` + `bin/pikuri-code` (in-repo coding agent).
- `pikuri-mcp` — Model Context Protocol support.
- `pikuri-subagents` — the `agent` tool + `Persona` record +
  bundled `RESEARCHER` / `FILE_MINER` + `bin/pikuri-minions` fan-out demo.
- `pikuri-vectordb` — local-corpus vector search + agentic RAG:
  `vectordb_search` / `vectordb_read` / `vectordb_reindex` tools,
  swappable `Backend` (`InMemory` / `Chroma`), embedder + reranker +
  chunker pipeline, bundled `LIBRARIAN` persona, `bin/pikuri-corpus`.
- `pikuri-memory` — durable cross-conversation memory backed by
  mem0: `recall` tool + automatic per-turn prefetch and capture
  (`Memory::Extension`), self-managed mem0 + Qdrant sidecar
  (`Mem0Server`), `bin/pikuri-memory` no-egress demo.
- `pikuri-assistant` — MCP-aware `bin/pikuri-assistant`.
- `pikuri` — convenience metagem depending on all ten.

## Why this exists

The motivating frustration: the existing agent stacks (the "PI" and
"OpenClaw" projects) have grown big and hit a steep learning curve.
A privacy-conscious user arriving fresh hits a wall of massive JSON
configuration with no clear start-here. Pikuri is the counter-move:

- **Start slowly.** Sane defaults, no config file required for a
  first conversation. Surface area grows as the user grows into it.
- **Privacy-first.** Defaults wire the local llama.cpp server — no
  cloud account, no API key, no telemetry. External providers
  require explicit opt-in via ruby_llm.
- **Educates along the way.** The code is meant to be read: per-file
  YARD headers explain *why* each piece exists, system prompts are
  plain text in `prompts/`, and conventions are deliberately verbose
  so the project doubles as a tour of how a small agent runtime
  actually works.
- **Small enough to audit.** A user should be able to read pikuri's
  sources end-to-end in an evening. Every new feature is weighed
  against the line count it adds. Abstraction layers that exist
  "just in case" lose every argument; concrete code that does one
  named thing wins.

## Reference projects

When designing new features, the closest prior art to mine:

- **opencode** — <https://github.com/anomalyco/opencode/>. TypeScript /
  Effect-TS / Bun. Tool registry shape, skill loading, permission
  system.
- **PI** — <https://github.com/earendil-works/pi>. TypeScript / Bun.
  Agent Skills standard implementation, `.agents/` cross-harness
  skill directory convention.
- **hermes-agent** — <https://github.com/nousresearch/hermes-agent>.
  Python. Memories are a primary concept — useful prior art for any
  memory / "what the user is working on" feature.

Both opencode and PI implement the [Agent Skills standard](https://agentskills.io/specification),
which is also what Claude Code follows.

## Seams (invariants)

Every seam below has detailed rationale in the corresponding class's
yardoc. CLAUDE.md only records the invariant.

- **Loop seam.** ruby_llm owns `Chat#complete`; pikuri-side
  loop-wiring is confined to `bin/pikuri-*` (boot/`RubyLLM.configure`),
  `pikuri-core/lib/pikuri/agent.rb` (callbacks + `run_loop`), and
  `pikuri-core/lib/pikuri/tool.rb` (the `Pikuri::Tool` →
  `RubyLLM::Tool` adapter). Don't construct a `Chat` or attach
  callbacks from anywhere else. See {Pikuri::Agent}.
- **Value-type passthrough.** Anywhere in pikuri-* `lib/` may
  reference `RubyLLM::Content` / `Attachment` / `Message` directly
  when wrapping would be a transparent passthrough. See
  {Pikuri::Agent} ("Roles in this file") for the rule of preference.
- **Subprocess seam.** All subprocess spawning in pikuri-* `lib/`
  routes through `Pikuri::Subprocess.spawn`. Grep-enforceable:
  `grep -rnE 'Process\.spawn|Open3\.|\bsystem\(' pikuri-*/lib/`
  should only hit `pikuri-core/lib/pikuri/subprocess.rb` (plus the
  comment in `pikuri-mcp/lib/pikuri/mcp/servers.rb` explaining the
  exception). The documented
  exception is `pikuri-mcp/lib/pikuri/mcp/client_wrapper.rb`
  (stdio MCP entries — the `mcp` gem owns its own subprocess
  lifecycle). HTTP MCP entries don't subprocess at all. See
  {Pikuri::Subprocess} and {Pikuri::Mcp::ClientWrapper}.
- **Finalizers / teardown seam.** One process-global teardown
  registry with a single `at_exit`; no other `at_exit { close }`
  hooks in pikuri-* `lib/`. A resource registers at its *ownership
  boundary*: process-level infra a `bin/` starts self-registers
  (`Pikuri::VectorDb::ChromaServer` via `ensure_running!`);
  agent-owned resources do NOT — they ride the agent's `on_close`,
  which an extension arms via `c.on_close` (that writes to the
  agent's live handler list, so cleanup fires even mid-construction).
  `Agent` self-heals: it registers up front and, if the build phase
  raises, closes (firing armed handlers) and unregisters before
  re-raising — so a half-built agent leaks nothing. `#close`
  unregisters so an explicitly-closed object isn't pinned until exit.
  `Subprocess` registers at *load* time, so in the LIFO sweep it runs
  LAST — the SIGTERM-the-strays reaper after every graceful close.
  Even fire-and-forget disk cleanup routes here (the workspace's
  ephemeral-umbrella removal, via the block form of `.register`).
  Grep-enforceable: `grep -rn 'at_exit {' pikuri-*/lib/` should only
  hit `pikuri-core/lib/pikuri/finalizers.rb` (the registry's own
  hook). See {Pikuri::Finalizers}, {Pikuri::Agent},
  {Pikuri::Agent::Configurator} (the `on_close_sink`), and
  {Pikuri::Workspace::Filesystem.mint_internal_temp}.
- **Workspace seam.** Tools touching files (`Read`, `Write`,
  `Edit`, `Grep`, `Glob`, `Bash`) take a
  `Pikuri::Workspace::Filesystem` via constructor and route every
  path through `#resolve_for_read` / `#resolve_for_write` before
  touching the filesystem. See {Pikuri::Workspace::Filesystem}
  (project_root semantics, containment algorithm, `AllowAll`
  variant, project-root denylist).
- **Confirmer seam.** Tools that mutate user state (`Write`,
  `Bash`) take a `Pikuri::Workspace::Confirmer` via constructor
  and route every prompt through `#confirm?(prompt:)` — never
  `gets` / `puts` / `$stdin` / `$stdout` directly. See
  {Pikuri::Workspace::Confirmer}.
- **Sandbox seam.** `Pikuri::Code::Bash` takes a
  `Pikuri::Code::Bash::Sandbox` (default `Sandbox::NONE`) and
  wraps every spawned argv through `#wrap(argv)`. Distinct from
  Workspace: Workspace governs what the LLM observes; Sandbox
  governs the filesystem view of the bash subprocess. See
  {Pikuri::Code::Bash::Sandbox} and `Sandbox::Bubblewrap`
  (threat model, ephemeral overlays, container-socket footgun).
- **Streaming flag.** `Agent.new(..., streaming: true)` is opt-in
  and propagates to `Synthesizer.run` and spawned sub-agents so
  the whole agent tree streams or doesn't, consistently. Default
  `false` because `Terminal` still renders on `Event::Assistant`.
  See `Agent#initialize`'s `streaming:` yardoc.
- **Sub-agent propagation.** Listeners define `for_sub_agent(**)`
  as a duck-typed protocol; controls do not (the policy is
  inlined in `SubAgentTool#execute`). Sub-agents do NOT inherit
  extensions — each persona owns its toolset and system prompt
  verbatim. See {Pikuri::SubAgent::SubAgentTool} and
  {Pikuri::Agent::ListenerList#for_sub_agent}.
- **MCP-tool bypass.** MCP tools synthesize as raw
  `RubyLLM::Tool` subclasses inside `Mcp::Servers`, not as
  `Pikuri::Tool`s. See {Pikuri::Mcp::Servers} ("Why MCP tools
  bypass `Pikuri::Tool`").

### Out of scope

- Multi-provider config, vision/audio, embeddings — available via
  ruby_llm if/when needed; not part of pikuri today.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX
  shell, GNU coreutils' `timeout`, XDG cache layout, SIGTERM-based
  process-group cleanup. CI and bug reports follow the same
  prioritization.

## Layout

Rails-shape monorepo: each gem owns its own `lib/`, `spec/`,
`<gem>.gemspec`, entry file, and (where relevant) `bin/` +
`prompts/`. Top-level `Gemfile` wires every gem via
`gemspec path: '<gem>'` for dev mode; top-level `Rakefile` fans
out `rake test` and orchestrates `rake release VERSION=x.y.z` in
lockstep.

Everything pikuri ships lives under the `Pikuri::` namespace,
contributed cooperatively by each gem's own Zeitwerk loader. The
`Pikuri::PROMPT_DIRS` list is similarly cooperative: each gem
appends its `prompts/` at boot, so `Pikuri.prompt(name)` searches
across every loaded gem.

Per-file rationale lives in each source file's YARD header. The
per-gem one-liners:

- **`pikuri-core/`** — `Agent` (`lib/pikuri/agent.rb` +
  `lib/pikuri/agent/`), `Tool` + strict `Parameters`, the four
  bundled stateless tools (`calculator`, `web_search`,
  `web_scrape`, `fetch`), `Subprocess` chokepoint, `UrlCache`,
  `FileType` magic-byte sniffer, `bin/pikuri-chat`. Runtime deps:
  ruby_llm, Faraday, Rainbow, tty-markdown, Zeitwerk, Nokogiri,
  pdf-reader, reverse_markdown, ruby-readability, dentaku, tsort.
- **`pikuri-skills/`** — Agent Skills implementation:
  `Skill::Catalog`, `Skill::SkillTool`, `Skill::Extension`.
  Depends on `pikuri-core`. No new runtime deps.
- **`pikuri-tasks/`** — `Tasks::List` (in-memory, per-Agent) and
  the four task tool classes (`Tasks::Create`, `Tasks::InProgress`,
  `Tasks::Completed`, `Tasks::Delete`) plus `Tasks::Extension`.
  Content doubles as identifier across the four tools (no item
  IDs); state is dropped on agent close. Depends on `pikuri-core`.
  Stdlib-only; no new runtime deps.
- **`pikuri-workspace/`** — `Workspace::Filesystem`,
  `Workspace::Confirmer`, and the five file tools (`Read`,
  `Write`, `Edit`, `Grep`, `Glob`). Depends on `pikuri-core`.
  Stdlib-only; no subprocess execution.
- **`pikuri-code/`** — `Code::Bash`, `Code::Bash::Sandbox`,
  `Code::ToolchainPaths`, `Code::GitClone`, bundled
  `GIT_REPO_RESEARCHER` persona, `bin/pikuri-code`. Depends on
  `pikuri-core` + `pikuri-workspace` + `pikuri-subagents` +
  `pikuri-tasks`. The binary wires three personas:
  `FILE_MINER` + `RESEARCHER` from pikuri-subagents and
  `GIT_REPO_RESEARCHER` from this gem (the one persona that needs
  a tool — `GitClone` — outside the
  pikuri-subagents/pikuri-workspace surface). pikuri-tasks rides
  along on the parent agent only — sub-agents do not inherit
  the task list (consistent with the no-inherit rule).
- **`pikuri-mcp/`** — `Mcp::Registry`, `Mcp::Servers`,
  `Mcp::Extension`, `Mcp::Synthesizer` (description
  summarization), `Mcp::Verifier` (injection check), `Mcp::Cache`,
  `Mcp::ClientWrapper`. Depends on `pikuri-core` + the `mcp` gem.
- **`pikuri-subagents/`** — the delegation feature top to bottom:
  `SubAgent::SubAgentTool` (the `agent` tool),
  `SubAgent::Persona`, `SubAgent::Extension`, bundled
  `RESEARCHER` / `FILE_MINER`, `bin/pikuri-minions`. Depends on
  `pikuri-core` + `pikuri-workspace` (the latter so `SubAgentTool`
  can construct a per-invocation `Workspace::Filesystem` when a
  persona sets `needs_temp_workspace: true` — the persona stays
  declarative, with no Proc to pass). Personas reference tools by
  string name only so the gem stays decoupled from gems whose
  tools they happen to use.
- **`pikuri-vectordb/`** — local-corpus vector search + agentic
  RAG. `VectorDb::Extension` auto-registers the `vectordb_search`
  + `vectordb_read` + `vectordb_reindex` tools
  (`Search` / `Read` / `Reindex`) onto an `Agent` via
  `c.add_extension(...)` in the `Agent.new` block — same opt-in
  shape as pikuri-tasks / pikuri-skills. `vectordb_read` is
  parent-document retrieval (read a hit in full by `source`),
  inbound-only so it adds no egress leg. Pieces:
  swappable `Backend` (pure-Ruby `Backend::InMemory` cosine, the
  educational default; thin Faraday `Backend::Qdrant` /
  `Backend::Chroma` for persistence — Qdrant recommended, see
  `pikuri-vectordb/DESIGN.md`) + `Backend::Result`,
  `QdrantServer` / `ChromaServer` (self-managed docker container
  supervisors, route through `Pikuri::Subprocess.spawn`;
  `QdrantServer::IMAGE` pins the same tag as `Mem0Server`'s
  Qdrant, in lockstep by convention), `Indexer` (walks `source`, chunks,
  embeds, upserts), `Watcher` (filesystem-event daemon over the
  `listen` gem that keeps a live index fresh; wired in
  `bin/pikuri-corpus`), `Embedder` (wrapper over `RubyLLM.embed`),
  optional `Reranker::LlamaServer` (cross-encoder over
  `/v1/rerank`) + `Reranker::Hit`, `Chunker::FixedWindow` +
  `Tokenizer` (`CharHeuristic` default / `LlamaServer`) + `Chunk`.
  Text extraction reuses `Pikuri::FileType.read_as_text` from
  pikuri-core (plain text / Markdown / PDF; HTML deferred).
  Ships `bin/pikuri-corpus` — a single egress-free recall agent
  (`vectordb_search` + `vectordb_read` + `calculator`, no web
  tools): treats the corpus as private and breaks the trifecta by
  having no outbound leg (search and read are both inbound-only). The bundled `VectorDb::LIBRARIAN` persona is the
  privilege-separated counterpart for an agent that *does* have
  egress; it is NOT wired in `bin/pikuri-corpus` (a correct wiring
  needs persona-owned tools — see `ideas/trifecta-detector.md` —
  since sub-agent tools are a subset of the parent's). Its worked
  home is `pikuri-assistant` (ch7); same precedent as
  `GIT_REPO_RESEARCHER`. Depends on `pikuri-core` +
  `pikuri-subagents` + the `listen` gem (filesystem events for
  `Watcher`).
- **`pikuri-memory/`** — durable cross-conversation memory backed
  by mem0 (see `pikuri-memory/DESIGN.md` for the design rationale
  + threat model). `Memory::Extension` wires the `recall` tool
  + an automatic per-turn prefetch onto an agent via
  `c.add_extension(...)` — same opt-in shape as pikuri-tasks /
  pikuri-vectordb. Pieces: thin Faraday `Memory::Mem0Client`
  (mem0 REST: `add`/`search`/`get_all`/`delete`/`reset`),
  `Memory::Recorder` (off-the-loop async capture queue, bounded
  flush on close), `Memory::Record` value type, `Memory::Recall`
  (the `recall` tool), `Memory::Mem0Server` (the self-managed mem0 +
  Qdrant sidecar supervisor — `ChromaServer`-shaped, drives
  `docker compose` over `docker/` artifacts through
  `Pikuri::Subprocess.spawn`), and the curated `memory-extraction`
  prompt in `prompts/`. The three retrieval tiers — resident persona
  (always-in-prompt) + automatic prefetch + explicit `recall` —
  mirror pikuri-vectordb's `vectordb_search`/`vectordb_read` split.
  **Reads sync (vector search, ms), writes async** (the ~3s
  extraction call is deferred off the interaction path). Two
  structural feedback-loop defenses: capture feeds **user-role
  content only**, and recall lands as a **`:system` message**
  (never a user turn) — so recalled memories are never
  re-extracted. Safe only on a no-untrusted-ingest / no-egress
  agent (the `@private` config); porting onto an egress-capable
  agent re-opens recall-poisoning. Two ways to a server: let pikuri
  manage it (`Mem0Server`, needs `docker` + `git`) or bring your own
  (`Mem0Client.new(endpoint:)`). The supervisor builds mem0 **from a
  pinned source checkout** (no usable published image) with a
  fail-loud build-time patch swapping `DEFAULT_CONFIG` from pgvector
  to Qdrant — pgvector both has a top-k inversion bug *and* connects
  to Postgres eagerly at boot, so Qdrant-by-default is what lets the
  stack run **Postgres-free** (2 containers, not 3). Verified
  end-to-end against a local llama.cpp router (non-reasoning
  `Qwen2.5-7B` extractor + `nomic` embedder): boots Postgres-free,
  add/search rank correctly through the REST API. Rides the one new
  pikuri-core primitive, `Extension#on_user_message` (the per-turn
  prefetch + capture hook). No persona (a memory-only persona is
  meaningless without the rest of `@private`'s toolset). Ships
  `bin/pikuri-memory` — the no-egress `@private` demo agent
  (`calculator` + memory only). Depends only
  on `pikuri-core` (mem0 owns embedding + extraction).
- **`pikuri-assistant/`** — `bin/pikuri-assistant` (MCP-aware
  binary) + prompt. No Ruby library code of its own. Depends on
  `pikuri-core` + `pikuri-skills` + `pikuri-mcp` + `pikuri-subagents`
  + `pikuri-vectordb` + `pikuri-memory` — the last two are
  forward-prep for the ch7 assistant shape: declared but not yet
  wired in the binary (vectordb's correct wiring is gated on
  persona-owned tools, see `ideas/trifecta-detector.md`).
- **`pikuri/`** (metagem) — `lib/pikuri.rb` is ten `require`s
  in dependency order. Lockstep version pins. No Ruby code.
  Releases last on each release.

The six `bin/pikuri-*` scripts are dev / demo entry points only —
not advertised as gem executables. Production binaries built on
pikuri (notably the planned `pikuri-tui`) live in downstream gems.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value
  objects, Faraday for HTTP, Rainbow for terminal color. ruby_llm
  is the LLM transport — don't add provider-specific SDKs.
- **`# frozen_string_literal: true`** at the top of every Ruby
  file (`lib/`, `spec/`, `bin/*`). Add it to any new file.
- **YARD docs on every public module, class, and method.** Use
  concrete types in `@param` and `@return` (`String`, `Integer`,
  `Array<Hash>`, `Faraday::Connection`, `String, nil`) — never
  bare `Object` or `Any`. Document expected exceptions with
  `@raise`. One-line summary first, blank line, then tags.
  Applies to `lib/`; `bin/` and `spec/` don't need it. **Rationale
  belongs here, not in CLAUDE.md** — when adding a non-obvious
  design decision, put it in the class's yardoc and reference it
  from CLAUDE.md only if it's a cross-cutting invariant.
- **Bundler.** Entry-point scripts live in `bin/` and are run
  directly (`./bin/pikuri-chat "question"`); each self-bootstraps
  via `require 'bundler/setup'`, so callers don't need `bundle
  exec`. Add gems to `Gemfile` with conservative pessimistic
  constraints (`~>`).
- **Diagnostics go through `Pikuri.logger_for('Name')`.** Each
  subsystem holds a memoized stdlib `Logger`, tagged with a
  `progname:` (e.g. `LOGGER = Pikuri.logger_for('Engines')`), all
  writing through `Pikuri.log_io` (default `$stderr`). Level
  resolves as `PIKURI_LOG_<NAME>` → `PIKURI_LOG` → `INFO`. Use
  these instead of `puts` / `warn` / `$stderr.puts` for log
  lines. Listener-driven rendering of the LLM stream stays on
  stdout via `Terminal` — that's not logging.
- **Errors are loud.** On unexpected internal state, raise with
  the offending data included. Tools split this in two: failures
  the LLM can react to (bad arguments, HTTP 4xx/5xx, network
  blips, search rate-limits, division by zero) come back as
  `"Error: <message>"` Strings and become the next observation;
  bugs in pikuri's own code (parser regressions, schema misuse,
  misconfigured clients) keep raising. The narrow carve-out:
  third-party rendering bugs *secondary to the loop* (e.g.
  `tty-markdown` choking on an edge case) get rescued narrowly,
  logged, and fall back to degraded rendering — but NOT errors
  from libraries on the actual chat path (ruby_llm, Faraday
  inside a tool).
- **Per-gem Zeitwerk loaders.** Each gem ships its own loader
  rooted at its `lib/`. Don't add `require_relative` chains
  inside any gem's `lib/`. Each loader eager-loads at gem boot
  so `ALL_CAPS` value constants are defined alongside autoloadable
  classes. New files must define exactly the camelcased constant
  matching their path; for acronyms (`HTML`, `PDF`, `DuckDuckGo`)
  add an `inflector.inflect` entry. Extensions that nest under
  the `Pikuri::Tool` class mount with
  `push_dir(..., namespace: Pikuri::Tool)` to avoid Zeitwerk
  redefining the parent class.
- **Namespacing.** Everything any pikuri-* gem ships lives under
  `Pikuri::`. New files: define a single `Pikuri::*` constant per
  file at the path Zeitwerk expects
  (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`). No
  top-level constants.
- **Tests: rspec-core with minitest-style asserts.** Each gem has
  its own `spec/`; `rake test` fans out (`cd <gem> && bundle exec
  rspec`). Use `describe` / `it` but write `assert_equal` /
  `assert` / `refute` rather than RSpec matchers. rspec-mocks is
  *not* in the closure — to stub a module method like
  `RubyLLM.chat`, use `define_singleton_method` in `before` and
  restore in `after`. See
  `pikuri-core/spec/pikuri/agent_spec.rb` for the pattern.
- **Tool descriptions follow opencode-shape:** a `description:`
  heredoc with a one-line summary, a blank line, then a `Usage:`
  bullet list. Per-argument constraints (defaults, caps, format)
  live in the parameter description, not in the tool description.
  Universal failure-recovery guidance ("on `Error: ...`, use what
  you have or admit defeat") lives in per-binary system prompts,
  not per-tool. Add an example value
  (`'..., e.g. "https://example.com"'`) to every parameter
  description — the LLM's argument-filling reliability is
  measurably better with one.
- **User-facing docs: prefer concrete over abstract.** Readers
  abstract easily; the reverse takes effort. *"Delete your home
  folder"* beats *"filesystem mutation outside the workspace"*;
  *"the CPU's NX flag"* beats *"a structural data/instructions
  distinction."* Applies to `README.md`, `SECURITY.md`,
  `IDEAS.md`, `COMPARISON.md`, and the `docs/guide/` chapters —
  any prose meant for a human reader.

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.**
  When changing `lib/pikuri/agent.rb`, the question is "what hooks
  fire when?" — the iteration itself lives in `RubyLLM::Chat#complete`.
  Don't reimplement the loop in pikuri; reach for a different
  listener instead.
- **Readable, not obfuscated.** Prefer the simplest implementation
  that does the job. Don't golf for line count, but also don't add
  abstraction layers, plugin systems, or configuration knobs that
  aren't needed for the next concrete step.
- **Grow by adding tools, listeners, or controls — not by
  complicating the loop.** New capabilities land as new
  `Pikuri::Tool` constants under `lib/pikuri/tool/`, new
  pure-consumer listeners under `lib/pikuri/agent/listener/`, or
  new host-facing controls under `lib/pikuri/agent/control/`,
  each with their own specs. Neither `Pikuri::Tool`, the
  `Pikuri::Agent`, nor ruby_llm's loop should need to know about
  them.

## CI

Woodpecker CI runs `rake test` on push / pull-request / manual,
configured in `.woodpecker.yml`. Dashboard:
<https://ci.codeberg.org/repos/17229>. The `ruby:4.0` image doesn't
ship `ripgrep`, so the config installs it (the Grep tool's specs
need `rg`). Gem deps are cached in Hetzner Object Storage, keyed on
`Gemfile.lock`.
