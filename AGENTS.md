# pikuri — AGENTS.md

## What this is

A small Ruby AI assistant you run on your own machine, shipped as
a family of gems in a monorepo; you install the ones you wire.
Defaults wire a local
[llama.cpp](https://github.com/ggml-org/llama.cpp) server, so a
conversation never leaves your computer unless the model itself
decides to call a network tool. The smallest demo binary is
`pikuri-chat` from [`pikuri-core`](pikuri-core/README.md); the rest
of the family adds filesystem tools, sub-agents, web search,
local-corpus vector search and your Thunderbird mail à la carte.
The power tools (a shell, a coding agent, MCP, skills) live in
[pikuri-workshop](https://github.com/mvysny/pikuri-workshop).

## Promises

- **Privacy first.** By default nothing leaves the machine; every hosted provider and every network-reaching tool is an explicit opt-in, and a feature that only works against a hosted one breaks the posture even when nobody turns it on.
- **Readable in an evening.** You read only the code you run: core plus the gems you wire fits one sitting. Core is in every deployment, so it stays lean and clean; a gem may carry the complexity its job genuinely needs, bounded by a closeable threat model, and new work grows a new gem rather than fattening one. A layer or a knob not needed for the next concrete step is a violation even when it is small. See `D_read_what_you_run`.
- **The trifecta is broken by construction.** No agent that reads untrusted content also holds private data and a way to send bytes out — at most two legs at any node, and never by filtering, because filters lose to adversarial text.

## Design docs

| File | Owns | Loaded |
|---|---|---|
| `README.md` | the pitch, install, a couple of examples, routing onward | — |
| `AGENTS.md` (this) | promises, invariants, the module map, conventions, commands | every turn |
| `design/architecture.md` | how the gems compose in one process — wiring, dependency direction, the flows; normative | lazy |
| `design/decisions.md` | why this and not that — `D_` entries, FAQ-shaped | lazy |
| `design/research.md` | what opencode, PI, grok-build, hermes-agent and langchainrb actually do — `R_` entries, each claim with provenance | lazy |
| `design/ideas/` | not yet decided — one file per idea, `ls` is the index, deleted on graduation | transient |
| `<gem>/design/architecture.md` | that gem's own cross-symbol picture + its closeable threat model | lazy |
| yardoc (source headers) | what one symbol does, why it is shaped so | at the symbol |
| `book/` | a learner reading in order: concepts, teaching narrative, the cross-cutting why | — |
| `SECURITY.md` | threat model + shipped defenses | — |
| `CHANGELOG.md` | what changed and what you must do about it | — |

Every fact lives in exactly one of these; the others link to it. A cite into pikuri-workshop's
docs is qualified, `pikuri-workshop:D_<slug>`, and the design tripwire leaves it to that repo.

## Invariants

- **Nothing in pikuri requires a pikuri-workshop gem.** Dependencies point from the workshop to here, never back; a `lib/`, `bin/`, spec or chapter that needs one belongs there. See `pikuri-workshop:D_separate_repo`.
- **Loop seam.** ruby_llm owns `Chat#complete`; never build a `RubyLLM::Chat` or attach its callbacks outside `pikuri-core`'s `agent.rb` and `tool.rb`. See {Pikuri::Agent}.
- **Connection seam.** Every chat rides a per-chat `RubyLLM::Context` built from an `Agent::ChatTransport`, never the process-global `RubyLLM.configure`. See {Pikuri::Agent#build_chat}.
- **An extra request parameter is opaque.** `ChatTransport#params` is deep-merged into the payload verbatim; pikuri never translates one, names one, or grows a typed flag for it. See `D_opaque_request_params`.
- **Request seam.** `Agent.new(around_request:)` brackets one HTTP request, never a turn — a turn-scoped throttle deadlocks a parent against its own sub-agent; pikuri ships no throttle, a host hangs one here. See `D_llm_request_throttle`.
- **Attachments are bytes.** Every attachment pikuri hands around is a `Pikuri::Attachment`; a `RubyLLM::Attachment` is built only by {Pikuri::Attachment#to_ruby_llm}, so no path or URL ever reaches ruby_llm's read-at-construction. See {Pikuri::Attachment}.
- **Extraction seam.** Every format→text conversion routes through the `Pikuri::Extractor` registry — a new format is a registry entry, not a dispatcher arm.
- **Subprocess seam.** All subprocess spawning in `lib/` routes through `Pikuri::Subprocess.spawn`; a bare `Process.spawn` or `Open3` outlives the turn that started it.
- **Finalizers / teardown seam.** One process-global teardown registry and a single `at_exit`, each resource registering at its ownership boundary. See {Pikuri::Finalizers}.
- **Capability seam.** A live `Agent` reference is read-only; everything that *acts on* a wired agent lives on its `Agent::Configurator`, handed only to the `Agent.new` block and `Extension#configure`. See `D_one_phase_extensions`.
- **Environment is not a secret store.** pikuri never *filters* `ENV` before spawning; config holds tokens verbatim, and a per-child `env:` is the credential channel. See `D_de_bundlerized_children`.
- **Streaming flag.** `Agent.new(..., streaming:)` is opt-in and propagates to sub-agents, so the tree is consistent.
- **Interloper injection seam.** Mid-loop host→agent injection routes through `Control::Interloper`, delivered at turn start or once a tool batch is complete — never inside one. See {Pikuri::Agent::Control::Interloper}.
- **Nothing pikuri appends mid-conversation is ever `role: :system`** — a mid-conversation `:system` message fails silently. See {Pikuri::Agent#append_reference_block}, `D_reference_text_as_user_turn`.
- **Display-line seam.** The **tool** composes its three display strings at `execute` time — never the model, and never a renderer, which only styles, caps and defangs them. See {Pikuri::Tool}'s `== Display lines`, `D_tool_summary_lines`.
- **One tool return type.** `Tool#execute` answers a `Tool::Result`, always; the attachment case surfaces only inside `Tool#to_ruby_llm_tool`. See `D_tool_always_returns_result`.
- **History seam.** A conversation leaves the agent only as an `Agent::History`, an in-memory value pikuri never serializes; no host reads `@chat.messages`. See `D_history_value_type`, `D_history_local_ids`, `D_history_load_repairs`.
- **A turn never leaves a tool call unanswered.** An `ensure` on `run_loop` answers every call stranded by an unwinding batch — repair the damage, don't prevent it. See `D_unwound_batch_repair`.
- **The loop is unbounded — don't re-add a cap.** Nothing limits tool calls per turn, at any depth; if a runaway ever appears, reach for a repetition detector. See `D_no_step_limit`.
- **Every tool declares `trifecta_legs`**, a persona holds at most two, and a new tool or persona is placed on the map — pikuri never sanitizes tool output. See {Pikuri::Trifecta}, `D_egress_axis_shape`.
- **Sub-agent propagation protocol.** Listeners define `for_sub_agent(**)`, and a tool may define a no-arg one to be rebuilt narrower for a child. See {Pikuri::Agent::ListenerList#for_sub_agent}, `pikuri-subagents/AGENTS.md`.
- **A seam consumed across gems is stated once by its owner** — Workspace / Denylist / Confirmer belong to `pikuri-workspace`; a consumer carries a pointer, never a restatement.

## Module map

Rails-shape monorepo: each gem owns its `lib/`, `spec/`, gemspec, entry file, and where
relevant its `bin/`, `prompts/` and `design/`. The top-level `Gemfile` wires every gem via
`gemspec path:`; the top-level `Rakefile` fans out `rake test` and orchestrates `rake release`.

- `pikuri-core` — `Agent` runtime, `Tool` framework, Extension protocol, listener stream, `Subprocess` chokepoint, `Extractor` registry, the bundled `calculator`, `bin/pikuri-chat`.
- `pikuri-pdf` — in-process pure-Ruby PDF → text for the registry. The docker-free PDF arm; pikuri-workshop's pikuri-extractors is the other.
- `pikuri-web` — the tools that reach the internet: `web_search` and its engines, `web_scrape`, `fetch`, `web_read_cached`, the URL caches, and the HTML extractor it registers on require.
- `pikuri-workspace` — `Filesystem` / `Confirmer` seams, the file tools, the `ReadOnly` gate, `bin/pikuri-files`. Rules: `pikuri-workspace/AGENTS.md`
- `pikuri-thunderbird` — local Thunderbird mail + calendar: read-only inbound tools, human-gated outbound hand-offs. Rules: `pikuri-thunderbird/AGENTS.md`
- `pikuri-subagents` — the `agent` tool, the `Persona` record, the bundled personas, `bin/pikuri-minions`. Rules: `pikuri-subagents/AGENTS.md`
- `pikuri-vectordb` — the retrieval *primitive*: topical vector search over a local corpus + `bin/pikuri-corpus`.
- `pikuri-rag` — the retrieval *system* on that primitive: hybrid vector + FTS5 search + `bin/pikuri-briefing`. Rules: `pikuri-rag/AGENTS.md`
- `book/` — "the book", also "the guide"; `book/README.md` is the ToC and the single source of truth for chapter order.
- `assets/` — **Kuri**, the pika mascot (`kuri.svg` master, `kuri.png` raster); drawing + anatomy rule in `D_kuri_mascot`.
- [pikuri-workshop](https://github.com/mvysny/pikuri-workshop), a separate repo — the gems that need a cage: a shell, the coding agent, the OS assistant, LSP, MCP, skills, tasks, mem0, docker extractors.
- `bin/pikuri-*` — demo entry points a user runs, not gem executables, with their prompts in `prompts/`; production binaries live downstream.
- `dev/` — tooling for whoever develops pikuri, never run by a user or a reader; a gem's own lives in `<gem>/dev/`. `dev/demo-home/build` builds the demo `~/Documents` on a machine with no files of its own there (the dev VM); `pikuri-thunderbird/dev/testbed/` adds the demo mailbox on top. See `D_thunderbird_testbed`.

## Conventions

- **Ruby, no Rails.** Plain classes, `Data.define` value objects, Faraday for HTTP, Rainbow for color; ruby_llm is the only LLM transport.
- **Linux-first; macOS may work; Windows is unsupported.** POSIX shell, GNU `timeout`, XDG cache layout, SIGTERM process-group cleanup.
- **`# frozen_string_literal: true`** atop every Ruby file (`lib/`, `spec/`, `bin/*`).
- **YARD on every public module/class/method** in `lib/`: concrete `@param` / `@return` types, `@raise` for expected exceptions, one-line summary then tags, and the local *why*.
- **Bundler.** `bin/` scripts self-bootstrap via `require 'bundler/setup'`; pessimistic `~>` constraints.
- **A gemspec's runtime dependencies are what its `lib/` requires.** A sibling gem only a `bin/` script or a spec uses comes from the root `Gemfile`; a third-party gem only they use is an `add_development_dependency`.
- **Per-gem Zeitwerk loaders**, eager-loading at boot; no `require_relative` inside a gem's `lib/`. One constant per file at the Zeitwerk path, everything under `Pikuri::`, acronyms need an `inflector.inflect` entry, no top-level constants. `Pikuri::PROMPT_DIRS` is likewise cooperative.
- **Tests: rspec-core with minitest-style asserts.** `describe` / `it` but `assert_equal` / `assert` / `refute`, no RSpec matchers, no rspec-mocks (stub with `define_singleton_method` in `before`, restore in `after`). Pattern: `pikuri-core/spec/pikuri/agent_spec.rb`.
- **Diagnostics go through `Pikuri.logger_for('Name')`**, never `puts` / `warn` / `$stderr`; listener rendering of the LLM stream on stdout via `Terminal` is not logging.
- **Cache & temp paths go through `Paths`** (`Paths.cache` shared + persistent; `Paths.new_temp` per-process, reaped at exit); never read `ENV['XDG_CACHE_HOME']` or hardcode `~/.cache`.
- **Errors are loud.** Unexpected internal state raises with the offending data; failures the LLM can react to answer `Tool::Result.error(message)`; only cosmetic paths secondary to the loop may rescue-and-degrade.
- **Every tool declares a sharing posture.** `Agent` is thread-unsafe (the caller serializes; never key state off `Thread.current`), so a tool reachable from two agents carries a `Sharing:` yardoc line naming `P_stateless` / `P_shared_locked` / `P_shared_benign` / `P_one_agent` plus the state's owner; a waiting tool opts into `wants_context: true` and sleeps via `context.cancellable.sleep`. See `D_tool_sharing_postures`, `D_rate_limiter_scope`.
- **Tool descriptions follow opencode-shape:** one-line summary, blank line, `Usage:` bullets; per-arg constraints go in the *parameter* description with an example value. Universal failure-recovery guidance lives in per-binary prompts.
- **Tool naming: a prefix marks a family, a universal verb goes bare.** `foo_*` = a family sharing one backing resource; a verb every agent knows stays bare (`read`, `fetch`, `agent`). See `D_directory_listing`.
- **No tool names in a main/binary system prompt.** `prompts/<bin>.txt` names no wired tool and restates no mechanics; persona prompts (`prompts/persona-*.txt`) are the carve-out.
- **Grow by adding tools, listeners or controls** — new `Pikuri::Tool` / `Listener` / `Control` constants with their own specs; core and the loop stay ignorant of them.
- **Name a gem after what it refuses to become.** A gem is earned by a *novel* threat model or cohesive lib code needing a home; a nameable posture alone ships as a demo.
- **A gem whose future is more features goes to pikuri-workshop, and so does one that isn't safe on your host as-is.** pikuri grows by explaining better, never by gaining features. See `D_gem_placement`.
- **A `bin/` script is simple on purpose**, so its simplifications are not pikuri policy — never cite one as evidence of how pikuri behaves. Library behaviour is `lib/` and its yardoc.
- **Book chapters are named, not numbered** — never an ordinal, anywhere. A new concept is one `book/<slug>.md`, one line in `book/README.md`, and fixed neighbouring "What's next" links.
- **A CHANGELOG entry is one sentence**, new work under `[Unreleased]`, a shipped section closed.
- **The seam checks in `tasks/tripwires.rake` are a closed set of five.** A new invariant is a line here and stays unchecked. See `D_tripwire_bar`.
- **User-facing docs: prefer concrete over abstract.** "Delete your home folder" beats "filesystem mutation outside the workspace" — README / SECURITY / book, not yardoc.

## Commands

- `bundle exec rake check` (also the default task) — specs across every gem, then `tripwires`, then `design_tripwires`; verbatim what CI runs on push / PR / manual (`.woodpecker.yml`, dashboard <https://ci.codeberg.org/repos/17229>).
- `bundle exec rake tripwires` — the five seam checks (`tasks/tripwires.rake`). A failure is as often a stale expectation as a real violation — read the lines before "fixing" the code.
- `bundle exec rake design_tripwires` — the doc layer (`design/verify_design_tripwires.sh`); same rule about stale expectations.
- `cd pikuri-core && bundle exec rspec spec/pikuri/agent_spec.rb:42` — one test; run from the gem dir, whose `.rspec` loads its `spec_helper`.
- `bundle exec rake release VERSION=x.y.z` — every gem in lockstep, one OTP window (`D_release_one_otp`).

## Skills this project follows

- **Component-oriented:** self-sufficient components that reach their data directly, no MVC layers; inherit to *be* a thing, never to share code. The `cop` skill has the rules.
- **Yardoc is browsed standalone on rubydoc.info**, so each header carries the complete local what *and* why, deferring only the book-wide narrative. The `writing-rdoc` skill has the rules.
- **An idea file is temporary:** it lives in `design/ideas/`, one per file, `ls` is the index, and graduation is not done until the file is gone and its nuggets are in the durable homes the table above names. The `ideas-folder` skill has the procedure.
- **This doc layer** — the loaded file, the lazy `design/` files, the tripwire — is the `design-docs` skill's shape.

## Maintenance of this file

Loaded every turn; cap 34 KB. Over it, in this order:
delete what has no home — status, history, class lists, what the code already says; trim
each line to its fact plus one clause and send the explanation home — why →
`design/decisions.md`, how across symbols → `design/architecture.md`, how in one symbol →
its doc comment, what upstream does → `design/research.md`; only then a module's own
`AGENTS.md`, peripheral modules first, never the core. Never paraphrase a lazy entry into a
line here. `design/verify_design_tripwires.sh` checks the cap and the cites.
