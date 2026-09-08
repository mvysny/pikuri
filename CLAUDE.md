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
block, the listener event stream, and a deliberate set of bundled
tools.

The gem inventory (per-gem detail lives in each gem's yardoc /
`DESIGN.md` / gemspec, not here):

- `pikuri-core` — `Agent` runtime + `Tool` framework + Extension protocol + listener stream + `Subprocess` chokepoint + `Extractor` registry + four stateless bundled tools (calculator, web search, web scrape, fetch) + `bin/pikuri-chat`.
- `pikuri-extractors` — DOCX/ODT/XLSX/PPTX/EPUB/RTF/PDF → Markdown for the `Extractor` registry, via a one-shot networkless docker container (host pandoc/markitdown/pdftotext fallback).
- `pikuri-pdf` — PDF → text for the registry: in-process pure-Ruby pdf-reader, lazily paged. Pick one PDF arm per host (this or pikuri-extractors').
- `pikuri-skills` — Agent Skills standard + slash commands + the shared `Bundle::Base` / `Bundle::Frontmatter` vocabulary.
- `pikuri-tasks` — in-memory per-agent task list + four `task_*` tools.
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams + the file tools (Read/Write/Edit/Grep/Glob/FileList) + `ReadOnly` gate.
- `pikuri-lsp` — LSP client for read-only code navigation: the `lsp` tool (ten operations, anchored on a `symbol` and never a column) over `Connection` / `ClientWrapper` / `Servers` / `Readiness`, configured through `Registry.from_h`, plus `Lsp::Testing` and `bin/pikuri-lsp-check` (a dev diagnostic that re-measures the design's findings against a real server; `--drive` runs the tool itself). See the LSP seam; threat model + measurements in `pikuri-lsp/DESIGN.md`, forks in `DECISIONS.md`'s `D_lsp_*` entries, walk-through in `book/lsp.md`.
- `pikuri-code` — `Bash` + sandbox + `bin/pikuri-code` (in-repo coding agent).
- `pikuri-os` — offline, network-severed OS-helper agent (file-index search/read, `MACHINE.md` memory, boot grounding) + `bin/pikuri-os`; also hosts the `bin/pikuri-computer` demo.
- `pikuri-thunderbird` — local Thunderbird mail + calendar: five read-only inbound tools + two opt-in human-gated outbound hand-offs. See the Thunderbird seam.
- `pikuri-mcp` — Model Context Protocol support + `bin/pikuri-openlibrary` one-MCP demo.
- `pikuri-subagents` — the `agent` tool + `Persona` record + bundled `RESEARCHER` / `FILE_MINER` + `bin/pikuri-minions`.
- `pikuri-vectordb` — the retrieval *primitive*: topical vector search over a local corpus (`vectordb_*` tools, swappable `Backend`, `LIBRARIAN` persona) + `bin/pikuri-corpus`.
- `pikuri-rag` — the retrieval *system* on that primitive: hybrid search (`rag_search` fuses a vector and an FTS5 keyword leg by reciprocal rank; `rag_find` lists every matching document with no cutoff) over a keyword store composed beside the vector one, plus `bin/pikuri-briefing`. Exclusive with `VectorDb::Extension` on one agent. See the RAG seam; forks in `DECISIONS.md` `D_rag_gem`, walk-through in `book/rag.md`.
- `pikuri-memory` — durable cross-conversation memory backed by mem0 (`recall` tool + per-turn prefetch/capture) + `bin/pikuri-memory`.
- `pikuri-assistant` — MCP-aware `bin/pikuri-assistant`; no library code of its own.
- `pikuri` — convenience metagem depending on all siblings; lockstep version pins.

## Why this exists

The existing agent stacks (PI, OpenClaw) grew big and hit a steep
learning curve — a wall of JSON config with no start-here. Pikuri is the
counter-move: **start slowly** (sane defaults, no config for a first
chat), **privacy-first** (local llama.cpp by default; cloud is explicit
opt-in), **educates along the way** (the learner is a skilled Ruby dev
new to LLMs; per-file yardoc explains *why*), **small enough to audit**
(abstraction "just in case" loses to concrete code). Positioning detail
lives in README + the book.

## Reference projects

opencode, PI, grok-build and hermes-agent are the harnesses pikuri reads
for prior art — what each does and what's worth borrowing lives in
`COMPARISON.md`. opencode and PI both implement the
[Agent Skills standard](https://agentskills.io/specification), as does
Claude Code.

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
- **`ideas/*.md` is transient** — a scratchpad where rationale is born. As pieces land, cut them from the note; a fully-graduated note is *deleted*, not left as a stub. Graduation homes: reader-half → book, per-symbol rationale → yardoc, invariant → CLAUDE.md (a Seam/Convention entry), **the choice made + the alternatives rejected → DECISIONS.md**, work deferred *as a consequence of a logged decision* → that entry's *Consequences*. Only a standalone open topic with no decision yet keeps a note alive. (See the `ideas-folder` skill.)
- **A CHANGELOG entry is one sentence.** Lead with `Add` / `Fix` / `**Breaking:**`, name the symbol, say what changed — ≈40 words, excluding a trailing `See DECISIONS.md D_xxx` or book pointer. A **breaking** entry earns one *second* sentence, and only for what the caller must now *do* (the migration). Everything else — rationale, roads not taken, measurements, the worked example, the "there is deliberately no X" — belongs in DECISIONS.md, yardoc or the book. Entries are a flat list per release (no `### Added` / `### Changed` sub-headings), grouped `Add`, then `Fix`, then `**Breaking:**`. The one sanctioned narrative is a **≤3-sentence preamble** under a themed release's version heading — once per release, never per entry. A shipped release's section is closed: new work goes under `[Unreleased]`, and a version heading is *never* left unwritten while tags march on.
- **`DECISIONS.md` is the home for roads not taken**, and the *only* doc that is never context-loaded — that's why rejection rationale goes there instead of into yardoc (browsed standalone at the API) or here (loaded every session, 40 KB cap). Cite entries by slug (`D_per_process_temp`); `grep '^## D_' DECISIONS.md` is the index, so no ToC. Entries are mutable — a refined decision is edited in place, a *shipped-then-reversed* one gets a tombstone + a fresh entry. **No entry without a real fork** (no rejected alternative → it's just how it works → yardoc). `T_decision_slugs`.

## Seams (invariants)

Every seam has detailed rationale in the cited yardoc; CLAUDE.md records
only the invariant.

**Tripwires.** A seam that can be mechanically checked cites a `T_` slug;
`rake tripwires` runs all of them and prints the offending lines. The
commands live in `tasks/tripwires.rake`, not here — they were prose once,
and two had silently rotted by the time they were first executed. A
failure is as often a stale expectation as a real violation, so read the
lines before "fixing" the code.

- **Loop seam.** ruby_llm owns `Chat#complete`; pikuri loop-wiring lives only in `bin/pikuri-*`, `pikuri-core/lib/pikuri/agent.rb` (callbacks + `run_loop`), and `pikuri-core/lib/pikuri/tool.rb` (the `Pikuri::Tool` → `RubyLLM::Tool` adapter). Don't build a `Chat` or attach callbacks elsewhere. See {Pikuri::Agent}.
- **Connection seam.** A model's connection (base URL + key) rides its `Agent::ChatTransport` → a per-chat `RubyLLM::Context` (`build_context`), never a process-global `RubyLLM.configure`. Lone exception: `bin/pikuri-corpus`'s `RubyLLM.embed`, which runs outside any Agent. That context also asks for `openai_use_system_role` — ruby_llm otherwise sends a `:system` message as OpenAI's newer `developer` role, and a local llama.cpp hands the role straight to a chat template that has never seen it. See {Pikuri::Agent::ChatTransport}, {Pikuri::Agent#build_context}.
- **Value-type passthrough.** `lib/` may reference `RubyLLM::Content` / `Attachment` / `Message` directly when wrapping would be a transparent passthrough. See {Pikuri::Agent}.
- **Extraction seam.** Every format→text conversion routes through the `Pikuri::Extractor` registry (`.extract` / `.extract_paged`); a new format is a registry entry, not a new dispatcher arm. `T_extraction_registry`. See {Pikuri::Extractor}.
- **Subprocess seam.** All subprocess spawning in `lib/` routes through `Pikuri::Subprocess.spawn`. Two documented exceptions, both **long-lived stdio children** a one-shot chokepoint cannot model: the spawn inside the `mcp` gem (`mcp/client_wrapper.rb`) and `lsp/client_wrapper.rb`'s own `Open3.popen3`. An exception owns its teardown — `#close`, and for the LSP child `pgroup: true` + SIGTERM to the group, since it forks helpers. `T_subprocess_chokepoint` (which sees two, not three: the MCP child is spawned inside the third-party `mcp` gem). See {Pikuri::Subprocess}, {Pikuri::Mcp::ClientWrapper}, {Pikuri::Lsp::ClientWrapper}.
- **Finalizers / teardown seam.** One process-global teardown registry, single `at_exit`. Resources register at their ownership boundary: process infra a `bin/` starts self-registers; agent-owned resources ride the agent's `on_close`. `Subprocess` registers at load time so it sweeps last. `T_single_at_exit`. See {Pikuri::Finalizers}, {Pikuri::Agent::Configurator}, {Pikuri::Paths.new_temp}.
- **Capability seam (ExtensionContext).** A live `Agent` reference is read-only; everything that *acts on* a wired agent (`emit_event`, `add_raw_tool`, `sub_agent_listeners`, `on_close`) lives on `Agent::ExtensionContext`, handed only to `Extension#bind` / `#on_user_message` (non-extension consumers get it by explicit handoff). Gems emit domain events via `ctx.emit_event`; listeners must no-op on unknown variants. Grep `emit_event|add_raw_tool|sub_agent_listeners` for the capability-user roster; `T_listener_emit`. See {Pikuri::Agent::ExtensionContext}.
- **Workspace seam.** The file tools take a `Workspace::Workspace` composite; `Bash` takes the bare `Workspace::Filesystem`. Every path routes through `#resolve_for_read` / `#resolve_for_write`. The composite enforces the **read-before-edit gate** (Read marks; Edit + overwrite-Write refuse an unread path). File tools run in-process as the real user (only Bash is sandboxed), so `File.writable?` is exact — that backs the confirm-writable-writes / short-circuit-unwritable posture; confirmed writes always route through {Pikuri::Workspace::WriteGate}. `Workspace::Extension` also contributes a **depth-1 boot snapshot** of the root as a system-prompt snippet — one level, never a depth knob, and over its 2 KB cap it degrades to a single line rather than head-truncating. See {Pikuri::Workspace::Workspace}, {Pikuri::Workspace::Filesystem}, {Pikuri::Workspace::Extension}.
- **Denylist seam (walked vs. supplied paths).** `resolve_for_read` / `_for_write` gate a path the *model* supplied; a path a tool **walked** to on its own (a `Listing` row, an `rg` hit) reaches no `resolve_` call, so every enumerating tool must consult `Filesystem#denied?` on its results. That check is the guarantee and fails closed; `rg --glob '!…'` pruning via `Filesystem#denied_roots` is an optimization that may go partial and is never load-bearing. The roster: `Listing`, `Search::Glob` and `Lsp::Sources` / `Lsp::Renderer` call `denied?` per path; `Search::Grep` gets the same guarantee from `Utils.reject_denied_lines`, a prefix filter over `rg`'s output. `T_walked_path_denylist`. See {Pikuri::Workspace::Filesystem#denied?}, `DECISIONS.md` `D_walked_path_denylist`.
- **LSP seam.** A language server is a *foreign binary reading the project*, so four boundaries are fixed. **One root, never configurable**: the `Workspace` root is the child's cwd *and* the `rootUri` it indexes — `StdioEntry` has no `root:` / `cwd:` field. **Every result is a walked path** (`D_walked_path_denylist`): each row passes `Filesystem#denied?` before rendering, and a path shows only where `resolve_for_read` would open it — a basename otherwise. That reaches *prose* as well: `hover` alone answers markdown, so every `file:` URI in its blob is rewritten to the same `path:line` citation a row carries; other schemes pass through untouched (`D_lsp_hover_file_uris`). **pikuri reads `file:` paths and nothing else**: one hardcoded row (`Sources::SCHEME_REQUESTS`, `jdt:` → `java/classFileContents`), `http(s):` never dereferenced, and a new row is a protocol decision, not config (`D_lsp_scheme_fallback`). Servers start on **first use**, so a registered-but-missing binary is reported by the call that needed it rather than at boot. **Every `didOpen` is balanced by a `didClose`**, per *call* rather than per request and only once that call's last reply is in; re-opening an already-open document stays the one deliberate deviation (`D_lsp_document_sync`). `T_lsp_denied_sites`, and `T_lsp_finding_ids` for the `F_` / `J_` / `H_` / `S_` findings the design rests on (defined in `pikuri-lsp/DESIGN.md` §Measurements, cited from the specs, the fixtures and `bin/pikuri-lsp-check`). See {Pikuri::Lsp::Sources}, {Pikuri::Lsp::Servers}, {Pikuri::Lsp::Registry::StdioEntry}.
- **RAG seam (two stores composed, and model text never reaches `MATCH`).** The keyword half is its own backend (`Rag::Backend::Fts5`, the only file in the gem that speaks SQL); `Rag::Backend::Hybrid` is a `Backend` holding *both* stores, fanning writes out and keeping the reads separate. Never a sibling indexer — that is what makes the vectordb `Indexer` / `Watcher` reusable byte-for-byte, and a third index is a third store handed to `Hybrid`, not another wrapper. Three invariants. **"Indexed" means both stores hold it**: `sources_with_hashes` intersects the manifests and `count` is `0` when either store is empty, so a persistent vector store beside a fresh `:memory:` keyword index converges on the next sweep instead of booting to a silently empty `rag_find` — and a raise between the two writes self-heals the same way. **The membership gate is the vector store alone**, deliberately not the intersection, so a lagging keyword store never makes a correctly indexed document unreadable. **Every FTS5 `MATCH` term comes from `Rag::Query`**, emitted as quoted phrase terms so the mini-language (`OR`, `NOT`, `*`, `^`, `col:`, `{}`) is inert in model text and an operator is never exposed; nothing searchable is the tool's to report, never SQLite's. `Query.terms` returns a *list* because FTS5's implicit AND is row-scoped and a row is a chunk — the document-level AND is `Fts5#find`'s, one query per term. `T_fts_match_via_query`. See {Pikuri::Rag::Backend::Fts5}, {Pikuri::Rag::Backend::Hybrid}, {Pikuri::Rag::Query}, `DECISIONS.md` `D_rag_gem`.
- **Bundle-surface seam (skills vs. commands).** A skill is *model*-invoked and therefore advertised (`<available_skills>` + the `skill` tool); a **command is never advertised** — `Command::Registry` contributes no system-prompt snippet and no tool, and its expansion lands as a `:user` turn (so `on_user_message` fires and nothing goes sticky), never `:system`. Both surfaces take `Bundle::Base(dir:, trusted:)` search bases and grade the untrusted leg over what they actually stored; a *refused* command never taints. Typed `/name` resolution belongs to the host, because nothing in the library sees all three namespaces: **host built-in > command > skill**. `T_command_not_advertised`. See {Pikuri::Command::Registry}, `DECISIONS.md` `D_slash_commands`.
- **Skill path gate.** *A `paths:` skill is not in play until its path fires* — one rule, no exceptions to remember. A gated skill is withheld from the prompt block **entirely** (no name, no hint anything is missing) and refused by `SkillTool` and `schedule_load_skill` with the same answer a name that exists nowhere gets, enumeration included. `Skill::Activation` holds the per-conversation set; `Catalog` stays unfiltered (a picker and the installed-skills banner keep telling the truth). Two deliberate fail-opens: a `paths:` value the catalog can't read leaves the skill advertised, and an agent with **no interloper** loses the gate wholesale (`Activation::Open` + a warning) rather than hiding what nothing can bring back. The prompt block reads the *catalog*, never the activation — `clear_conversation` re-assembles the prompt before `on_conversation_reset` runs. See {Pikuri::Skill::Activation}, {Pikuri::Skill::PathActivationListener}, `DECISIONS.md` `D_skill_path_activation`.
- **Confirmer seam.** State-mutating (`Write`, `Bash`) or network-dispatching (`agent`) tools take a `Workspace::Confirmer` and route every prompt through `#ask(request:)` → `Approved(detail)` / `Rejected(reason)` (`#confirm?` is the boolean convenience). Presentation — color, edit affordance, hostile-byte neutralization — belongs to the confirmer, never tool code, which never touches `gets` / `puts` / `$stdin` / `$stdout`. Chrome-independent defanging is the shared `Pikuri::Sanitizer`. See {Pikuri::Workspace::Confirmer}, {Pikuri::Sanitizer}.
- **Sandbox seam.** `Code::Bash` takes a `Code::Bash::Sandbox` (default `NONE`), wraps every argv via `#wrap`. Governs the bash subprocess's fs view (vs Workspace = what the LLM observes). `FullFsNoNet` = full-fs read-write + `--unshare-net` (raises rather than degrading) **minus the live session's IPC sockets** — a tmpfs over `$XDG_RUNTIME_DIR` + `/tmp/.X11-unix`, because a reachable session bus hands the severed egress straight back (`D_headless_os_agent`; the mask must stay *after* the root bind). Threat model + posture comparison in `pikuri-code/DESIGN.md`. See {Pikuri::Code::Bash::Sandbox}.
- **Environment is not a secret store.** pikuri never *filters* `ENV` before spawning (no env-scrubbing primitive). Trusted children inherit it wholesale; untrusted ones are cleared *as a unit by the isolation boundary* (Bubblewrap `--clearenv`, docker). Config holds tokens **verbatim**, not `ENV['X']` refs; `Mcp::Registry::StdioEntry#env` is the legitimate per-child credential channel. The one systematic rewrite is `Pikuri::BundlerEnv`: every long-lived child (bash, MCP, LSP) is spawned de-bundlerized — it *restores* what pikuri's own `bundler/setup` boot changed rather than filtering what the user set (`D_de_bundlerized_children`). An entry's `env:` merges over it. See {Pikuri::Code::Bash::Sandbox}, {Pikuri::Mcp::Registry::StdioEntry}, {Pikuri::BundlerEnv}.
- **Streaming flag.** `Agent.new(..., streaming:)` is opt-in and propagates to sub-agents so the whole tree is consistent. Default false. See `Agent#initialize`.
- **Interloper injection seam.** Mid-loop host→agent injection routes through `Control::Interloper`; each item carries a `kind` — `:user` (a mid-loop turn: `Event::UserTurn` + `on_user_message` dispatch) or `:system` (reference text — a host-loaded skill, retrieved context — no user-turn semantics, reused `Event::SystemInjected`). `run_loop` *delivers* pending injections at turn start (before the first `complete`) and mid-turn only once a **tool batch is complete** — an assistant message carrying `tool_calls` plus the `:tool` messages answering it are one unit on the wire. Never wire a drain to ruby_llm's `after_tool_result`: it fires *before* the result message is added. A blank turn against a conversation holding nothing but the system prompt is provider-split — where `:system` rides a top-level field rather than `messages` (Anthropic, Bedrock) it renders `messages: []`, so `run_loop` raises `Agent::EmptyTurnError`; the rest run the turn against that history. `clear_conversation` *discards* pending injections. Host-driven skill loading is the enqueue-only, main-agent-only `Skill::Extension#schedule_load_skill` — the host must then run the loop. See {Pikuri::Agent::Control::Interloper}, {Pikuri::Agent#run_loop}.
- **Reference-text delivery seam.** *Nothing pikuri appends mid-conversation is ever `role: :system`.* Every block the agent injects on its own initiative — the `Extension#on_user_message` dispatch (memory prefetch, plan-mode re-assertion), the interloper's `:system` kind (host-loaded skill, `paths:` promotion, retrieved context) — routes through `Agent#append_reference_block`, which lands `role: :user` wrapped in `<system-reminder>` (escaping a closing tag in the content) and emits `Event::SystemInjected` carrying the block *unwrapped*. `:system` survives only as the leading assembled prompt, because a mid-conversation one fails **silently and unobservably** — dropped by a chat template, or merged into the standing prompt and left in force, while the payload, the listener stream and `Chat#messages` all report success. `T_no_system_role`, plus the wire-format specs in `pikuri-core/spec/pikuri/testing_spec.rb` (role names *and* order in the recorded request body). See {Pikuri::Agent#append_reference_block}, `DECISIONS.md` `D_reference_text_as_user_turn`.
- **Display-line seam (a tool composes its own).** One tool call reaches a chrome as three short `String`s — `display_name` + `argument` on `Event::ToolCall`, `summary` on `Event::ToolResult` — and a renderer *styles, caps and defangs* them, never composes them (the cap is the renderer's, since only it knows its width; every one of the three goes through `Pikuri::Sanitizer`, which the old `inspect`-escaped argument dump made unnecessary). The **tool** composes them, at `execute` time, where it still holds the structure it is about to flatten for the model: a `Tool::Result(content:, summary:)` return, plus `Tool#display_name` / `#describe_call`. Never the *model* — a narrated status line is steerable through a fetched page — and a summary is **structural, never excerpted** (counts, sizes, exit codes; never the first line of what was fetched). Every default is mechanical (`Tool.display_name_for`, the first required parameter, `Tool.describe_content`), so an MCP tool and a third-party `Tool` still render. All three strings are persisted in `History` (local-only, like `id` / `kind`) because nothing can recompute them later. See {Pikuri::Tool}'s `== Display lines`, {Pikuri::Tool::Result}, `DECISIONS.md` `D_tool_summary_lines`.
- **One tool return type.** `Tool#execute` answers a `Tool::Result`, always — `Result.error` for a recoverable failure, and `Tool#run` wraps a bare String from a third-party `Tool` rather than refusing it. `Result#content` is a `String` except for an **attachment observation** (the image `Workspace::Read` answers for a PNG), where it is a `RubyLLM::Content` and the display line is *derived* (mime + size is all the structure there is). The union is visible in exactly one place — the wrapper in `Tool#to_ruby_llm_tool`, which hands ruby_llm the bare `Content` for an attachment and the `Result` for text, because `content_like?` is an `is_a?` test a `Result` cannot pass. Never widen it by teaching `Result#to_s` to answer the `Content`: ruby_llm's `to_s` call would pass it through, but the broken `to_s` contract then misrenders under interpolation and raises under `String()`, silently. See {Pikuri::Tool::Result}, {Pikuri::Tool#to_ruby_llm_tool}, `DECISIONS.md` `D_tool_always_returns_result`.
- **History seam.** A conversation leaves the agent only as an `Agent::History` (`#export_history` / `#load_history!`); no host reads `@chat.messages`. Four invariants. `:system` is **never exported** — the prompt is re-assembled on load, so a resumed conversation gets today's. `id`, `kind` (`user` vs `reference`, marking what `append_reference_block` injected) and the display strings are **local-only** and reach no provider, tracked in an *identity-keyed* map so nothing can drift out of alignment with `@chat.messages` (`D_history_local_ids`). **Attachments live in the history's own folder or the history does not load** — `save(dir)` writes `attachments/`, and a reference is a bare basename whose *resolved* path must sit in that folder (`D_history_attachments`). And the file is a faithful record while the **repair happens on the way in**: a tool call whose result never arrived is legal on disk and gets a synthesized `INTERRUPTED_RESULT` at load, whereas a result nothing asked for is refused outright (`D_history_load_repairs`). `T_history_encapsulated`. See {Pikuri::Agent::History}, {Pikuri::Agent#load_history!}.
- **A turn never leaves a tool call unanswered.** ruby_llm appends the assistant `tool_calls` message before running any tool, so *anything* unwinding out of the batch — a tool raising, a cancel, an untrapped `Interrupt` — strands calls the next turn would post as a malformed batch (a 400 on OpenAI/Anthropic; silent improvisation on a local model). An `ensure` on `run_loop` answers each one before the exception propagates, blaming the first (the one that raised or was about to) and marking the rest unrun. Don't prevent the damage instead. See {Pikuri::Agent#run_loop}, `DECISIONS.md` `D_unwound_batch_repair`.
- **The loop is unbounded — don't re-add a cap.** Nothing limits tool calls per turn, at any depth: no budget kwarg on `Agent`, same posture in a sub-agent. The ceilings are `Control::Cancellable` (a watching human — every wiring pikuri ships; no `bin/` is unattended) and the context window. A step budget shipped until 2026-09-08 and went: zero real loops caught, repeated false stops on long work. If a loop ever appears, reach for a **repetition detector** (N identical consecutive calls), not a cap. `Control` holds signals, never budgets. See `DECISIONS.md` `D_no_step_limit`, {Pikuri::Agent}'s `== The loop is unbounded`.
- **Sub-agent propagation.** Listeners define `for_sub_agent(**)`; a **tool** may define a no-arg `for_sub_agent` and is rebuilt through it (duck-typed, after `with_workspace`) when a child must hold a narrower view than the parent — `SkillTool` hands over a sealed `Skill::Activation`, so a promotion the parent earned never travels down. Controls don't (inlined in `SubAgentTool#execute`) — the child shares the parent's `Cancellable` by reference, so one Ctrl+C stops the tree. Sub-agents do NOT inherit extensions — each persona owns its toolset + system prompt verbatim — and get **no skills at all**: no catalog block, and no bundled persona names `skill`, so the persona's prompt is the child's complete brief. See {Pikuri::SubAgent::SubAgentTool}, {Pikuri::SubAgent::Persona}, {Pikuri::Agent::ListenerList#for_sub_agent}, {Pikuri::Skill::Activation::Sealed}, `DECISIONS.md` `D_no_skills_in_sub_agents`.
- **MCP-tool bypass.** MCP tools synthesize as raw `RubyLLM::Tool` subclasses, not `Pikuri::Tool`s. See {Pikuri::Mcp::Servers}.
- **Thunderbird no-egress / no-send seam.** No network egress, no *autonomous* send: reads the local profile only (never IMAP/SMTP/CalDAV), writes nothing to Thunderbird's stores. The five inbound tools have no egress leg and are the `Extension` default (both `allow_` flags off). The two outbound tools are opt-in (one flag each) and are *human-gated hand-offs to Thunderbird's own UI* (a `mailto:` compose window; an `.ics` import wizard) — never a send/import by pikuri. **No send tool ever ships.** **No attachment ever ships either** — mail or `.ics`: the hand-off may carry only fields that *render literally* (plain-text body, no HTML, no `attach=`, no iCalendar `ATTACH`), because the gate's entire value is that the human sees the exact bytes that leave. `T_thunderbird_no_attachment`. Reads are an allowlist (Gloda + calendar DBs + `profiles.ini`; credential stores never touched). See {Pikuri::Thunderbird::Extension}, `pikuri-thunderbird/DESIGN.md`.

### Out of scope

- Multi-provider config, vision/audio, embeddings — via ruby_llm if/when needed; not part of pikuri today.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup. CI and bug reports follow the same prioritization.

## Layout

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, `<gem>.gemspec`,
entry file, and (where relevant) `bin/` + `prompts/`. Top-level `Gemfile`
wires every gem via `gemspec path: '<gem>'`; top-level `Rakefile` fans
out `rake test` and orchestrates `rake release VERSION=x.y.z` in lockstep.

`assets/` holds **Kuri**, the mascot — a pika; `kuri.svg` is the master
(transparent, tight `viewBox`) and `kuri.png` its raster. Hosts render
their own icons from it and own how they get a background; the drawing
and its anatomy rule live in `DECISIONS.md` `D_kuri_mascot`.

**"The book"** = the `book/` folder; `book/README.md` is the ToC.
"The book" and "the guide" both mean there. (Renamed from
`docs/guide/` in July 2026.)

**Chapters are named, not numbered** (August 2026). Files are
`security.md` / `code.md`, H1s carry no number, and prose refers to a
chapter by name ("the security chapter") — never by ordinal;
`book/README.md` is the **single source of truth for order**. A name
survives a reordering that silently falsifies an ordinal. **The rule
covers yardoc, gemspec comments and `bin/` scripts, not just prose** —
point at the file (`book/os-assistant.md`), the form `Report::FOOTER`
uses. `T_named_chapters` scans every tracked file, this one included.

Everything pikuri ships lives under `Pikuri::`, contributed by each gem's
own Zeitwerk loader. `Pikuri::PROMPT_DIRS` is likewise cooperative: each
gem appends its `prompts/` at boot, so `Pikuri.prompt(name)` searches all
loaded gems. Per-file rationale lives in each file's YARD header.

The `bin/pikuri-*` scripts are dev / demo entry points only, not gem
executables. Production binaries (e.g. the planned `pikuri-tui`) live in
downstream gems.

**A `bin/` script is simple on purpose, so its simplifications are not
pikuri policy.** Each one must stay readable end-to-end, so it takes the
crudest handling that works — `exit 1` on a context overflow, synchronous
stdin, no interloper. So don't cite a `bin/` script as evidence of how
pikuri *behaves*, and don't propose a library feature whose value rests on
a demo's shortcut — check whether a real host (TUI, web client) would even
have the problem. Library behaviour is defined by `lib/` and its yardoc.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` for value objects, Faraday for HTTP, Rainbow for terminal color. ruby_llm is the LLM transport — no provider-specific SDKs.
- **Composition over inheritance.** Two classes sharing mechanics → extract a concrete helper constructed with explicit kwargs, not a base class with template methods.
- **`# frozen_string_literal: true`** at the top of every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/` (`bin/` and `spec/` exempt). Concrete `@param`/`@return` types (never bare `Object`/`Any`), `@raise` for expected exceptions, one-line summary then tags. **Rationale belongs in the yardoc, not CLAUDE.md** — reference it from here only if it's a cross-cutting invariant.
- **Bundler.** `bin/` scripts self-bootstrap via `require 'bundler/setup'` (no `bundle exec` needed). Add gems with pessimistic `~>` constraints.
- **Every tool declares a sharing posture.** `Agent` is **thread-unsafe** — the caller prevents concurrent access (a thread each, a mutex, an actor); nothing is *thread-confined*, so never key state off `Thread.current`. A tool instance handed to two agents is therefore reachable from two threads, so each tool's yardoc carries a `Sharing:` line (or `== Sharing` where it runs long) naming one of `P_stateless` / `P_shared_locked` / `P_shared_benign` / `P_one_agent`, and names the collaborator that owns the state. `P_one_agent` is a fine answer (today: MCP, LSP, the terminal confirmer); a limiter's scope must match the resource it protects, never the agent. A tool that *waits* opts into `wants_context: true` + a `context:` kwarg and waits through `context.cancellable.sleep`, never `Kernel#sleep`. `T_tool_sharing_posture`. See {Pikuri::Tool}, {Pikuri::Agent}, `DECISIONS.md` `D_tool_sharing_postures` + `D_rate_limiter_scope`.
- **Diagnostics go through `Pikuri.logger_for('Name')`** (memoized stdlib `Logger`, `progname:`-tagged, writing through `Pikuri.log_io`; level `PIKURI_LOG_<NAME>` → `PIKURI_LOG` → `INFO`). Not `puts`/`warn`/`$stderr.puts`. Listener rendering of the LLM stream stays on stdout via `Terminal` — that's not logging.
- **Cache & temp paths go through `Paths`.** Never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache` in a gem. `Paths.cache` is shared + persistent; `Paths.new_temp` is fresh per-process (reaped at exit) — use it for anything two concurrent processes must not share. `T_paths_xdg`. See {Pikuri::Paths.new_temp}.
- **Errors are loud.** On unexpected internal state, raise with the offending data. Tools split it: failures the LLM can react to (bad args, HTTP 4xx/5xx, network blips, division by zero) answer `Tool::Result.error(message)` — an `"Error: <message>"` observation — and become the next turn's input; bugs in pikuri's own code keep raising. Narrow carve-out: best-effort cosmetic paths *secondary to the loop* may rescue-and-degrade — but never errors from libraries on the actual chat path.
- **Per-gem Zeitwerk loaders**, rooted at each gem's `lib/`, eager-loading at boot. No `require_relative` chains inside a gem's `lib/`. A new file defines exactly the camelcased constant matching its path; acronyms (`HTML`, `PDF`, `DuckDuckGo`) need an `inflector.inflect` entry. Extensions nesting under `Pikuri::Tool` mount with `push_dir(..., namespace: Pikuri::Tool)`.
- **Namespacing.** Everything lives under `Pikuri::`. One `Pikuri::*` constant per file at the Zeitwerk path (`<gem>/lib/pikuri/foo/bar.rb` → `Pikuri::Foo::Bar`). No top-level constants.
- **Tests: rspec-core with minitest-style asserts.** Per-gem `spec/`; `rake test` fans out. `describe`/`it` but `assert_equal`/`assert`/`refute`, not RSpec matchers. rspec-mocks is not in the closure — stub module methods with `define_singleton_method` in `before`, restore in `after`. Pattern: `pikuri-core/spec/pikuri/agent_spec.rb`.
- **Tool descriptions follow opencode-shape:** a `description:` heredoc — one-line summary, blank line, `Usage:` bullets (a `# Sub-heading` where a cluster earns it). Per-arg constraints (defaults, caps, format) go in the *parameter* description, not the tool description. Give every parameter an example value (`e.g. "https://example.com"`) — derive it from live values where computed; the one exception is a bounded numeric whose description already states default/cap. Universal failure-recovery guidance lives in per-binary prompts, not per-tool.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** A `foo_*` prefix means a family sharing one backing resource (`task_*`, `thunderbird_*`, `vectordb_*`, `fileindex_*`, `web_*`, `git_*`); a singleton verb every agent understands stays bare (`read`, `write`, `edit`, `grep`, `glob`, `bash`, `fetch`, `skill`, `recall`, `agent`, `calculator`). `file_list` is prefixed for grammar, not collision — `list` has no implied object the way `read` does. Don't spend an in-distribution name (`read` → `file_read`) for symmetry; see `DECISIONS.md` `D_directory_listing`.
- **No tool names in a main/binary system prompt.** A `prompts/<bin>.txt` names no wired pikuri tool, so it can't drift against the wiring or reference a tool the binary doesn't wire; a tool's existence + mechanics live in its `description:` (sub-agents: the persona `description`). The real rule: **naming the wired tool or restating its mechanics is forbidden; stating a capability the agent observes** (e.g. "the commands you run can't reach the internet") **is fine** — even when the words collide. The main prompt keeps general engineering norms and agent-level orchestration, phrased as an action. **Persona prompts (`prompts/persona-*.txt`) are the carve-out** — `tool_names:` + `system_prompt:` are co-located, so they may name their tools. `T_no_tool_names_in_prompts` (a dual-natured shell-command tip is a reviewer-cleared false positive).
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace." Applies to README / SECURITY / COMPARISON / book — any human-facing prose (not yardoc).

## Working on this codebase

- **Agent owns the extension surface; ruby_llm owns the loop.** Changing `agent.rb` = "what hooks fire when?", not reimplementing iteration. Reach for a different listener instead.
- **Readable, not obfuscated.** Simplest implementation that does the job; no abstraction layers / plugin systems / config knobs not needed for the next concrete step.
- **Grow by adding tools, listeners, or controls — not by complicating the loop.** New capabilities land as new `Pikuri::Tool` / `Listener` / `Control` constants with their own specs; core and ruby_llm's loop stay ignorant of them.
- **Grow by adding *bounded gems*, not by fattening one — each addition re-examines the trifecta.** A bounded gem has a *closeable* threat model (freeze the surface, enumerate the legs, write the DESIGN.md); fattening a gem makes every new tool interact with every existing leg. But a bounded concept earns a gem only with a *novel* threat model **or** cohesive lib code needing a home — not merely a nameable posture (worked example: `bin/pikuri-computer` shipped as a demo + the book's OS-assistant chapter, not a gem). Name a gem after what it *refuses to become*.

## CI

Woodpecker CI runs `rake check` (= `test` then `tripwires`; also the
`default` task, per the cross-repo standard) on push / PR / manual
(`.woodpecker.yml`, dashboard
<https://ci.codeberg.org/repos/17229>). The `ruby:4.0` image lacks
`ripgrep`, so the config installs it (the Grep tool's specs need `rg`).
Everything runs as an unprivileged user — root would bypass the permission
bits the workspace specs assert. Gem deps cache in Hetzner Object
Storage, keyed on `Gemfile.lock`.
