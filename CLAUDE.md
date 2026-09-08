# CLAUDE.md

An index, not a manual: each entry is the one-line invariant ("what you
must not break") plus pointers to where the truth and its rationale live.
When a line says "see {ClassName}", that yardoc is the source of truth;
the book teaches the concept; `DESIGN.md` / `DECISIONS.md` hold the
nitty-gritty and the roads not taken. Don't explain here what those
already explain.

**Size cap.** If this file exceeds 34 KB, stop and garbage-collect
ruthlessly. It holds what is *generic to the project or lives in
`pikuri-core`*; a gem-specific invariant lives in that gem's own
`CLAUDE.md`, which Claude Code loads beside this one only when work
touches that directory (`ls pikuri-*/CLAUDE.md` for the set).

## What this project is

A Ruby AI assistant on top of [ruby_llm](https://rubyllm.com), shipped as
sibling gems in one monorepo. ruby_llm owns the chat transport and the
Thought / Tool-call / Observation loop; pikuri owns the *extension
surface*: the strict `Pikuri::Tool::Parameters` validator, the
Configurator + Extension protocol hosts wire into via the `Agent.new`
block, the listener event stream, and a deliberate set of bundled tools.

Gem inventory — bare pointers; detail lives in each gem's `CLAUDE.md` /
`DESIGN.md` / yardoc / gemspec:

- `pikuri-core` — `Agent` runtime + `Tool` framework + Extension protocol + listener stream + `Subprocess` chokepoint + `Extractor` registry + four stateless bundled tools + `bin/pikuri-chat`.
- `pikuri-extractors` — office/EPUB/RTF/PDF → Markdown for the `Extractor` registry via a one-shot networkless docker container.
- `pikuri-pdf` — in-process pure-Ruby PDF → text for the registry. Pick one PDF arm per host (this or pikuri-extractors').
- `pikuri-skills` — Agent Skills standard + slash commands + the shared `Bundle::*` vocabulary.
- `pikuri-tasks` — in-memory per-agent task list + four `task_*` tools.
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams + the file tools + `ReadOnly` gate.
- `pikuri-lsp` — LSP client for read-only code navigation: the `lsp` tool + `bin/pikuri-lsp-check`.
- `pikuri-code` — `Bash` + sandbox + `bin/pikuri-code` (in-repo coding agent).
- `pikuri-os` — offline, network-severed OS-helper agent + `bin/pikuri-os`; hosts the `bin/pikuri-computer` demo.
- `pikuri-thunderbird` — local Thunderbird mail + calendar: read-only inbound tools + human-gated outbound hand-offs.
- `pikuri-mcp` — Model Context Protocol support + `bin/pikuri-openlibrary` one-MCP demo.
- `pikuri-subagents` — the `agent` tool + `Persona` record + bundled personas + `bin/pikuri-minions`.
- `pikuri-vectordb` — the retrieval *primitive*: topical vector search over a local corpus + `bin/pikuri-corpus`.
- `pikuri-rag` — the retrieval *system* on that primitive: hybrid vector + FTS5 search + `bin/pikuri-briefing`.
- `pikuri-memory` — durable cross-conversation memory backed by mem0 + `bin/pikuri-memory`.
- `pikuri-assistant` — MCP-aware `bin/pikuri-assistant`; no library code of its own.
- `pikuri` — convenience metagem depending on all siblings; lockstep version pins.

## Why this exists

The counter-move to agent stacks that grew big and steep (PI, OpenClaw):
**start slowly** (no config for a first chat), **privacy-first** (local
llama.cpp by default; cloud is explicit opt-in), **educates along the
way** (the learner is a skilled Ruby dev new to LLMs; yardoc explains
*why*), **small enough to audit** (no abstraction "just in case").
Positioning lives in README + the book.

## Reference projects

opencode, PI, grok-build and hermes-agent are the harnesses pikuri reads
for prior art; what each does and what's worth borrowing lives in
`COMPARISON.md`. opencode, PI and Claude Code all implement the
[Agent Skills standard](https://agentskills.io/specification).

## Documentation kinds

Each kind has a distinct audience and *what it is allowed to own*. Match
the kind before writing.

| Kind | Audience | Owns |
|---|---|---|
| `ideas/*.md` | you + the author | design rationale *in flight* + each topic's *considered-then-deferred* list; transient |
| `DECISIONS.md` | a contributor asking "why this way?" | the *why-we-chose*, incl. the **roads not taken**; one mutable entry per live decision |
| `COMPARISON.md` | evaluator / contributor | external prior art + "ideas to borrow" |
| per-gem `DESIGN.md` | someone extending that gem | that gem's cross-cutting rationale + closeable threat model (only where earned) |
| **book** (`book/`) | a learner, reading in order | concepts, teaching narrative, the cross-cutting why |
| **YARD** (source headers) | someone at the API | the per-symbol technical truth **and its rationale** — the source of truth |
| **README** | a prospective user | positioning + quickstart + a couple examples + pointers |
| **SECURITY.md** | a security-conscious user | threat model + shipped defenses |
| **CHANGELOG.md** | an existing user deciding whether/how to upgrade | *what changed* and *what you must do about it* |
| **CLAUDE.md** (this) | contributor / coding agent | project-wide + `pikuri-core` invariants + pointers to the owning yardoc |
| per-gem `CLAUDE.md` | a coding agent editing that gem (auto-loaded there) | that gem's own invariants, same shape; consumers of a seam point to the owner gem's file |

Rules:

- **Single source of truth per fact.** One home; others link. Tempted to explain twice → link instead; a one-line load-bearing restatement is fine when it saves a jump.
- **YARD is browsed standalone** on rubydoc.info, so it carries the complete *local* what + why; it may defer only the book-wide *narrative*.
- **README stays a front door.** Concepts migrate to the book; per-symbol API + rationale to yardoc.
- **The book grows organically.** A new concept = one `book/<slug>.md`, one line in `book/README.md` (the ToC owns the order), fixed neighbouring "What's next" links. Chapters are named, not numbered (see Layout).
- **`ideas/*.md` is transient.** As pieces land, cut them; a fully-graduated note is deleted. Homes: reader-half → book, per-symbol rationale → yardoc, invariant → a Seam/Convention entry in the root or owning gem's CLAUDE.md, choice + rejected alternatives → DECISIONS.md, deferred consequences → that entry. See the `ideas-folder` skill.
- **A CHANGELOG entry is one sentence.** Lead with `Add` / `Fix` / `**Breaking:**`, name the symbol, say what changed (≈40 words + an optional `See DECISIONS.md D_xxx` / book pointer); a breaking entry gets one second sentence for the migration. Flat list per release, grouped `Add`, `Fix`, `**Breaking:**`; one ≤3-sentence preamble per themed release; a shipped section is closed, new work goes under `[Unreleased]`, and a version heading is never left unwritten while tags march on.
- **`DECISIONS.md` is the home for roads not taken** and the only doc never context-loaded. Cite by slug (`D_per_process_temp`); `grep '^## D_'` is the index. Entries are mutable (refine in place; shipped-then-reversed → tombstone + fresh entry). **No entry without a real fork.** `T_decision_slugs` (exempts `ideas/`, where a slug is named before its entry exists).

## Seams (invariants)

**Placement.** A seam whose every cited symbol lives in one gem goes in
*that gem's* `CLAUDE.md`; this file keeps the seams that live in
`pikuri-core` or span the whole process. A seam consumed across gems
(Workspace / Denylist / Confirmer, owned by `pikuri-workspace`) is stated
once in the owner's file; each consumer's file carries a one-line pointer.
A gem with no seam has no file.

**Tripwires.** A mechanically checkable seam cites a `T_` slug;
`rake tripwires` runs them all (`tasks/tripwires.rake`). A failure is as
often a stale expectation as a real violation — read the lines before
"fixing" the code.

- **Loop seam.** ruby_llm owns `Chat#complete`; pikuri loop-wiring lives only in `bin/pikuri-*`, `pikuri-core/lib/pikuri/agent.rb` and `pikuri-core/lib/pikuri/tool.rb`. Never build a `Chat` or attach callbacks elsewhere. See {Pikuri::Agent}.
- **Connection seam.** A connection rides `Agent::ChatTransport` → a per-chat `RubyLLM::Context`, never a process-global `RubyLLM.configure`; **every** chat rides one (`build_chat` never calls `RubyLLM.chat`). Lone exception: `bin/pikuri-corpus`'s `RubyLLM.embed`. See {Pikuri::Agent::ChatTransport}, {Pikuri::Agent#build_context}.
- **Request-permit seam.** Every request through a connection takes a permit held for exactly one HTTP request — never a turn — from one process-wide registry keyed by **server**, never per agent. That registry is also the `/props` probe's memo: the probe is skipped only when *both* its facts are known (a stated `context_window` **and** a sized server), never on the cap alone. `T_request_permits`. See {Pikuri::Agent::ServerPermits}, `DECISIONS.md` `D_llm_request_throttle` + `D_probe_when_unknown`.
- **Value-type passthrough.** `lib/` may reference `RubyLLM::Content` / `Attachment` / `Message` directly when wrapping would be a transparent passthrough. See {Pikuri::Agent}.
- **Extraction seam.** Every format→text conversion routes through the `Pikuri::Extractor` registry; a new format is a registry entry, not a dispatcher arm. `T_extraction_registry`. See {Pikuri::Extractor}.
- **Subprocess seam.** All subprocess spawning in `lib/` routes through `Pikuri::Subprocess.spawn`. Two documented exceptions, long-lived stdio children owning their teardown — the MCP and LSP children, terms in `pikuri-mcp/CLAUDE.md` / `pikuri-lsp/CLAUDE.md`. `T_subprocess_chokepoint`. See {Pikuri::Subprocess}.
- **Finalizers / teardown seam.** One process-global teardown registry, single `at_exit`; resources register at their ownership boundary (process infra a `bin/` starts self-registers, agent-owned resources ride `on_close`). `T_single_at_exit`. See {Pikuri::Finalizers}, {Pikuri::Agent::Configurator}, {Pikuri::Paths.new_temp}.
- **Capability seam (ExtensionContext).** A live `Agent` reference is read-only; everything that *acts on* a wired agent lives on `Agent::ExtensionContext`, handed only to `Extension#bind` / `#on_user_message`. Listeners no-op on unknown event variants. `T_listener_emit`. See {Pikuri::Agent::ExtensionContext}.
- **Environment is not a secret store.** pikuri never *filters* `ENV` before spawning; config holds tokens **verbatim**, and a per-child `env:` on a config entry is the credential channel. The one systematic rewrite, `Pikuri::BundlerEnv`, *restores* what pikuri's own boot changed — a restoration, not a filter. See {Pikuri::BundlerEnv}, `DECISIONS.md` `D_de_bundlerized_children`.
- **Streaming flag.** `Agent.new(..., streaming:)` is opt-in (default false) and propagates to sub-agents so the tree is consistent. See `Agent#initialize`.
- **Interloper injection seam.** Mid-loop host→agent injection routes through `Control::Interloper` (`:user` / `:system` kinds); `run_loop` delivers at turn start and mid-turn only once a **tool batch is complete** — never from ruby_llm's `after_tool_result`, which fires before the result message exists. `clear_conversation` discards pending injections. See {Pikuri::Agent::Control::Interloper}, {Pikuri::Agent#run_loop}.
- **Reference-text delivery seam.** *Nothing pikuri appends mid-conversation is ever `role: :system`*; every injected block routes through `Agent#append_reference_block` (a `:user` turn wrapped in `<system-reminder>`), because a mid-conversation `:system` fails silently. `T_no_system_role`. See {Pikuri::Agent#append_reference_block}, `DECISIONS.md` `D_reference_text_as_user_turn`.
- **Display-line seam.** The **tool** composes its three display strings (`display_name`, `argument`, `summary`) at `execute` time — never the model — and a summary is structural, never excerpted; a renderer only styles, caps and defangs them. See {Pikuri::Tool}'s `== Display lines`, {Pikuri::Tool::Result}, `DECISIONS.md` `D_tool_summary_lines`.
- **One tool return type.** `Tool#execute` answers a `Tool::Result`, always; the one `RubyLLM::Content` attachment case surfaces only inside `Tool#to_ruby_llm_tool`, never by widening `Result#to_s`. See {Pikuri::Tool::Result}, {Pikuri::Tool#to_ruby_llm_tool}, `DECISIONS.md` `D_tool_always_returns_result`.
- **History seam.** A conversation leaves the agent only as an `Agent::History`; no host reads `@chat.messages`. `:system` is never exported, local-only fields reach no provider, attachments live in the history's own folder, and repair happens on load. `T_history_encapsulated`. See {Pikuri::Agent::History}, {Pikuri::Agent#load_history!}, `DECISIONS.md` `D_history_local_ids` / `D_history_attachments` / `D_history_load_repairs`.
- **A turn never leaves a tool call unanswered.** Anything unwinding out of a tool batch strands calls the next turn would post as a malformed batch; an `ensure` on `run_loop` answers each one before propagating. Repair the damage, don't prevent it. See {Pikuri::Agent#run_loop}, `DECISIONS.md` `D_unwound_batch_repair`.
- **The loop is unbounded — don't re-add a cap.** Nothing limits tool calls per turn, at any depth; the ceilings are `Control::Cancellable` and the context window. If a loop ever appears, reach for a repetition detector, not a cap. See `DECISIONS.md` `D_no_step_limit`, {Pikuri::Agent}'s `== The loop is unbounded`.
- **Sub-agent propagation protocol.** Listeners define `for_sub_agent(**)`; a tool may define a no-arg `for_sub_agent` and is rebuilt through it when a child must hold a narrower view. What a child inherits and never gets is the policy in `pikuri-subagents/CLAUDE.md`. See {Pikuri::Agent::ListenerList#for_sub_agent}.

### Out of scope

- Multi-provider config, vision/audio, embeddings — via ruby_llm if/when needed.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup.

## Layout

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, gemspec, entry
file, and (where relevant) `bin/` + `prompts/`. The top-level `Gemfile`
wires every gem via `gemspec path:`; the top-level `Rakefile` fans out
`rake test` and orchestrates `rake release VERSION=x.y.z` in lockstep.

- **`assets/`** holds **Kuri**, the pika mascot (`kuri.svg` master, `kuri.png` raster); drawing + anatomy rule in `DECISIONS.md` `D_kuri_mascot`.
- **"The book"** (also "the guide") = `book/`; `book/README.md` is the ToC and the single source of truth for chapter order.
- **Chapters are named, not numbered.** Files are `security.md` / `code.md`, H1s carry no number, prose says "the security chapter" and yardoc / gemspecs / `bin/` point at the file (`book/os-assistant.md`) — never an ordinal, which a reordering silently falsifies. `T_named_chapters`.
- **Everything ships under `Pikuri::`**, contributed by each gem's own Zeitwerk loader; `Pikuri::PROMPT_DIRS` is likewise cooperative (each gem appends its `prompts/`, `Pikuri.prompt(name)` searches all).
- **`bin/pikuri-*` are dev / demo entry points**, not gem executables; production binaries live downstream.
- **A `bin/` script is simple on purpose, so its simplifications are not pikuri policy** (`exit 1` on overflow, synchronous stdin, no interloper). Don't cite one as evidence of how pikuri *behaves* or build a library feature on a demo's shortcut — ask whether a real host would have the problem. Library behaviour is `lib/` and its yardoc.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` value objects, Faraday for HTTP, Rainbow for color; ruby_llm is the only LLM transport.
- **Composition over inheritance.** Shared mechanics → a concrete helper with explicit kwargs, not a base class with template methods.
- **`# frozen_string_literal: true`** atop every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/`: concrete `@param` / `@return` types, `@raise` for expected exceptions, one-line summary then tags. Rationale belongs in the yardoc, not here.
- **Bundler.** `bin/` scripts self-bootstrap via `require 'bundler/setup'`; pessimistic `~>` constraints.
- **Every tool declares a sharing posture.** `Agent` is thread-unsafe (the caller serializes; never key state off `Thread.current`), so a tool reachable from two agents carries a `Sharing:` yardoc line naming `P_stateless` / `P_shared_locked` / `P_shared_benign` / `P_one_agent` plus the state's owner. A waiting tool opts into `wants_context: true` and sleeps via `context.cancellable.sleep`, never `Kernel#sleep`. `T_tool_sharing_posture`. See {Pikuri::Tool}, {Pikuri::Agent}, `DECISIONS.md` `D_tool_sharing_postures` + `D_rate_limiter_scope`.
- **Diagnostics go through `Pikuri.logger_for('Name')`**, never `puts` / `warn` / `$stderr`. Listener rendering of the LLM stream on stdout via `Terminal` is not logging.
- **Cache & temp paths go through `Paths`** (`Paths.cache` shared + persistent; `Paths.new_temp` per-process, reaped at exit); never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache`. `T_paths_xdg`. See {Pikuri::Paths.new_temp}.
- **Errors are loud.** Unexpected internal state raises with the offending data. Failures the LLM can react to (bad args, HTTP errors, network blips) answer `Tool::Result.error(message)`; bugs in pikuri keep raising. Only cosmetic paths secondary to the loop may rescue-and-degrade, never library errors on the chat path.
- **Per-gem Zeitwerk loaders**, eager-loading at boot; no `require_relative` inside a gem's `lib/`. One `Pikuri::*` constant per file at the Zeitwerk path (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`); acronyms need an `inflector.inflect` entry; no top-level constants.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it` but `assert_equal` / `assert` / `refute`, no RSpec matchers, no rspec-mocks (stub with `define_singleton_method` in `before`, restore in `after`). Pattern: `pikuri-core/spec/pikuri/agent_spec.rb`.
- **Tool descriptions follow opencode-shape:** one-line summary, blank line, `Usage:` bullets. Per-arg constraints go in the *parameter* description, each with an example value (`e.g. "https://example.com"`). Universal failure-recovery guidance lives in per-binary prompts, not per-tool.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** `foo_*` = a family sharing one backing resource (`task_*`, `thunderbird_*`, `web_*`); a verb every agent knows stays bare (`read`, `bash`, `fetch`, `agent`). Don't spend an in-distribution name for symmetry. See `DECISIONS.md` `D_directory_listing`.
- **No tool names in a main/binary system prompt.** `prompts/<bin>.txt` names no wired tool and restates no mechanics (those live in the tool's `description:`); stating a capability the agent observes is fine. Persona prompts (`prompts/persona-*.txt`) are the carve-out. `T_no_tool_names_in_prompts`.
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace" — README / SECURITY / COMPARISON / book, not yardoc.

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** Changing `agent.rb` = "what hooks fire when?", not reimplementing iteration.
- **Readable, not obfuscated.** Simplest implementation that does the job; no layers, plugin systems or knobs not needed for the next concrete step.
- **Grow by adding tools, listeners, or controls** — new `Pikuri::Tool` / `Listener` / `Control` constants with their own specs; core and the loop stay ignorant of them.
- **Grow by adding *bounded gems*, not by fattening one.** A bounded gem has a closeable threat model (`DESIGN.md`); it earns a gem only with a *novel* threat model or cohesive lib code needing a home — a nameable posture alone ships as a demo (`bin/pikuri-computer` + the book's OS-assistant chapter). Name a gem after what it *refuses to become*.

## CI

Woodpecker runs `rake check` (= `test` then `tripwires`, also the
`default` task) on push / PR / manual — `.woodpecker.yml`, dashboard
<https://ci.codeberg.org/repos/17229>. It installs `ripgrep` (the Grep
specs need `rg`) and runs unprivileged, since root would bypass the
permission bits the workspace specs assert.
