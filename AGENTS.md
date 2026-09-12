# pikuri — AGENTS.md

An index, not a manual: each entry is the one-line invariant ("what you
must not break") plus pointers to where the truth and its rationale live —
a yardoc header (`See {Class}`), a decision (`See D_<slug>`), a
requirement (`See R_<slug>`). Never the explanation itself.
**Size cap: 34 KB.** Over it, garbage-collect by *moving*, never
summarising: a rationale to its `D_`, a per-symbol rule to its yardoc, a
cross-symbol flow to `design/architecture.md`, a gem's own invariants and
class map to that gem's `AGENTS.md` (`ls pikuri-*/AGENTS.md` for the set;
≤ 10 KB each, loaded only when work touches that directory). `CLAUDE.md`
is exactly `@AGENTS.md`, here and beside every nested `AGENTS.md`.

## What this is

A Ruby AI assistant on top of [ruby_llm](https://rubyllm.com), shipped as
sibling gems in one monorepo. ruby_llm owns the chat transport and the
Thought / Tool-call / Observation loop; pikuri owns the *extension
surface*: the strict `Pikuri::Tool::Parameters` validator, the
Configurator + Extension protocol hosts wire into via the `Agent.new`
block, the listener event stream, and a deliberate set of bundled tools.
Why it exists at all — start slowly, privacy-first, educate along the way,
small enough to audit — is the README's and the book's.

## Design docs

Rationale and reference live under `design/`; this file holds only what
its header says it may. Each file has one audience and *what it is allowed
to own*; every file's preamble states its entry shape and how to cite it.
This section is the whole contract — nothing outside the repo is needed to
follow it.

| File | Owns | Loaded? |
|---|---|---|
| `README.md` | a prospective user: positioning, quickstart, a couple of examples, routing onward | — |
| `AGENTS.md` (this) | what you must not break from a distance; the repo map; this table — its rules are in its header | **every turn** |
| `design/requirements.md` | what must hold — `R_` entries, stated not argued | lazy |
| `design/architecture.md` | **the map** of the code as it is — cross-gem wiring and flows; **the code is the truth** | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, roads not taken | lazy |
| `design/comparison.md` | what opencode, PI, grok-build, hermes-agent and langchainrb do, and what's worth borrowing | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| `<gem>/design/architecture.md` | that gem's own cross-symbol picture + its closeable threat model (only where earned) | lazy |
| yardoc (source headers) | per-symbol truth **and its rationale** | source of truth |
| `book/` | a learner reading in order: concepts, teaching narrative, the cross-cutting why | — |
| `SECURITY.md` | threat model + shipped defenses | — |
| `CHANGELOG.md` | what changed and what you must do about it | — |

Rules that keep the split from drifting:

- **One home per fact; the others link.** A one-line restatement that saves a jump is fine — repeat the *fact*, defer the *explanation*. Compressing a `D_` entry into a bullet here is a third copy, not a summary.
- **`decisions.md` argues, `requirements.md` states, `comparison.md` is about *them* not us, `architecture.md` composes and never argues.** A paragraph explaining *why* in any file but `decisions.md` has drifted; move it and cite the `D_`.
- **No `D_` entry without a real fork; only decisions already taken.** Ideas, TODOs and open questions go to `design/ideas/`. A shipped decision that is reversed keeps its entry as a tombstone.
- **Slugs:** `D_` decisions, `R_` requirements, `T_` tripwires (cited from the requirement's *Enforced by*, defined by the check), `Q_` open questions inside `design/ideas/` only — a durable doc never cites a `Q_`. Underscores throughout, backticked in prose, cited by slug never by position; `grep '^## D_' design/decisions.md` is the index.
- **`design/verify_design_tripwires.sh`** (also `rake design_tripwires`) fails on any cited `D_` / `R_` without a heading, a `T_` without a check, an oversized `AGENTS.md`, or a `CLAUDE.md` that isn't the shim. Run it before committing a doc change.

### Ideas & their graduation

An idea graduates the moment it is acted on, and graduation is not done
until its file (and any sidecar folder `design/ideas/<name>/`) is gone.
Where the lasting nuggets land:

- the choice made + the alternatives rejected → a `D_` entry in `design/decisions.md`
- something that must hold from now on → an `R_` entry in `design/requirements.md`
- a new gem, or a changed responsibility → one line in the repo map (this file, or the gem's own `AGENTS.md`)
- how the pieces work together — wiring, a flow crossing several of them → `design/architecture.md`, or that gem's
- what other projects do → `design/comparison.md`
- how one class works and why it is shaped so → its yardoc header
- the concept, taught in order → one `book/<slug>.md` + one line in `book/README.md`
- what a user or operator must know → `README.md` / `SECURITY.md`
- a cross-cutting invariant ("never …") → this file
- work deferred *as a consequence of a logged decision* → that entry's *Consequences*

*Layout seeded from the `design-docs` and `ideas-folder` skills (mvysny, `~/.claude/skills`); this project needs nothing from them.*

## Invariants (seams)

**Placement.** This file keeps the seams living in `pikuri-core` or
spanning the process; a seam whose every cited symbol is in one gem goes
in that gem's file. A seam *consumed* across gems (Workspace / Denylist /
Confirmer, owned by `pikuri-workspace`) is stated once in the owner's
file, and each consumer's carries a one-line pointer — never a restatement.

- **Loop seam.** ruby_llm owns `Chat#complete`; pikuri loop-wiring lives only in `bin/pikuri-*`, `pikuri-core/lib/pikuri/agent.rb` and `pikuri-core/lib/pikuri/tool.rb`. Never build a `Chat` or attach callbacks elsewhere. See {Pikuri::Agent}.
- **Connection seam.** A connection rides `Agent::ChatTransport` → a per-chat `RubyLLM::Context`, never a process-global `RubyLLM.configure`; **every** chat rides one (`build_chat` never calls `RubyLLM.chat`). Lone exception: `bin/pikuri-corpus`'s `RubyLLM.embed`. See {Pikuri::Agent::ChatTransport}, {Pikuri::Agent#build_context}.
- **An extra request parameter is opaque, and rides the transport.** `ChatTransport#params` is deep-merged into the completion payload verbatim; pikuri never translates a parameter, names one, or grows a typed flag for one (a `thinking:` boolean's wire spelling differs per provider *and* per chat template). Sugar belongs in a host's config parser. See {Pikuri::Agent::ChatTransport}'s `== Extra request parameters`, `D_opaque_request_params`.
- **Request-permit seam.** Every request through a connection takes a permit held for exactly one HTTP request — never a turn — from one process-wide registry keyed by **server**, never per agent. That registry is also the `/props` probe's memo: the probe is skipped only when *both* its facts are known (a stated `context_window` **and** a sized server), never on the cap alone. `T_request_permits`. See {Pikuri::Agent::ServerPermits}, `D_llm_request_throttle` + `D_probe_when_unknown`.
- **Value-type passthrough.** `lib/` may reference `RubyLLM::Content` / `Attachment` / `Message` directly when wrapping would be a transparent passthrough. See {Pikuri::Agent}.
- **Extraction seam.** Every format→text conversion routes through the `Pikuri::Extractor` registry; a new format is a registry entry, not a dispatcher arm. `T_extraction_registry`. See {Pikuri::Extractor}.
- **Subprocess seam.** All subprocess spawning in `lib/` routes through `Pikuri::Subprocess.spawn`. Two documented exceptions, long-lived stdio children owning their teardown — the MCP and LSP children, terms in `pikuri-mcp/AGENTS.md` / `pikuri-lsp/AGENTS.md`. See `R_subprocess_chokepoint`, {Pikuri::Subprocess}.
- **Finalizers / teardown seam.** One process-global teardown registry, single `at_exit`; resources register at their ownership boundary (process infra a `bin/` starts self-registers, agent-owned resources ride `on_close`). `T_single_at_exit`. See {Pikuri::Finalizers}, {Pikuri::Agent::Configurator}, {Pikuri::Paths.new_temp}.
- **Capability seam (ExtensionContext).** A live `Agent` reference is read-only; everything that *acts on* a wired agent lives on `Agent::ExtensionContext`, handed only to `Extension#bind` / `#on_user_message`. Listeners no-op on unknown event variants. `T_listener_emit`. See {Pikuri::Agent::ExtensionContext}.
- **Environment is not a secret store.** pikuri never *filters* `ENV` before spawning; config holds tokens **verbatim**, and a per-child `env:` on a config entry is the credential channel. The one systematic rewrite, `Pikuri::BundlerEnv`, *restores* what pikuri's own boot changed — a restoration, not a filter. See {Pikuri::BundlerEnv}, `D_de_bundlerized_children`.
- **Streaming flag.** `Agent.new(..., streaming:)` is opt-in (default false) and propagates to sub-agents so the tree is consistent. See `Agent#initialize`.
- **Interloper injection seam.** Mid-loop host→agent injection routes through `Control::Interloper` (`:user` / `:system` kinds); `run_loop` delivers at turn start and mid-turn only once a **tool batch is complete** — never from ruby_llm's `after_tool_result`, which fires before the result message exists. `clear_conversation` discards pending injections. See {Pikuri::Agent::Control::Interloper}, {Pikuri::Agent#run_loop}.
- **Reference-text delivery seam.** *Nothing pikuri appends mid-conversation is ever `role: :system`*; every injected block routes through `Agent#append_reference_block` (a `:user` turn wrapped in `<system-reminder>`), because a mid-conversation `:system` fails silently. See `R_no_system_role`, {Pikuri::Agent#append_reference_block}.
- **Display-line seam.** The **tool** composes its three display strings (`display_name`, `argument`, `summary`) at `execute` time — never the model — and a summary is structural, never excerpted; a renderer only styles, caps and defangs them. See {Pikuri::Tool}'s `== Display lines`, {Pikuri::Tool::Result}, `D_tool_summary_lines`.
- **One tool return type.** `Tool#execute` answers a `Tool::Result`, always; the one `RubyLLM::Content` attachment case surfaces only inside `Tool#to_ruby_llm_tool`, never by widening `Result#to_s`. See {Pikuri::Tool::Result}, {Pikuri::Tool#to_ruby_llm_tool}, `D_tool_always_returns_result`.
- **History seam.** A conversation leaves the agent only as an `Agent::History`; no host reads `@chat.messages`. `:system` is never exported, local-only fields reach no provider, attachments live in the history's own folder, and repair happens on load. `T_history_encapsulated`. See {Pikuri::Agent::History}, {Pikuri::Agent#load_history!}, `D_history_local_ids` / `D_history_attachments` / `D_history_load_repairs`.
- **A turn never leaves a tool call unanswered.** Anything unwinding out of a tool batch strands calls the next turn would post as a malformed batch; an `ensure` on `run_loop` answers each one before propagating. Repair the damage, don't prevent it. See {Pikuri::Agent#run_loop}, `D_unwound_batch_repair`.
- **The loop is unbounded — don't re-add a cap.** Nothing limits tool calls per turn, at any depth; the ceilings are `Control::Cancellable` and the context window. If a loop ever appears, reach for a repetition detector, not a cap. See `D_no_step_limit`, {Pikuri::Agent}'s `== The loop is unbounded`.
- **Sub-agent propagation protocol.** Listeners define `for_sub_agent(**)`; a tool may define a no-arg `for_sub_agent` and is rebuilt through it when a child must hold a narrower view. What a child inherits and never gets is the policy in `pikuri-subagents/AGENTS.md`. See {Pikuri::Agent::ListenerList#for_sub_agent}.

### Out of scope

- No provider abstraction of our own: multi-provider config, vision/audio and embeddings are ruby_llm's (`bin/pikuri-corpus` already uses its `embed`).
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup.

## Repo map

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, gemspec, entry
file, and (where relevant) `bin/`, `prompts/` and `design/`. The top-level
`Gemfile` wires every gem via `gemspec path:`; the top-level `Rakefile`
fans out `rake test` and orchestrates `rake release VERSION=x.y.z` in
lockstep. Detail lives in each gem's `AGENTS.md` / `design/` / yardoc /
gemspec.

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
- `book/` — "the book", also "the guide"; `book/README.md` is the ToC and the single source of truth for chapter order.
- `assets/` — **Kuri**, the pika mascot (`kuri.svg` master, `kuri.png` raster); drawing + anatomy rule in `D_kuri_mascot`.
- `bin/pikuri-*` — dev / demo entry points, not gem executables; production binaries live downstream.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` value objects, Faraday for HTTP, Rainbow for color; ruby_llm is the only LLM transport.
- **`# frozen_string_literal: true`** atop every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/`: concrete `@param` / `@return` types, `@raise` for expected exceptions, one-line summary then tags, and the local *why*.
- **Bundler.** `bin/` scripts self-bootstrap via `require 'bundler/setup'`; pessimistic `~>` constraints.
- **Every tool declares a sharing posture.** `Agent` is thread-unsafe (the caller serializes; never key state off `Thread.current`), so a tool reachable from two agents carries a `Sharing:` yardoc line naming `P_stateless` / `P_shared_locked` / `P_shared_benign` / `P_one_agent` plus the state's owner. A waiting tool opts into `wants_context: true` and sleeps via `context.cancellable.sleep`, never `Kernel#sleep`. `T_tool_sharing_posture`. See {Pikuri::Tool}, {Pikuri::Agent}, `D_tool_sharing_postures` + `D_rate_limiter_scope`.
- **Diagnostics go through `Pikuri.logger_for('Name')`**, never `puts` / `warn` / `$stderr`. Listener rendering of the LLM stream on stdout via `Terminal` is not logging.
- **Cache & temp paths go through `Paths`** (`Paths.cache` shared + persistent; `Paths.new_temp` per-process, reaped at exit); never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache`. `T_paths_xdg`. See {Pikuri::Paths.new_temp}.
- **Errors are loud.** Unexpected internal state raises with the offending data. Failures the LLM can react to (bad args, HTTP errors, network blips) answer `Tool::Result.error(message)`; bugs in pikuri keep raising. Only cosmetic paths secondary to the loop may rescue-and-degrade, never library errors on the chat path.
- **Per-gem Zeitwerk loaders**, eager-loading at boot; no `require_relative` inside a gem's `lib/`. Everything ships under `Pikuri::`, one constant per file at the Zeitwerk path (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`); acronyms need an `inflector.inflect` entry; no top-level constants. `Pikuri::PROMPT_DIRS` is likewise cooperative — each gem appends its `prompts/`, `Pikuri.prompt(name)` searches all.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it` but `assert_equal` / `assert` / `refute`, no RSpec matchers, no rspec-mocks (stub with `define_singleton_method` in `before`, restore in `after`). Pattern: `pikuri-core/spec/pikuri/agent_spec.rb`.
- **Tool descriptions follow opencode-shape:** one-line summary, blank line, `Usage:` bullets. Per-arg constraints go in the *parameter* description, each with an example value (`e.g. "https://example.com"`). Universal failure-recovery guidance lives in per-binary prompts, not per-tool.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** `foo_*` = a family sharing one backing resource (`task_*`, `thunderbird_*`, `web_*`); a verb every agent knows stays bare (`read`, `bash`, `fetch`, `agent`). Don't spend an in-distribution name for symmetry. See `D_directory_listing`.
- **No tool names in a main/binary system prompt.** `prompts/<bin>.txt` names no wired tool and restates no mechanics (those live in the tool's `description:`); stating a capability the agent observes is fine. Persona prompts (`prompts/persona-*.txt`) are the carve-out. `T_no_tool_names_in_prompts`.
- **Book chapters are named, not numbered** — never an ordinal, anywhere: files, H1s, prose, yardoc, gemspecs, `bin/`. A new concept is one `book/<slug>.md`, one line in `book/README.md`, and fixed neighbouring "What's next" links. `T_named_chapters`.
- **A CHANGELOG entry is one sentence**, new work under `[Unreleased]`, a shipped section closed. The full shape is `CHANGELOG.md`'s own preamble.
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace" — README / SECURITY / `design/comparison.md` / book, not yardoc.

## Commands

- `bundle exec rake check` (also the default task) — specs across every gem, then `tripwires`, then `design_tripwires`. Verbatim what CI runs on push / PR / manual; `.woodpecker.yml` carries its own setup notes, dashboard <https://ci.codeberg.org/repos/17229>.
- `bundle exec rake tripwires` — the executable form of the seams above (`tasks/tripwires.rake`), each cited by its `T_` slug. A failure is as often a stale expectation as a real violation — read the lines before "fixing" the code.
- `bundle exec rake design_tripwires` — the doc layer (`design/verify_design_tripwires.sh`); same rule about stale expectations.
- `bundle exec rspec pikuri-core/spec/pikuri/agent_spec.rb:42` — one test.
- `bundle exec rake release VERSION=x.y.z` — every gem in lockstep, one OTP window (`D_release_one_otp`).

## Skills this project follows

- **Composition over inheritance:** self-sufficient components that reach their data directly, no MVC layers; inherit to *be* a thing, never to share code. The `cop` skill has the rules.
- **Yardoc is browsed standalone on rubydoc.info**, so each header carries the complete local what *and* why, deferring only the book-wide narrative. The `writing-rdoc` skill has the rules.

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** Changing `agent.rb` = "what hooks fire when?", not reimplementing iteration.
- **Readable, not obfuscated.** Simplest implementation that does the job; no layers, plugin systems or knobs not needed for the next concrete step.
- **Local by default; cloud is an explicit opt-in.** A default that reaches a hosted provider, or a feature that only works against one, breaks the privacy posture the whole project is positioned on. See README.
- **Grow by adding tools, listeners, or controls** — new `Pikuri::Tool` / `Listener` / `Control` constants with their own specs; core and the loop stay ignorant of them.
- **Grow by adding *bounded gems*, not by fattening one.** A bounded gem has a closeable threat model (its `design/architecture.md`); it earns a gem only with a *novel* threat model or cohesive lib code needing a home — a nameable posture alone ships as a demo (`bin/pikuri-computer` + the book's OS-assistant chapter). Name a gem after what it *refuses to become*.
- **A `bin/` script is simple on purpose, so its simplifications are not pikuri policy** (`exit 1` on overflow, synchronous stdin, no interloper). Don't cite one as evidence of how pikuri *behaves* or build a library feature on a demo's shortcut — ask whether a real host would have the problem. Library behaviour is `lib/` and its yardoc.
