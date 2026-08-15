# CLAUDE.md

This file is the pointer-level orientation map: invariants and where
each rationale lives, not the rationale itself. When a line says
"see {ClassName}", that yardoc is the source of truth.

**Size cap.** If this file exceeds 40 KB, stop and garbage-collect ruthlessly — rationale belongs in yardoc / DESIGN.md / the book, never in prose here.

## What this project is

A Ruby AI assistant on top of [ruby_llm](https://rubyllm.com), shipped
as sibling gems in one monorepo. ruby_llm owns the chat transport and
the Thought / Tool-call / Observation loop; pikuri owns the *extension
surface*: the strict `Pikuri::Tool::Parameters` validator, the
Configurator + Extension protocol hosts wire into via the `Agent.new`
block, the listener event stream, the `max_steps` budget, and a
deliberate set of bundled tools.

The gem inventory (per-gem detail lives in each gem's yardoc /
`DESIGN.md` / gemspec, not here):

- `pikuri-core` — `Agent` runtime + `Tool` framework + Extension protocol + listener stream + `Subprocess` chokepoint + `Extractor` registry + four stateless bundled tools (calculator, web search, web scrape, fetch) + `bin/pikuri-chat`.
- `pikuri-extractors` — DOCX/ODT/XLSX/PPTX/EPUB/RTF/PDF → Markdown for the `Extractor` registry, via a one-shot networkless docker container (host pandoc/markitdown/pdftotext fallback).
- `pikuri-pdf` — PDF → text for the registry: in-process pure-Ruby pdf-reader, lazily paged. Pick one PDF arm per host (this or pikuri-extractors').
- `pikuri-skills` — Agent Skills standard implementation.
- `pikuri-tasks` — in-memory per-agent task list + four `task_*` tools.
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams + the file tools (Read/Write/Edit/Grep/Glob/FileList) + `ReadOnly` gate.
- `pikuri-code` — `Bash` + sandbox + `bin/pikuri-code` (in-repo coding agent).
- `pikuri-os` — offline, network-severed OS-helper agent (file-index search/read, `MACHINE.md` memory, boot grounding) + `bin/pikuri-os`; also hosts the `bin/pikuri-computer` demo composition.
- `pikuri-thunderbird` — local Thunderbird mail + calendar: five read-only inbound tools + two opt-in human-gated outbound hand-offs. No network, no autonomous send. See the Thunderbird seam.
- `pikuri-mcp` — Model Context Protocol support + `bin/pikuri-openlibrary` one-MCP demo.
- `pikuri-subagents` — the `agent` tool + `Persona` record + bundled `RESEARCHER` / `FILE_MINER` + `bin/pikuri-minions`.
- `pikuri-vectordb` — local-corpus vector search + agentic RAG (`vectordb_*` tools, swappable `Backend`, embedder/reranker/chunker, `LIBRARIAN` persona) + `bin/pikuri-corpus`.
- `pikuri-memory` — durable cross-conversation memory backed by mem0 (`recall` tool + per-turn prefetch/capture, self-managed sidecar) + `bin/pikuri-memory`.
- `pikuri-assistant` — MCP-aware `bin/pikuri-assistant`; no library code of its own.
- `pikuri` — convenience metagem depending on all siblings; lockstep version pins.

## Why this exists

The existing agent stacks (PI, OpenClaw) grew big and hit a steep
learning curve — a wall of JSON config with no start-here. Pikuri is the
counter-move: **start slowly** (sane defaults, no config for a first
chat), **privacy-first** (local llama.cpp by default; cloud is explicit
opt-in), **educates along the way** (the learner is a skilled Ruby dev
new to LLMs; per-file yardoc explains *why*), **small enough to audit**
(readable end-to-end in an evening; abstraction "just in case" loses to
concrete code). Positioning detail lives in README + the book.

## Reference projects

- **opencode** — <https://github.com/anomalyco/opencode/>. Tool registry shape, skill loading, permission system.
- **PI** — <https://github.com/earendil-works/pi>. Agent Skills standard, `.agents/` cross-harness skill convention.
- **hermes-agent** — <https://github.com/nousresearch/hermes-agent>. Memories as a primary concept.

opencode and PI both implement the [Agent Skills standard](https://agentskills.io/specification), as does Claude Code.

## Documentation kinds

Each kind of doc has a distinct audience and *what it is allowed to
own*. Match the kind before writing.

| Kind | Audience | Owns |
|---|---|---|
| `ideas/*.md` | you + the author | design rationale *in flight* + each topic's *considered-then-deferred* list; transient (trimmed as pieces graduate) |
| `DECISIONS.md` | a contributor asking "why this way?" | the *why-we-chose*, incl. the **roads not taken**; one mutable entry per live decision |
| `COMPARISON.md` | evaluator / contributor | external prior art + "ideas to borrow" |
| per-gem `DESIGN.md` | someone extending that gem | that gem's cross-cutting rationale + closeable threat model (only where earned; `ls pikuri-*/DESIGN.md` for the set) |
| **book** (`book/`) | a learner, reading in order | concepts, teaching narrative, the cross-cutting why |
| **YARD** (source headers) | someone at the API | the per-symbol technical truth **and its rationale** — the source of truth |
| **README** | a prospective user | positioning + quickstart + a couple examples + pointers |
| **SECURITY.md** | a security-conscious user | threat model + shipped defenses |
| **CHANGELOG.md** | an existing user deciding whether/how to upgrade | *what changed* and *what you must do about it*; one sentence per entry, append-only per release |
| **CLAUDE.md** (this) | contributor / coding agent | invariants ("what you must not break") + pointers to the owning yardoc |

Rules:

- **Single source of truth per fact.** One home; others link. Yardoc owns per-symbol truth + rationale; the book owns concepts + teaching order; DECISIONS.md owns the rejected alternative; CLAUDE.md owns invariants and points (`see {ClassName}`). Tempted to explain twice → link instead. A tiny load-bearing restatement is fine when it saves a jump (repeat the *one-line fact*, defer the *explanation*).
- **YARD is browsed standalone** on rubydoc.info, so it carries the complete *local* what + why of the symbol; it may defer only the book-wide *narrative*, never the local truth.
- **README stays a front door.** Concepts migrate to the book; per-symbol API + rationale to yardoc.
- **The book grows organically.** Add a chapter when a concept earns one: one new `book/<slug>.md`, one line in `book/README.md` (the ToC owns the order), and fix the two neighbouring "What's next" links. Chapters are named, not numbered — see Layout.
- **`ideas/*.md` is transient** — a scratchpad where rationale is born. As pieces land in source / book / CLAUDE.md / DECISIONS.md, cut them from the note; a fully-graduated note is *deleted*, not left as a stub. Graduation homes: reader-half → book, per-symbol rationale → yardoc, invariant → CLAUDE.md (a Seam/Convention entry), **the choice made + the alternatives rejected → DECISIONS.md**, work deferred *as a consequence of a logged decision* → that entry's *Consequences*. Only a standalone open topic with no decision yet keeps a note alive. (See the `ideas-folder` skill.)
- **A CHANGELOG entry is one sentence.** Lead with `Add` / `Fix` / `**Breaking:**`, name the symbol, say what changed — ≈40 words, and a trailing `See DECISIONS.md D-xxx` or book pointer doesn't count toward the cap. A **breaking** entry earns one *second* sentence, and only for what the caller must now *do* (the migration). Everything else — the rationale, the roads not taken, the measurements, the worked example, the "there is deliberately no X" — belongs in DECISIONS.md, yardoc or the book, and a changelog that restates them is the single-source rule broken in the file nobody re-reads. Entries are a flat list per release (no `### Added` / `### Changed` sub-headings), grouped `Add`, then `Fix`, then `**Breaking:**`. The one sanctioned narrative is a **≤3-sentence preamble** under a themed release's version heading — once per release, never per entry. A shipped release's section is closed: new work goes under `[Unreleased]`, and a version heading is *never* left unwritten while tags march on (this rule was written 2026-08-12, when `[Unreleased]` had eaten four tagged releases and its entries had reached paragraph length; the whole file was retro-trimmed to it then).
- **`DECISIONS.md` is the home for roads not taken**, and the *only* doc that is never context-loaded — that's why rejection rationale goes there instead of into yardoc (browsed standalone at the API) or here (loaded every session, 40 KB cap). Cite entries by slug (`D-per-process-temp`); `grep '^## D-' DECISIONS.md` is the index, so no ToC. Entries are mutable — a refined decision is edited in place, a *shipped-then-reversed* one gets a tombstone + a fresh entry. **No entry without a real fork** (no rejected alternative → it's just how it works → yardoc). Boundaries: per-gem `DESIGN.md` / `SECURITY.md` keep the system-as-it-is and the shipped defenses, `COMPARISON.md` keeps what *others* do. Grep tripwire: every `D-<slug>` cited in the repo exists as a `^## D-` heading in `DECISIONS.md`.

## Seams (invariants)

Every seam has detailed rationale in the cited yardoc; CLAUDE.md records
only the invariant + any grep check.

- **Loop seam.** ruby_llm owns `Chat#complete`; pikuri loop-wiring lives only in `bin/pikuri-*`, `pikuri-core/lib/pikuri/agent.rb` (callbacks + `run_loop`), and `pikuri-core/lib/pikuri/tool.rb` (the `Pikuri::Tool` → `RubyLLM::Tool` adapter). Don't build a `Chat` or attach callbacks elsewhere. See {Pikuri::Agent}.
- **Connection seam.** A model's connection (base URL + key) rides its `Agent::ChatTransport` → a per-chat `RubyLLM::Context` (`build_context`), never a process-global `RubyLLM.configure`. Lone exception: `bin/pikuri-corpus`'s `RubyLLM.embed`, which runs outside any Agent. See {Pikuri::Agent::ChatTransport}, {Pikuri::Agent#build_context}.
- **Value-type passthrough.** `lib/` may reference `RubyLLM::Content` / `Attachment` / `Message` directly when wrapping would be a transparent passthrough. See {Pikuri::Agent}.
- **Extraction seam.** Every format→text conversion routes through the `Pikuri::Extractor` registry (`.extract` / `.extract_paged`); a new format is a registry entry, not a new dispatcher arm. Grep: `grep -rnE "require '(pdf-reader|readability|reverse_markdown)'" pikuri-*/lib/` hits only `pikuri-core/lib/pikuri/extractor/` + `pikuri-pdf/lib/`. See {Pikuri::Extractor}.
- **Subprocess seam.** All subprocess spawning in `lib/` routes through `Pikuri::Subprocess.spawn`. Grep: `grep -rnE 'Process\.spawn|Open3\.|\bsystem\(' pikuri-*/lib/` hits only `subprocess.rb` (+ the documented `mcp/client_wrapper.rb` stdio-MCP exception). See {Pikuri::Subprocess}, {Pikuri::Mcp::ClientWrapper}.
- **Finalizers / teardown seam.** One process-global teardown registry, single `at_exit`. Resources register at their ownership boundary: process infra a `bin/` starts self-registers; agent-owned resources ride the agent's `on_close`. `Subprocess` registers at load time so it sweeps last. Grep: `grep -rn 'at_exit {' pikuri-*/lib/` hits only `finalizers.rb`. See {Pikuri::Finalizers}, {Pikuri::Agent::Configurator}, {Pikuri::Paths.new_temp}.
- **Capability seam (ExtensionContext).** A live `Agent` reference is read-only; everything that *acts on* a wired agent (`emit_event`, `add_raw_tool`, `sub_agent_listeners`, `on_close`) lives on `Agent::ExtensionContext`, handed only to `Extension#bind` / `#on_user_message` (non-extension consumers get it by explicit handoff). Gems emit domain events via `ctx.emit_event`; listeners must no-op on unknown variants. Grep: `emit_event|add_raw_tool|sub_agent_listeners` is the capability-user roster, and `listeners.emit` outside `agent.rb` / `extension_context.rb` hits nothing. See {Pikuri::Agent::ExtensionContext}.
- **Workspace seam.** The file tools take a `Workspace::Workspace` composite; `Bash` takes the bare `Workspace::Filesystem`. Every path routes through `#resolve_for_read` / `#resolve_for_write`. The composite enforces the **read-before-edit gate** (Read marks; Edit + overwrite-Write refuse an unread path). File tools run in-process as the real user (only Bash is sandboxed), so `File.writable?` is exact — that backs the confirm-writable-writes / short-circuit-unwritable posture; confirmed writes always route through {Pikuri::Workspace::WriteGate}. `Workspace::Extension` also contributes a **depth-1 boot snapshot** of the root as a system-prompt snippet — one level, never a depth knob, and over its 2 KB cap it degrades to a single line rather than head-truncating (a truncated listing teaches the model that `spec/` doesn't exist). See {Pikuri::Workspace::Workspace}, {Pikuri::Workspace::Filesystem}, {Pikuri::Workspace::Extension}.
- **Denylist seam (walked vs. supplied paths).** `resolve_for_read` / `_for_write` gate a path the *model* supplied; a path a tool **walked** to on its own (a `Listing` row, an `rg` hit) reaches no `resolve_` call, so every enumerating tool must consult `Filesystem#denied?` on its results. That check is the guarantee and fails closed; `rg --glob '!…'` pruning via `Filesystem#denied_roots` is an optimization that may go partial and is never load-bearing. Grep: `denied?|denied_roots` is the roster — `Listing`, `Search::Glob`, `Search::Grep`. See {Pikuri::Workspace::Filesystem#denied?}, `DECISIONS.md` `D-walked-path-denylist`.
- **Confirmer seam.** State-mutating (`Write`, `Bash`) or network-dispatching (`agent`) tools take a `Workspace::Confirmer` and route every prompt through `#ask(request:)` → `Approved(detail)` / `Rejected(reason)` (`#confirm?` is the boolean convenience). Presentation — color, edit affordance, hostile-byte neutralization — belongs to the confirmer, never tool code, which never touches `gets` / `puts` / `$stdin` / `$stdout`. Chrome-independent defanging is the shared `Pikuri::Sanitizer`. See {Pikuri::Workspace::Confirmer}, {Pikuri::Sanitizer}.
- **Sandbox seam.** `Code::Bash` takes a `Code::Bash::Sandbox` (default `NONE`), wraps every argv via `#wrap`. Governs the bash subprocess's fs view (vs Workspace = what the LLM observes). `FullFsNoNet` = full-fs read-write + `--unshare-net` (raises rather than degrading) **minus the live session's IPC sockets** — a tmpfs over `$XDG_RUNTIME_DIR` + `/tmp/.X11-unix`, because a reachable session bus spawns commands outside every namespace and hands the severed egress straight back (`D-headless-os-agent`; the mask must stay *after* the root bind). Threat model + posture comparison in `pikuri-code/DESIGN.md`. See {Pikuri::Code::Bash::Sandbox}.
- **Environment is not a secret store.** pikuri never *filters* `ENV` before spawning (no env-scrubbing primitive). Trusted children inherit it wholesale; untrusted ones are cleared *as a unit by the isolation boundary* (Bubblewrap `--clearenv`, docker). Config holds tokens **verbatim**, not `ENV['X']` refs; `Mcp::Registry::StdioEntry#env` is the legitimate per-child credential channel. See {Pikuri::Code::Bash::Sandbox}, {Pikuri::Mcp::Registry::StdioEntry}.
- **Streaming flag.** `Agent.new(..., streaming:)` is opt-in and propagates to the synthesizer + sub-agents so the whole tree is consistent. Default false. See `Agent#initialize`.
- **Interloper injection seam.** Mid-loop host→agent injection routes through `Control::Interloper`; each item carries a `kind` — `:user` (a mid-loop turn: `Event::UserTurn` + `on_user_message` dispatch) or `:system` (reference text — a host-loaded skill, retrieved context — landing as `add_message(:system)` + reused `Event::SystemInjected`, no user-turn semantics). `run_loop` *delivers* pending injections at turn start (before the first `complete`); a blank turn with nothing but `:system` to complete against is provider-split — providers that hoist `:system` out of the messages array (Anthropic, Bedrock) raise `Agent::EmptyTurnError`, the rest run the turn against that history. `clear_conversation` *discards* them. Host-driven skill loading is the enqueue-only, main-agent-only `Skill::Extension#schedule_load_skill` — the host must then run the loop. See {Pikuri::Agent::Control::Interloper}, {Pikuri::Agent#run_loop}.
- **Step-exhaustion policy.** `StepLimit.new(max:, on_exhausted: :raise|:synthesize)`, default `:raise`. Q&A wirings opt into `:synthesize`; coding agents keep `:raise`; sub-agents are always `:synthesize`. The synth is a nested tools-free `Agent`. See {Pikuri::Agent::Control::StepLimit}, {Pikuri::Agent::Synthesizer}.
- **Sub-agent propagation.** Listeners define `for_sub_agent(**)`; controls don't (inlined in `SubAgentTool#execute`). Sub-agents do NOT inherit extensions — each persona owns its toolset + system prompt verbatim. See {Pikuri::SubAgent::SubAgentTool}, {Pikuri::Agent::ListenerList#for_sub_agent}.
- **MCP-tool bypass.** MCP tools synthesize as raw `RubyLLM::Tool` subclasses, not `Pikuri::Tool`s. See {Pikuri::Mcp::Servers}.
- **Thunderbird no-egress / no-send seam.** No network egress, no *autonomous* send: reads the local profile only (never IMAP/SMTP/CalDAV), writes nothing to Thunderbird's stores. The five inbound tools have no egress leg and are the `Extension` default (both `allow_` flags off). The two outbound tools are opt-in (one flag each) and are *human-gated hand-offs to Thunderbird's own UI* (a `mailto:` compose window; an `.ics` import wizard) — never a send/import by pikuri. **No send tool ever ships.** **No attachment ever ships either** — mail or `.ics`: the hand-off may carry only fields that *render literally* (plain-text body, no HTML, no `attach=`, no iCalendar `ATTACH`), because the gate's entire value is that the human sees the exact bytes that leave. A filename approved in place of bytes nobody saw is `curl` wearing a different hat, and degrades the leg to hard egress. Grep: `grep -rn attach pikuri-thunderbird/lib/pikuri/thunderbird/{mailto_uri,ics_event,mail_compose,calendar_create,launcher}.rb` hits nothing. Reads are an allowlist (Gloda + calendar DBs + `profiles.ini`; credential stores never touched). See {Pikuri::Thunderbird::Extension}, `pikuri-thunderbird/DESIGN.md`.

### Out of scope

- Multi-provider config, vision/audio, embeddings — via ruby_llm if/when needed; not part of pikuri today.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup. CI and bug reports follow the same prioritization.

## Layout

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, `<gem>.gemspec`,
entry file, and (where relevant) `bin/` + `prompts/`. Top-level `Gemfile`
wires every gem via `gemspec path: '<gem>'`; top-level `Rakefile` fans
out `rake test` and orchestrates `rake release VERSION=x.y.z` in lockstep.

**"The book"** = the `book/` folder; `book/README.md` is the ToC.
"The book" and "the guide" both mean there. (Renamed from
`docs/guide/` in July 2026.)

**Chapters are named, not numbered** (August 2026). Files are
`security.md` / `code.md`, H1s carry no number, and prose refers to a
chapter by name ("the security chapter") — never by ordinal.
`book/README.md` is the **single source of truth for order**, which is
why inserting a chapter costs one file plus one ToC line instead of
renaming fourteen files and rewriting ~500 references. Named refs also
can't rot: a name survives a reordering that silently falsifies an
ordinal. **The rule covers yardoc, gemspec comments and `bin/` scripts,
not just prose** — a header saying "the guide's ch&lt;N&gt;" rots exactly like a
chapter does, and outlives it, since nobody rereads a comment. Point at
the file (`book/os-assistant.md`), the form `Report::FOOTER` uses.
Grep tripwire — unfiltered, so extensionless `bin/` scripts count — and
keep this file free of the pattern too:
`grep -rniE 'chapters? ?[0-9]+|\bch\.? ?[0-9]+\b' --exclude-dir=.git .`
and `grep -rnoE '[0-9]{2}-[a-z-]+\.md' .` both hit nothing (`ideas/`
included — it is transient, so it may carry the pattern in flight, but
today it does not).

Everything pikuri ships lives under `Pikuri::`, contributed by each gem's
own Zeitwerk loader. `Pikuri::PROMPT_DIRS` is likewise cooperative: each
gem appends its `prompts/` at boot, so `Pikuri.prompt(name)` searches all
loaded gems. Per-file rationale lives in each file's YARD header.

The `bin/pikuri-*` scripts are dev / demo entry points only, not gem
executables. Production binaries (e.g. the planned `pikuri-tui`) live in
downstream gems.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Faraday for HTTP, Rainbow for terminal color. ruby_llm is the LLM transport — no provider-specific SDKs.
- **Composition over inheritance.** Two classes sharing mechanics → extract a concrete helper constructed with explicit kwargs, not a base class with template methods.
- **`# frozen_string_literal: true`** at the top of every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/` (`bin/` and `spec/` exempt). Concrete `@param`/`@return` types (never bare `Object`/`Any`), `@raise` for expected exceptions, one-line summary then tags. **Rationale belongs in the yardoc, not CLAUDE.md** — reference it from here only if it's a cross-cutting invariant.
- **Bundler.** `bin/` scripts self-bootstrap via `require 'bundler/setup'` (no `bundle exec` needed). Add gems with pessimistic `~>` constraints.
- **Diagnostics go through `Pikuri.logger_for('Name')`** (memoized stdlib `Logger`, `progname:`-tagged, writing through `Pikuri.log_io`; level `PIKURI_LOG_<NAME>` → `PIKURI_LOG` → `INFO`). Not `puts`/`warn`/`$stderr.puts`. Listener rendering of the LLM stream stays on stdout via `Terminal` — that's not logging.
- **Cache & temp paths go through `Paths`.** Never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache` in a gem. `Paths.cache` is shared + persistent; `Paths.new_temp` is fresh per-process (reaped at exit) — use it for anything two concurrent processes must not share. Grep: `grep -rn "ENV\['XDG_CACHE_HOME'\]" pikuri-*/lib/` hits only `paths.rb`. See {Pikuri::Paths.new_temp}.
- **Errors are loud.** On unexpected internal state, raise with the offending data. Tools split it: failures the LLM can react to (bad args, HTTP 4xx/5xx, network blips, division by zero) return `"Error: <message>"` Strings and become the next observation; bugs in pikuri's own code keep raising. Narrow carve-out: best-effort cosmetic paths *secondary to the loop* may rescue-and-degrade — but never errors from libraries on the actual chat path.
- **Per-gem Zeitwerk loaders**, rooted at each gem's `lib/`, eager-loading at boot. No `require_relative` chains inside a gem's `lib/`. A new file defines exactly the camelcased constant matching its path; acronyms (`HTML`, `PDF`, `DuckDuckGo`) need an `inflector.inflect` entry. Extensions nesting under `Pikuri::Tool` mount with `push_dir(..., namespace: Pikuri::Tool)`.
- **Namespacing.** Everything lives under `Pikuri::`. One `Pikuri::*` constant per file at the Zeitwerk path (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`). No top-level constants.
- **Tests: rspec-core with minitest-style asserts.** Per-gem `spec/`; `rake test` fans out. `describe`/`it` but `assert_equal`/`assert`/`refute`, not RSpec matchers. rspec-mocks is not in the closure — stub module methods with `define_singleton_method` in `before`, restore in `after`. Pattern: `pikuri-core/spec/pikuri/agent_spec.rb`.
- **Tool descriptions follow opencode-shape:** a `description:` heredoc — one-line summary, blank line, `Usage:` bullets (a `# Sub-heading` where a cluster earns it). Per-arg constraints (defaults, caps, format) go in the *parameter* description, not the tool description. Give every parameter an example value (`e.g. "https://example.com"`) — derive it from live values where computed; the one exception is a bounded numeric whose description already states default/cap. Universal failure-recovery guidance lives in per-binary prompts, not per-tool.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** A `foo_*` prefix means a family sharing one backing resource (`task_*`, `thunderbird_*`, `vectordb_*`, `fileindex_*`, `web_*`, `git_*`); a singleton verb every agent understands stays bare (`read`, `write`, `edit`, `grep`, `glob`, `bash`, `fetch`, `skill`, `recall`, `agent`, `calculator`). `file_list` is prefixed for grammar, not collision — `list` has no implied object the way `read` does. Don't spend an in-distribution name (`read` → `file_read`) for symmetry; see `DECISIONS.md` `D-directory-listing`.
- **No tool names in a main/binary system prompt.** A `prompts/<bin>.txt` names no wired pikuri tool, so it can't drift against the wiring or reference a tool the binary doesn't wire; a tool's existence + mechanics live in its `description:` (sub-agents: the persona `description`). The real rule: **naming the wired tool or restating its mechanics is forbidden; stating a capability the agent observes** (e.g. "the commands you run can't reach the internet") **is fine** — even when the words collide. The main prompt keeps general engineering norms and agent-level orchestration (phrased as an action, not a tool name). **Persona prompts (`prompts/persona-*.txt`) are the carve-out** — `tool_names:` + `system_prompt:` are co-located, so they may name their tools. Grep: `grep -rnoE '\x60(bash|write|read|grep|glob|file_list|edit|agent|calculator|web_search|web_scrape|fetch|task_[a-z]+|vectordb_[a-z]+|recall|skill|mcp_connect)\x60' --include='*.txt' --exclude='persona-*.txt' */prompts/` hits nothing (dual-natured shell-command tips are reviewer-cleared false positives).
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace." Applies to README / SECURITY / COMPARISON / book — any human-facing prose (not yardoc).

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** Changing `agent.rb` = "what hooks fire when?", not reimplementing iteration. Reach for a different listener instead.
- **Readable, not obfuscated.** Simplest implementation that does the job; no abstraction layers / plugin systems / config knobs not needed for the next concrete step.
- **Grow by adding tools, listeners, or controls — not by complicating the loop.** New capabilities land as new `Pikuri::Tool` / `Listener` / `Control` constants with their own specs; core and ruby_llm's loop stay ignorant of them.
- **Grow by adding *bounded gems*, not by fattening one — each addition re-examines the trifecta.** A bounded gem has a *closeable* threat model (freeze the surface, enumerate the legs, write the DESIGN.md); fattening a gem makes every new tool interact with every existing leg. But a bounded concept earns a gem only with a *novel* threat model **or** cohesive lib code needing a home — not merely a nameable posture (worked example: `bin/pikuri-computer` shipped as a demo + the book's OS-assistant chapter, not a gem). Name a gem after what it *refuses to become*.

## CI

Woodpecker CI runs `rake test` on push / PR / manual (`.woodpecker.yml`,
dashboard <https://ci.codeberg.org/repos/17229>). The `ruby:4.0` image
lacks `ripgrep`, so the config installs it (the Grep tool's specs need
`rg`). Gem deps cache in Hetzner Object Storage, keyed on `Gemfile.lock`.
