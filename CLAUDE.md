# CLAUDE.md

This file is the pointer-level orientation map. Rationale and per-file
purpose live in YARD headers on the classes/modules themselves — when
a section here says "see {ClassName}", that yardoc is the source of
truth and this file just records the invariant.

## What this project is

A Ruby implementation of an AI assistant on top of
[ruby_llm](https://rubyllm.com), shipped as twelve sibling gems in
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
- `pikuri-extractors` — document extractors
  (DOCX/ODT/XLSX/PPTX/EPUB/RTF/PDF → Markdown) for the `Extractor`
  registry, converted in a one-shot networkless docker container
  (host pandoc/markitdown/pdftotext CLI fallback).
- `pikuri-pdf` — PDF → text for the `Extractor` registry:
  in-process pure-Ruby pdf-reader, lazily paged. Superseded by
  pikuri-extractors' PDF arm in full wirings — pick one per host.
- `pikuri-skills` — Agent Skills standard implementation.
- `pikuri-tasks` — in-memory task list + four tools
  (`task_create` / `task_in_progress` / `task_completed` /
  `task_delete`); JSON-array mass-create, mutations address
  items by numeric id.
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams +
  Read/Write/Edit/Grep/Glob.
- `pikuri-code` — `Bash` + `bin/pikuri-code` (in-repo coding agent).
- `pikuri-mcp` — Model Context Protocol support +
  `bin/pikuri-openlibrary` one-MCP demo.
- `pikuri-subagents` — the `agent` tool + `Persona` record +
  bundled `RESEARCHER` / `FILE_MINER` + `bin/pikuri-minions` fan-out demo.
- `pikuri-vectordb` — local-corpus vector search + agentic RAG:
  `vectordb_search` / `vectordb_read` / `vectordb_reindex` tools,
  swappable `Backend` (`InMemory` / `Qdrant` / `Chroma`), embedder +
  reranker + chunker pipeline, bundled `LIBRARIAN` persona,
  `bin/pikuri-corpus`.
- `pikuri-memory` — durable cross-conversation memory backed by
  mem0: `recall` tool + automatic per-turn prefetch and capture
  (`Memory::Extension`), self-managed mem0 + Qdrant sidecar
  (`Mem0Server`), `bin/pikuri-memory` no-egress demo.
- `pikuri-assistant` — MCP-aware `bin/pikuri-assistant`.
- `pikuri` — convenience metagem depending on all twelve.

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
  loop-wiring is confined to `bin/pikuri-*` (boot),
  `pikuri-core/lib/pikuri/agent.rb` (callbacks + `run_loop`), and
  `pikuri-core/lib/pikuri/tool.rb` (the `Pikuri::Tool` →
  `RubyLLM::Tool` adapter). Don't construct a `Chat` or attach
  callbacks from anywhere else. See {Pikuri::Agent}.
- **Connection seam.** A model's connection (base URL + key) rides
  its `Agent::ChatTransport`, not a process-global `RubyLLM.configure`:
  `Agent` maps `transport.api_base`/`api_key` onto a per-chat
  `RubyLLM::Context` (`build_context`), so several agents — and the
  sub-agents / synthesizer that inherit `parent.transport` — stay
  isolated and can't stomp a shared global. The chat-only `bin/pikuri-*`
  build their transport with `ChatTransport.from_openai_server`, which
  also normalizes a trailing `/v1` (so a server value works with or
  without it). The one surviving `RubyLLM.configure` is
  `bin/pikuri-corpus`, where `RubyLLM.embed` (the Indexer/Watcher) runs
  outside any Agent and so can't ride a per-agent Context. See
  {Pikuri::Agent::ChatTransport} and {Pikuri::Agent#build_context}.
- **Value-type passthrough.** Anywhere in pikuri-* `lib/` may
  reference `RubyLLM::Content` / `Attachment` / `Message` directly
  when wrapping would be a transparent passthrough. See
  {Pikuri::Agent} ("Roles in this file") for the rule of preference.
- **Extraction seam.** Every format→text conversion routes through
  the `Pikuri::Extractor` registry (`.extract` for whole documents,
  `.extract_paged` for the line-windowed LLM-tool shape).
  `Tool::Scraper` (web bytes + Content-Type header) and
  `FileType.read_as_text` / `read_as_text_paged` (local paths) are
  thin fronts over it; supporting a new format means inserting a
  registry entry, not a new dispatcher arm (worked examples:
  pikuri-extractors' `DOCUMENTS` and pikuri-pdf's `Extractors::PDF`,
  each plugged in via an explicit `register` call from the host
  script — never by require alone; `PDF` front-inserts because its
  magic sniff must beat `HTML`'s content-type match).
  Grep-enforceable:
  `grep -rnE "require '(pdf-reader|readability|reverse_markdown)'" pikuri-*/lib/`
  should only hit `pikuri-core/lib/pikuri/extractor/` and
  `pikuri-pdf/lib/`. See
  {Pikuri::Extractor} (duck type, error taxonomy, why windowing is
  not part of the extractor interface).
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
  (`Pikuri::VectorDb::Server::Chroma` via `ensure_running!`);
  agent-owned resources do NOT — they ride the agent's `on_close`,
  which an extension arms via `c.on_close` at configure time or
  `ctx.on_close` at bind time (both write to the agent's live
  handler list, so cleanup fires even mid-construction).
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
- **Capability seam (ExtensionContext).** A live `Agent` reference
  grants read access only — no `listeners` / `chat` readers, no
  emit method, no post-construction `on_close`. Everything that
  *acts on* a wired agent (`emit_event` for domain events,
  `add_raw_tool`, `sub_agent_listeners`, `on_close`) lives on
  `Pikuri::Agent::ExtensionContext`, constructed once per agent and
  handed only to `Extension#bind` / `#on_user_message`; non-extension
  consumers (`SubAgentTool`, `Mcp::Servers::Connect`) receive it by
  explicit handoff from their extension's `bind`. Core `Event`
  variants remain Agent-emitted loop narration; gems define domain
  events in their own namespace (e.g. `Tasks::ListChanged`) and emit
  via `ctx.emit_event` — listeners must no-op on unknown variants.
  Grep-enforceable:
  `grep -rn 'emit_event\|add_raw_tool\|sub_agent_listeners' pikuri-*/lib/`
  is the capability-user roster, and `listeners.emit` outside
  `agent.rb` / `extension_context.rb` should hit nothing. See
  {Pikuri::Agent::ExtensionContext}.
- **Workspace seam.** The five file tools (`Read`, `Write`,
  `Edit`, `Grep`, `Glob`) take a `Pikuri::Workspace::Workspace`
  composite via constructor; `Bash` takes the bare
  `Pikuri::Workspace::Filesystem` (it governs the subprocess fs
  view, not the read record). Every path routes through
  `#resolve_for_read` / `#resolve_for_write` before touching the
  filesystem. The composite pairs the `Filesystem` (path
  resolution / containment / sandboxing, kept pure) with this
  session's read record, and enforces the **read-before-edit
  gate**: `Read` marks a path read (`#mark_read`); `Edit` and
  overwrite-`Write` refuse a path not yet read (`#read?`) — making
  Edit's "you must Read first" promise real. Each `Workspace` owns
  its own record, so a sub-agent's temp clone starts empty.
  `Workspace::Extension` is the single registration point that wires
  the five tools sharing one composite. See
  {Pikuri::Workspace::Workspace} and {Pikuri::Workspace::Filesystem}
  (project_root semantics, containment algorithm, `AllowAll`
  variant, project-root denylist).
- **Confirmer seam.** Tools that mutate user state (`Write`,
  `Bash`) take a `Pikuri::Workspace::Confirmer` via constructor
  and route every prompt through `#confirm?(request:)` with a
  semantic `Confirmer::Request` (question + optional detail, raw
  bytes). Presentation belongs to the confirmer — color, the
  answer cue, and neutralizing hostile LLM bytes — never to tool
  code, which also never touches `gets` / `puts` / `$stdin` /
  `$stdout` directly. The chrome-independent half of that
  neutralization (defang control bytes incl. ESC, flag bidi /
  zero-width / homoglyph spoofs) is the shared `Pikuri::Sanitizer`,
  which every chrome routes attacker-controlled text through;
  only the medium-specific wrapping stays in the chrome (a
  terminal prints the sanitized text directly; a web client
  additionally HTML-escapes). See {Pikuri::Workspace::Confirmer}
  and {Pikuri::Sanitizer}.
- **Sandbox seam.** `Pikuri::Code::Bash` takes a
  `Pikuri::Code::Bash::Sandbox` (default `Sandbox::NONE`) and
  wraps every spawned argv through `#wrap(argv)`. Distinct from
  Workspace: Workspace governs what the LLM observes; Sandbox
  governs the filesystem view of the bash subprocess. See
  {Pikuri::Code::Bash::Sandbox} and `Sandbox::Bubblewrap`
  (threat model, ephemeral overlays, container-socket footgun).
  `Sandbox::FullFsNoNet` is its inverse — full-fs read-write but
  `--unshare-net` (the OS-helper's kernel-severed egress; raises
  rather than degrading if the network can't be unshared).
- **Environment is not a secret store.** `ENV` is ambient process
  state, not a credential channel — pikuri never *filters* it before
  spawning a subprocess (no env-scrubbing primitive; a prototype
  `scrub_env!` was deliberately removed). Rationale: filtering env is
  an unwinnable allowlist/denylist game, and outside a real sandbox it
  closes nothing — a trusted MCP run bare still has full `$HOME` +
  network, so a trimmed env is theatre; an untrusted MCP belongs in
  docker (worked example: `bin/pikuri-openlibrary`'s `docker run`),
  which clears env as a unit. So env is inherited *wholesale* by
  trusted children (`Bash` after confirmation, build tools — trimming
  only breaks `JAVA_HOME`/toolchain vars), and cleared *as a unit by
  the isolation boundary* (Bubblewrap `--clearenv`, docker) for
  untrusted ones — env-clearing is a property of the sandbox, never a
  free-floating filter. Corollaries: pikuri config holds tokens
  **verbatim**, not `ENV['X']` refs (long-term secrets live in
  permissioned files, like `~/.aws/credentials` / `gh` / ssh); and
  `Mcp::Registry::StdioEntry#env` is the *legitimate* per-child
  credential channel (a specific secret to a specific server, via
  `envp` not argv — not `ps`-visible). The thing we reject is ambient
  *inheritance* of unrelated secrets, not passing a needed one
  explicitly. See {Pikuri::Code::Bash::Sandbox} and
  {Pikuri::Mcp::Registry::StdioEntry}.
- **Streaming flag.** `Agent.new(..., streaming: true)` is opt-in
  and propagates to the step-exhaustion synthesizer and spawned
  sub-agents so the whole agent tree streams or doesn't,
  consistently. Default `false` because `Terminal` still renders
  on `Event::Assistant`. See `Agent#initialize`'s `streaming:`
  yardoc.
- **Step-exhaustion policy.** What happens when a `StepLimit`
  trips travels with the budget, not the agent:
  `StepLimit.new(max:, on_exhausted: :raise | :synthesize)`,
  default `:raise` (the invalid "synthesize without a budget"
  state is unrepresentable). Q&A wirings opt into `:synthesize`;
  coding agents keep `:raise` (a tools-free pass can't finish
  code); sub-agents are always `:synthesize` (they must return
  usable text to the parent's tool call). The synth itself is a
  nested tools-free `Agent` — no chat is constructed outside
  `Agent`. See {Pikuri::Agent::Control::StepLimit} and
  {Pikuri::Agent::Synthesizer}.
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
  `FileType` magic-byte sniffer, `Extractor` registry (HTML /
  Passthrough → Markdown text, the extraction seam; PDF and office
  formats are plug-in gems), `bin/pikuri-chat`. Runtime deps:
  ruby_llm, Faraday, Rainbow, Zeitwerk, Nokogiri,
  reverse_markdown, ruby-readability.
- **`pikuri-extractors/`** — `Extractors::Documents` +
  the shared `Extractors::DOCUMENTS` instance: DOCX / ODT / XLSX /
  legacy XLS / PPTX / EPUB / RTF / PDF → Markdown for the `Extractor`
  registry, by piping bytes through pandoc / markitdown / pdftotext
  (the PDF arm rebuilds pikuri-pdf's `--- Page N ---` markers from
  pdftotext's `\f` separators) — preferably
  in a one-shot networkless locally-built docker container
  (`docker/Dockerfile`, pinned versions, no volume mounts; untrusted
  parser input never touches host fs or network), falling back to
  host CLIs. **Registration is explicit** —
  `DOCUMENTS.register` in the host script; requiring the gem changes
  nothing (same opt-in shape as `c.add_extension`). Conversions ride
  the `Subprocess.run` filter shape (stdin streamed from the source
  IO, stdout → Tempfile, stderr captured). No result cache: paged reads re-convert
  (accepted). ODS/ODP, OCR, audio, LibreOffice: out of scope (see
  the class yardoc). PDF here vs pikuri-pdf is a pick-one-per-wiring
  choice: sandboxed-but-rerun-per-page here, in-process-and-lazy
  there (trade-off table in the class yardoc).
  Depends on `pikuri-core`. No new runtime deps.
- **`pikuri-pdf/`** — `Extractors::PDF`: PDF → text for the
  `Extractor` registry via the pure-Ruby pdf-reader gem, in-process
  and lazily paged (`extract_lines` parses pages on demand, so a
  windowed `read` of a 500-page PDF parses only its window).
  **Registration is explicit** — `Extractors::PDF.register` in the
  host script (same opt-in shape as `DOCUMENTS`); it *front*-inserts
  because the `%PDF-` magic sniff must beat `HTML`'s content-type
  match under lying headers. Split out of pikuri-core so pdf-reader's
  five transitive deps stay out of the core audit tree. Wired by
  `bin/pikuri-corpus` (guide ch3 — the no-docker registry intro);
  deliberately NOT by `bin/pikuri-chat` (ch1 stays pure-core) nor by
  `bin/pikuri-assistant` (ch7 supersedes it with pikuri-extractors'
  sandboxed PDF arm — one extractor per format per wiring; the
  trade-off table lives in {Pikuri::Extractors::Documents}'s
  yardoc). Depends on `pikuri-core` + pdf-reader.
- **`pikuri-skills/`** — Agent Skills implementation:
  `Skill::Catalog`, `Skill::SkillTool`, `Skill::Extension`.
  Depends on `pikuri-core`. No new runtime deps.
- **`pikuri-tasks/`** — `Tasks::List` (in-memory, per-Agent) and
  the four task tool classes (`Tasks::Create`, `Tasks::InProgress`,
  `Tasks::Completed`, `Tasks::Delete`) plus `Tasks::Extension`.
  `task_create` takes a JSON array of strings; the three mutation
  tools address items by numeric id (never reused after delete;
  rationale for both reversals in {Pikuri::Tasks::Create} and the
  guide ch11); state is dropped on agent close. `Extension#bind`
  arms a `Tasks::ListChanged` domain event per list mutation
  (snapshot payload — the worked example of `ctx.emit_event`; UI
  listeners observe the list without touching the
  agent-thread-confined `List`). Depends on
  `pikuri-core`. Stdlib-only; no new runtime deps.
- **`pikuri-workspace/`** — `Workspace::Filesystem`, the
  `Workspace::Workspace` composite (Filesystem + read record,
  backing the read-before-edit gate), `Workspace::Confirmer`, the
  five file tools (`Read`, `Write`, `Edit`, `Grep`, `Glob`), and
  `Workspace::Extension` (their single registration point). Depends
  on `pikuri-core`. No new runtime deps (Rainbow rides in via
  pikuri-core for `Confirmer::Terminal`); no subprocess execution.
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
  summarization), `Mcp::Verifier` (injection check), `Mcp::Thinker`
  (the shared one-shot LLM pass both ride; constructed by them
  internally from a `transport:`), `Mcp::Cache`,
  `Mcp::ClientWrapper`, `bin/pikuri-openlibrary` (the guide-ch5
  demo: one hardcoded Open Library MCP in a locally-built Docker
  container + `calculator`, no private data wired in — the
  hand-edit-your-own-registry slot stays in `pikuri-assistant`).
  Depends on `pikuri-core` + the `mcp` gem.
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
  (`Tools::Search` / `Tools::Read` / `Tools::Reindex` — the gem's
  `tools/` directory is its whole LLM-facing surface) onto an `Agent` via
  `c.add_extension(...)` in the `Agent.new` block — same opt-in
  shape as pikuri-tasks / pikuri-skills. `vectordb_read` is
  parent-document retrieval (read a hit in full by `source`),
  inbound-only so it adds no egress leg. Pieces:
  swappable `Backend` (pure-Ruby `Backend::InMemory` cosine, the
  educational default; thin Faraday `Backend::Qdrant` /
  `Backend::Chroma` for persistence — Qdrant recommended, see
  `pikuri-vectordb/DESIGN.md`) + `Backend::Result`,
  `Server::Qdrant` / `Server::Chroma` (self-managed docker container
  supervisors, route through `Pikuri::Subprocess.spawn`;
  `Server::Qdrant::IMAGE` pins the same tag as `Mem0Server`'s
  Qdrant, in lockstep by convention) + `Server::InMemory` (the null
  supervisor — every engine is a `Backend::X` ↔ `Server::X` pair
  behind one duck-typed Server protocol, so hosts wire all three
  identically), `Indexer` (walks `source`, chunks,
  embeds, upserts), `Watcher` (filesystem-event daemon over the
  `listen` gem that keeps a live index fresh; wired in
  `bin/pikuri-corpus`), `Embedder` (wrapper over `RubyLLM.embed`),
  optional `Reranker::LlamaServer` (cross-encoder over
  `/v1/rerank`) + `Reranker::Hit`, `Chunker::FixedWindow` +
  `Tokenizer` (`CharHeuristic` default / `LlamaServer`) + `Chunk`.
  Text extraction reuses `Pikuri::FileType.read_as_text` from
  pikuri-core (plain text / Markdown out of the box; HTML deferred;
  PDF via pikuri-pdf, which `bin/pikuri-corpus` requires + registers
  checkout-mode — deliberately not a gemspec dep, so the lean
  install stays lean).
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
  Qdrant sidecar supervisor — `Server::Chroma`-shaped, drives
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
  manage it (`Mem0Server`, needs `docker` + `git` + `socat`) or
  bring your own (`Mem0Client.new(endpoint:)`). The supervisor
  builds mem0 **from a pinned source checkout** (no usable published
  image) with a fail-loud build-time patch swapping `DEFAULT_CONFIG`
  from pgvector to Qdrant — pgvector both has a top-k inversion bug
  *and* connects to Postgres eagerly at boot, so Qdrant-by-default
  is what lets the stack run **Postgres-free**. The container
  reaches the (loopback-bound) host router through a **socket
  relay** — host-side `socat` on a unix socket + a pinned
  `alpine/socat` `router-proxy` sidecar — so a `localhost` router
  works identically on rootful and rootless daemons, and the
  host's loopback stays sealed for every other container; the
  socket file is the capability (see `Mem0Server`'s "router relay"
  yardoc). Verified
  end-to-end against a local llama.cpp router (non-reasoning
  `Qwen2.5-7B` extractor + `nomic` embedder): boots Postgres-free,
  add/search rank correctly through the REST API — that run predates
  the socket relay, which still needs one live end-to-end pass. Rides the one new
  pikuri-core primitive, `Extension#on_user_message` (the per-turn
  prefetch + capture hook). No persona (a memory-only persona is
  meaningless without the rest of `@private`'s toolset). Ships
  `bin/pikuri-memory` — the no-egress `@private` demo agent
  (`calculator` + memory only). Depends only
  on `pikuri-core` (mem0 owns embedding + extraction).
- **`pikuri-assistant/`** — `bin/pikuri-assistant` (MCP-aware
  binary) + prompt. No Ruby library code of its own. Depends on
  `pikuri-core` + `pikuri-skills` + `pikuri-mcp` + `pikuri-subagents`
  + `pikuri-extractors` (the binary registers `DOCUMENTS`, whose PDF
  arm supersedes ch3's pikuri-pdf — untrusted documents on an
  egress-capable agent parse in the sandbox) +
  `pikuri-vectordb` + `pikuri-memory` — the last two are
  forward-prep for the ch7 assistant shape: declared but not yet
  wired in the binary (vectordb's correct wiring is gated on
  persona-owned tools, see `ideas/trifecta-detector.md`).
- **`pikuri/`** (metagem) — `lib/pikuri.rb` is twelve `require`s
  in dependency order. Lockstep version pins. No Ruby code.
  Releases last on each release.

The seven `bin/pikuri-*` scripts are dev / demo entry points only —
not advertised as gem executables. Production binaries built on
pikuri (notably the planned `pikuri-tui`) live in downstream gems.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value
  objects, Faraday for HTTP, Rainbow for terminal color. ruby_llm
  is the LLM transport — don't add provider-specific SDKs.
- **Composition over inheritance.** When two classes share
  mechanics, extract a concrete helper they construct with
  explicit keyword parameters — not a base class with template
  methods. The construction site should answer "what does this
  actually run?" without paging through a hierarchy. (Worked
  example: the docker-container lifecycle shared by the vectordb
  server supervisors.)
- **`# frozen_string_literal: true`** at the top of every Ruby
  file (`lib/`, `spec/`, `bin/*`). Add it to any new file.
- **YARD docs on every public module, class, and method.** Use
  concrete types in `@param` and `@return` (`String`, `Integer`,
  `Array<Hash>`, `Faraday::Connection`, `String, nil`) — never
  bare `Object` or `Any`. Document expected exceptions with
  `@raise`. One-line summary first, blank line, then tags.
  Applies to `lib/`; `bin/` and `spec/` don't need it. **Rationale
  belongs there, not in CLAUDE.md** — when adding a non-obvious
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
  best-effort cosmetic paths *secondary to the loop* (e.g. the
  `ContextWindowDetector` `/props` probe hitting a wedged server)
  get rescued narrowly, logged, and degrade — but NOT errors
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
- **No tool names in a main/binary system prompt.** The system
  prompt for a *main* agent (the per-binary `prompts/<bin>.txt`)
  names no specific pikuri tool — so it can never go stale against
  the wiring or reference a tool a given binary doesn't wire. The
  main prompt's scope is broad ("you are a coding agent; use the
  tools you have"), and the *same* prompt should survive being
  wired onto a differently-toolset agent — one binary edits the
  local workspace, another might edit a remote GitHub repo via a
  completely different mechanism. So a tool's existence and
  mechanics live in its `description:` (sub-agents: the persona
  `description`, which `SubAgent::Extension` renders into the
  runtime `<available_agents>` snippet — so the catalog stays in
  lockstep with the wired persona list). The main prompt keeps only
  general engineering norms, stated tool-agnostically: "search for
  its callers before editing" (norm), not "`grep` for its callers"
  (named tool); "a tool may ask for confirmation — if the user
  declines, accept it" (norm), not "the `bash` and `write` tools
  may prompt" (named tools). Advice about *when* to reach for a tool
  belongs in that tool's own description (e.g. "don't delegate what
  you can read yourself" lives on the `agent` tool, not on `read`).
  This subsumes the older "don't repeat tool descriptions in the
  system prompt." The line to draw: *per-tool mechanics* (what it
  returns, its caveats) go in the description and are reused by
  every prompt that wires the tool; *agent-level orchestration*
  (which move is primary for this agent, how to sequence the mix)
  stays in the prompt — phrased as an action, not a tool name
  ("searching the corpus is your primary move", not "`vectordb_search`
  is your primary tool"). The rule covers a gem's own tools too:
  `pikuri-corpus` always wires `vectordb_*`, but the "always wired
  here" argument applies equally to `pikuri-code` always wiring
  `bash`/`read`, so it can't earn a carve-out without voiding the
  rule — and keeping `vectordb_*` mechanics in the descriptions is
  what lets any other agent reuse those tools without re-deriving
  their usage.

  **Persona system prompts are the carve-out.** A persona
  (`prompts/persona-*.txt`) is narrow, single-purpose, and wired
  with the *minimum* toolset for that one job; its `tool_names:` and
  `system_prompt:` are co-located in the same persona file, so a
  tool reference can't silently drift out of sync the way a shared
  main prompt can. Persona prompts may name their tools.

  Grep-enforceable — a backtick-delimited tool name in a non-persona
  prompt is the violation:
  `grep -rnoE '\x60(bash|write|read|grep|glob|edit|agent|calculator|web_search|web_scrape|fetch|task_[a-z]+|vectordb_[a-z]+|recall|skill|mcp_connect)\x60' --include='*.txt' --exclude='persona-*.txt' */prompts/`
  should hit nothing (`\x60` is the backtick the tool name is
  wrapped in). `mcp_connect` is pikuri's own tool, so it's in the
  list; the *server-supplied* MCP tools are named by their server at
  runtime, so no static pattern can list them — a reviewer catches
  those by eye.
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
