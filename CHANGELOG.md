# Changelog

All notable changes to pikuri, newest first. One sentence per entry,
grouped `Add`, then `Fix`, then `**Breaking:**`; the rationale lives in
`DECISIONS.md`, the yardoc and the book, which entries link rather than
restate. Versioning is semver as documented in
`pikuri-core/lib/pikuri/version.rb`. The `0.0.4`–`0.0.7` sections were
reconstructed from git history in August 2026, after those releases had
shipped without one.

## [Unreleased]

Two offline agents graduate into gems — `pikuri-os` (whole-machine
helper) and `pikuri-thunderbird` (local mail + calendar) — and the
lethal-trifecta detector turns a wiring into a map the host prints at
boot.

- Add `pikuri-lsp` — read-only code navigation through a language server you already have installed: one `lsp` tool with ten operations (`goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`, `goToTypeDefinition`, `incomingCalls`, `outgoingCalls`, `supertypes`), anchored on a `symbol` and never a column, capability-gated per workspace, with servers started on first use and configured through `Lsp::Registry.from_h`. Wired by `bin/pikuri-code` from the `lsp_servers:` key of `~/.pikuri-examples-config.yaml`; no config means no tool.
- Fix the `lsp` tool's `hover` quoting a server's raw `file://` URIs — absolute, column-bearing and past the denylist every row passes; each is now rewritten to the same `path:line` citation a row carries, keeping its markdown link only where `read` would open the file. See `DECISIONS.md` `D-lsp-hover-file-uris`.
- Fix the `lsp` tool printing duplicate rows when a server returned two results on one line — pikuri prints no column, so results differing only in column rendered identically while counting twice in the header and against the result cap; `Lsp::Renderer#locations` now dedupes on the rendered row. See `pikuri-lsp/DESIGN.md` `R-same-line-references`.
- Fix `Workspace::Filesystem`'s `/tmp` alias rewriting paths inside a project that itself lives under `/tmp`, which sent every absolute in-root path into the agent's empty playground — the sandbox re-binds workspace roots over its `/tmp` bind, so the host-side rewrite now agrees and skips them; a `Pathname` argument no longer raises there either.
- Fix a Bundler-booted pikuri leaking `BUNDLE_GEMFILE` / `RUBYOPT` / `GEM_*` / `PATH` into its stdio MCP servers, where a Ruby-written server resolved its gems out of *pikuri's* bundle — `Pikuri::BundlerEnv` (extracted from `Code::Bash`, which already de-bundlerized `bash`) now corrects every long-lived child. See `DECISIONS.md` `D-de-bundlerized-children`.
- Add `Agent::Event::Transient` — a marker a gem's own progress event includes so `Listener::Terminal` rewrites one line in place instead of logging every update, showing only the final state when stdout is not a terminal.
- Add `bin/pikuri-wire-check` — a dev diagnostic that records what pikuri would POST for a turn covering five positions (system prompt, user turn, reference block before and after a tool batch, tool result) and reports which survive llama.cpp's `/apply-template`, since nothing inside pikuri can see a message its model's chat template discards. See `book/wire.md`.
- Add slash commands — `Command::Registry` + `Command::Renderer` scan `.pikuri/commands` / `.claude/commands` for `.md` prompt templates you invoke by typing `/name`, never advertised to the model and costing nothing in the system prompt; `bin/pikuri-code` and `bin/pikuri-assistant` dispatch them. See `DECISIONS.md` `D-slash-commands`.
- Add `Trifecta::Contribution#label` — an extension's declared legs get their own row in the trifecta report instead of every contributor landing under a hardcoded `(mcp)`.
- Add the `paths:` and `when-to-use:` frontmatter keys to the skill catalog — `Catalog::Skill#paths` / `#when_to_use` / `#gated?`, plus `Skill::PathMatcher` (the `paths:` parser and its gitignore-dialect matcher), `Skill::Activation` (which gated skills a conversation has in play) and `Skill::Trigger` (description ↔ `when-to-use` de-duplication). See `DECISIONS.md` `D-skill-path-activation`.
- Add path-triggered skill activation — a skill declaring `paths:` is withheld from `<available_skills>` and unloadable by name until a `read` / `write` / `edit` touches a matching file, at which point its description and `when-to-use` are injected once per conversation and it becomes loadable; an agent with no `interloper:` keeps every skill advertised, since a promotion would have nowhere to land. See `DECISIONS.md` `D-skill-path-activation`.
- Add typed `/name` skill loading to `bin/pikuri-code` — the third and last leg of the host's resolution chain (host built-in > command > skill), so `/cop` enqueues that skill's body to arrive with your next message; argument-less, and a `paths:`-gated skill stays unloadable until its path fires. See `DECISIONS.md` `D-slash-commands`.
- **Breaking:** `Skill::Renderer.format_catalog` takes an `Array<Catalog::Skill>` rather than a `Catalog`, since the caller now decides what to withhold. Pass `catalog.list`.
- Add per-search-base trust to the skill catalog — `Bundle::Base(dir:, trusted:)` grades `SkillTool`'s untrusted trifecta leg over the skills a catalog actually stored, and `bin/pikuri-code` asks whether this repo's sources are your own work. See `DECISIONS.md` `D-bundle-trust-grading`.
- Add an `occurrence` parameter to `Workspace::Edit` — replace the Nth match by position rather than padding `old_string` with context until it is unique; mutually exclusive with `replace_all`, and the match itself stays byte-exact. See `DECISIONS.md` `D-single-hunk-edit`.
- Add the `file_list` tool — `Workspace::FileList`, the only tool that shows the model a directory *exists* (`glob` is `rg --files`, which emits files only); `path` defaults to the workspace root, `depth` to 1 and caps at 3. Wired by `Workspace::Extension` and added to the `FILE_MINER` / `GIT_REPO_RESEARCHER` recon personas. See `DECISIONS.md` `D-directory-listing`.
- Add a boot snapshot to `Workspace::Extension` — a depth-1 `<workspace_snapshot>` listing of the workspace root, contributed as a system-prompt snippet so orientation costs zero tool calls; ~325 tokens at this repo's root, degrading to one line over 2 KB. See `DECISIONS.md` `D-directory-listing`.
- Add `Workspace::Listing` — the gem's one directory renderer (name-sorted, directories first, per-row sizes or `[4 dirs, 25 files]` summaries, errno classes where a row can't be measured), now backing the oversized-root refusal too. See `DECISIONS.md` `D-directory-listing`.
- Add `pikuri-thunderbird` — the local Thunderbird profile as five read-only tools (`thunderbird_mail_search` / `_mail_read` / `_calendar_search` / `_calendar_read` / `_contact_search`) plus two opt-in hand-offs (`_mail_compose`, `_calendar_create`) that hand bytes to Thunderbird's own compose window or import wizard rather than sending anything. See `pikuri-thunderbird/DESIGN.md`.
- Add `pikuri-os` — an offline, network-severed OS helper: `fileindex_search` / `fileindex_read` over a swappable desktop index (localsearch or Recoll), `MACHINE.md` resident memory, boot-time machine facts, and `bin/pikuri-os` whose `--with-internet` routes the web through a confirmed, isolated researcher. See `book/os-assistant.md` and `DECISIONS.md` `D-headless-os-agent`.
- The privileged hand-off in `pikuri-os` splits reads from state changes: the agent never holds root, and anything that needs it comes back as an exact `sudo …` command for the human to run. See `DECISIONS.md` `D-no-agent-sudo`.
- Add `bin/pikuri-computer` — the demo composition of `pikuri-os --with-internet` with pikuri-thunderbird, shipped as a binary plus a book chapter rather than as a gem.
- Add `Pikuri::Trifecta` — the advisory, never-blocking lethal-trifecta detector: tools declare their legs via `Tool::TrifectaLegs`, `Trifecta.walk` folds them across the agent's tools and sub-agent personas, and `Agent#trifecta` hands the host a report to print. See `book/trifecta-detector.md` and `DECISIONS.md` `D-egress-axis-shape`.
- Add `Code::Bash::Sandbox::FullFsNoNet` — full-filesystem read-write with `--unshare-net` for the whole-machine helper, raising rather than degrading when bubblewrap cannot sever the network. See `DECISIONS.md` `D-headless-os-agent`.
- Add plan mode — `Code::EnterPlanMode` / `Code::ExitPlanMode` over a `Workspace::ReadOnly` gate that refuses `Write` / `Edit` with a custom reason, plus a per-turn reminder and a UI event.
- Add `Workspace::Workspace` — the composite the five file tools now take, enforcing the read-before-edit gate (Read marks a path; Edit and overwrite-Write refuse an unread one) and routing every confirmed write through `Workspace::WriteGate`.
- Add the confirm-all-writable write posture — passing a confirmer to `Write` / `Edit` confirms each write with a unified diff (`Confirmer::Change`), while an unwritable target short-circuits to a permission-denied observation instead of prompting. See `DECISIONS.md` `D-permission-wall-handoff`.
- Add editable confirmations — `Confirmer::Terminal` lets the human edit the proposed payload before approving, and a rejection carries a reason the tool sees as its next observation.
- Add `Code::Bash::PassiveCommandDetector` + `Code::Bash::Tokenizer` — read-only commands (`git` queries on a trusted repo, dpkg/apt queries, `man`, `systemctl show`, SMART diagnostics, and `&&` / pipe chains of them) auto-approve, with flag denylists recovering the read-only halves of `dmesg` and `journalctl`.
- Add `Pikuri::Testing.fake_transport` — a scripted-HTTP fake LLM, with an `api_base` override and a mid-turn `Gate`, so specs drive a real `Agent` end to end with no server. See `DECISIONS.md` `D-fake-transport`.
- Add `Agent#clear_conversation` — the host's `/clear`, with an extension reset hook, and dynamic system-prompt sections reassembled pull-style on each clear.
- Add `Agent::Extension#system_prompt_snippets` and `Pikuri.prompts(*names)` — a gem contributes its own prompt fragment instead of the host pasting it, and a binary assembles a system prompt from several files.
- Add `Skill::Extension#schedule_load_skill` — enqueue-only, main-agent-only host-driven skill loading; the host then runs the loop.
- Add a `kind` to `Control::Interloper` items — `:user` (a mid-loop turn) or `:system` (reference text, wrapped and landed by `Agent#append_reference_block`) — delivered at turn start, plus an `on_change` hook that fires when the pending count moves.
- Add `Paths.new_temp` / `Paths.config` / `Paths.state` — per-process ephemeral scratch reaped at exit, alongside the shared `Paths.cache` that `UrlCache` now uses. See `DECISIONS.md` `D-per-process-temp`.
- Add `Agent::EmptyTurnError` — a blank turn against a conversation holding nothing but the system prompt now completes on providers that keep `:system` in the messages array and raises on the ones that carry it in a top-level field instead (Anthropic, Bedrock), rather than silently returning `false`.
- Add startup trust prompts to `bin/pikuri-code` — it asks whether the project is private (feeding the trifecta map) and whether the repo is trusted (gating read-only `git` auto-approval), and prepends the user's `~/.claude/CLAUDE.md` to the system prompt.
- Add an `include_gitignored` parameter to `Grep` / `Glob`, replacing a hint that told the model to shell out to `rg --no-ignore`.
- Add `Pikuri::Code::Extension` — one-call wiring for the pikuri-code-only pieces.
- Add Reline to the example REPLs for history and line editing; `pikuri-workspace` now declares the `reline` dependency Ruby 4.0 dropped from its defaults.
- The guide moves from `docs/guide/` to `book/`, and its chapters are named rather than numbered (`book/security.md`, `book/tasks.md`), with `book/README.md` owning the order.
- Fix a gem domain event's `to_s` reaching the terminal undefanged in `Listener::Terminal` — the generic arm now routes it through `Pikuri::Sanitizer` as tool results already were, since that text can come from a filename, a skill or a subprocess.
- Fix reference text vanishing before it reached the model: a mid-conversation `:system` message is dropped whole by newer chat templates (Qwen3.6 discards every one past the leading header) and merged into the standing system prompt by Anthropic, so pikuri-memory's prefetch, host-loaded skills and `paths:` promotions now land as a `<system-reminder>`-wrapped `:user` turn. See `DECISIONS.md` `D-reference-text-as-user-turn`.
- Fix every `:system` message going out under OpenAI's newer `developer` role, ruby_llm's default: a local llama.cpp hands the role straight to the model's chat template, which has never seen it, so the system prompt arrived mislabelled. `Agent#build_context` now asks for `system`.
- Fix a mid-loop interloper injection landing *between* an assistant's `tool_calls` message and the `tool` message answering it — invalid on OpenAI and Anthropic, and mangled by a local chat template. The drain moved off ruby_llm's `after_tool_result` (which fires before the result message is added) to the completion of the tool batch.
- Fix `<available_skills>` paying for a skill path it cannot use: `Renderer` no longer emits `<location>` in the catalog or promotion blocks, which the Agent Skills standard sanctions omitting when the activation tool returns the directory — `format_skill` still carries it, so sidecar reads are unaffected.
- Fix the `skill` tool's description telling a sub-agent its skills are listed in the system prompt under `<available_skills>` — a persona naming `skill` in `tool_names:` inherits the tool but not the `Skill::Extension` that contributes that block, so recovery now leans on the not-found error, which lists the real names.
- Fix `Code::Bash`'s read-only allowlist escapes — `rg --pre` executing an arbitrary program, unquoted globs, and other cases where an extra argument grows teeth on an otherwise read-only binary.
- Fix the credential denylist covering only paths the model *supplied*: `grep` returned the contents of `~/.ssh/id_rsa` and `glob` listed it, because a path a tool walked to reached no `resolve_for_read`. Every enumerating tool now consults `Filesystem#denied?`. See `SECURITY.md` and `DECISIONS.md` `D-walked-path-denylist`.
- Fix `Grep` / `Glob` accepting `/`, `$HOME` or any parent of home as a search root; a refused root now comes back with a one-level listing to pick from, and ripgrep's error blob is capped instead of pasted whole into the observation.
- Fix `read` on a directory: it pointed at `glob`, which lists no directories at all, so orientation dead-ended — it now hands back the directory's own entries instead. See `DECISIONS.md` `D-directory-listing`.
- Fix `FullFsNoNet`'s `/dev` handling (bind the real one, not bwrap's synthetic `--dev`) and mask the live session's IPC sockets, so the severed egress is not handed straight back by the session bus.
- Fix `ruby_llm` streaming error parsing against non-Hash bodies and against the `{"error": "…"}` string shape.
- Fix sub-agent-only tools being credited to the parent node in the trifecta map, which reported the sub-agent quarantine as broken. See `DECISIONS.md` `D-trifecta-map-orphans`.
- Add a tool-level `for_sub_agent` hook — a tool holding state a spawned sub-agent must see less of hands over a narrower copy (duck-typed, applied after `with_workspace`); `SkillTool` uses it to give the child an `Activation::Sealed`, so a skill the parent path-activated is not reachable in an agent that was never told its name.
- **Breaking:** `Skill::SkillTool.new(catalog:)` → `new(activation:)`, taking a `Skill::Activation` (which carries the catalog). Hosts wiring skills through `Skill::Extension` are unaffected; a host building the tool by hand wraps its catalog in `Skill::Activation.new(catalog:)`.
- **Breaking:** `Skill::Extension.new` now requires `root:`, the absolute `Pathname` a touched path will be resolved against. Pass your workspace root — `bin/pikuri-code` passes `project_root`.
- **Breaking:** `SubAgent::FILE_MINER` and `Code::GIT_REPO_RESEARCHER` now list `file_list` in `tool_names`, so `SubAgent::Extension#configure` raises unless a `file_list` tool is registered. Hosts wiring the file tools through `Workspace::Extension` get it automatically; a host registering file tools by hand must add `Workspace::FileList.new(workspace:)`.
- **Breaking:** `Workspace::Confirmer` is now a chrome-only seam whose primitive is `#ask(request:)` returning `Approved(detail)` / `Rejected(reason)`, with `#confirm?` as the boolean convenience. A custom confirmer must implement `#ask`, and command-approval policy moves out to `Code::Bash::PassiveCommandDetector`.
- **Breaking:** `Workspace::Grep` / `Workspace::Glob` → `Workspace::Search::Grep` / `Workspace::Search::Glob`. Update the constants; the `grep` / `glob` tool names are unchanged.
- **Breaking:** `Tool::Parameters#to_h` → `#to_openai`. Rename the call.

## [0.0.7] - 2026-06-11

Connections stop being process-global: a model's base URL and key ride
its `ChatTransport`, so several servers finally coexist, and the example
bins read their connection config from a file instead of CLI flags and
`ENV`.

- Add `Agent::ChatTransport.from_openai_server(server:, model:, api_key:)` — the connection rides the transport onto a per-chat `RubyLLM::Context` instead of a process-global `RubyLLM.configure`, and a `server` value already ending in `/v1` no longer doubles into a 404.
- Add `Agent#run_loop(transport:)` — switch models mid-conversation; history and callbacks carry over, and the swap emits `Event::ModelSwitched` followed by a fresh `Event::ContextCap`.
- Add `Agent::ExtensionContext` — the runtime capability facade (`emit_event`, `add_raw_tool`, `sub_agent_listeners`, `on_close`) handed to `Extension#bind`, so holding an `Agent` grants read-only config access; gems emit their own domain events, `Tasks::ListChanged` being the worked example.
- Add `Control::StepLimit.new(max:, on_exhausted:)` — `:raise` (default) or `:synthesize`, where the synth runs as a nested tools-free `Agent`; Q&A bins opt into `:synthesize`, `bin/pikuri-code` keeps `:raise`, and sub-agents are always `:synthesize`.
- Add `Pikuri::Sanitizer` — one chrome-independent primitive that neutralizes control bytes, bidi and zero-width characters and flags mixed-script tokens, reporting each finding as a `Warning` for the chrome to render.
- Add `TokenLog#on_status_line` — push the context-window status line to a host UI (SSE, websocket, TUI) instead of polling `#status_line`, with the agent id passed so one observer covers sub-agents.
- Add `~/.pikuri-examples-config.yaml` — the example bins read `llm_server` / `llm_model` / `llm_api_key` and the search-provider keys from there, while the prompt and security toggles stay on the command line.
- Add `Tool::Parameters#required_string_array` for native JSON-array-of-strings parameters.
- Add `Mcp::Registry::StdioEntry#env` — the per-child credential channel for stdio MCP servers.
- Add `bin/pikuri-code --readable` / `--writable` for extra workspace roots.
- Fix `Code::Bash` handing its child a Bundler-polluted environment (`Bundler.unbundled_env` now), which made a `bundle exec` the agent ran in another project resolve against pikuri's own Gemfile.
- Fix the bubblewrap toolchain overlay being read-only — every readable toolchain dir (plus `~/.gem`) is now overlaid read-write, so an install inside the sandbox works.
- **Breaking:** `Workspace::Confirmer#confirm?(prompt:)` → `#confirm?(request:)` taking a `Confirmer::Request`, with color, the `(y/n)` cue and byte escaping moving into `Confirmer::Terminal`. Move any presentation out of your tool code.
- **Breaking:** `Tool::WEB_SEARCH` → `Tool::WebSearch.build(brave_key:, exa_key:)`, and the `Brave::ENV_KEY` / `Exa::ENV_KEY` `ENV` defaults are gone. Pass provider keys from your own config; pikuri reads none from the environment.
- **Breaking:** `--server` / `--model` / `--api-key-env` are dropped from every example bin. Move those values into the config file.
- **Breaking:** context-window detection drops the ruby_llm registry source in favour of the `/props` probe or an honest `nil`, and the `llama_probe_url` plumbing leaves `Agent.new` and the bins. See `DECISIONS.md` `D-context-window-sources`.
- **Breaking:** `Agent.think` moves to `Mcp::Thinker`, `Agent`'s chat-wiring statics become private, and `ListenerList#with` is removed. Update the constants.
- **Breaking:** `Workspace`'s `CACHE_BASE` → `Paths.cache`. Use the shared resolver.
- **Breaking (behavior):** `task_create` takes a JSON array of items, and `task_in_progress` / `task_completed` / `task_delete` address tasks by the numeric `id` shown in every render instead of by content.

## [0.0.6] - 2026-06-04

Format→text conversion collapses into one registry, `Pikuri::Extractor`,
and the two heavyweight arms leave core as their own gems.

- Add `Pikuri::Extractor` — one registry with `.extract` (whole document) and `.extract_paged` (line-windowed `Page`) behind the web tools, the file tools and the indexer, so a new format is a registry entry a gem inserts rather than a new dispatcher arm.
- Add `pikuri-extractors` — DOCX / ODT / XLSX / PPTX / EPUB / RTF / PDF → Markdown via pandoc, markitdown and `pdftotext` in a one-shot networkless docker container (`--network=none --read-only --cap-drop=ALL`, bytes over stdin), with host CLIs as the docker-less fallback and an explicit `DOCUMENTS.register` to arm it.
- Add `pikuri-pdf` — the in-process, lazily-paged pdf-reader extractor as an opt-in sibling, so pdf-reader and its five transitive deps leave core's audit tree; pick one PDF arm per host.
- Add `Subprocess.run` — the filter shape for stdin→stdout children (stdin fed, child stdout redirected to a caller-supplied file, stderr captured), with the same process-group discipline as `.spawn`.
- Add a hand-rolled recursive-descent parser to `Tool::Calculator` — Python 3 expression syntax natively (`//` floors, `**` is right-associative and binds tighter than unary minus), dropping dentaku, concurrent-ruby, bigdecimal and the `tsort` pin from core's closure.
- PDF page markers (`--- Page N ---`) now appear in `web_scrape` output and vectordb chunks too, and a `%PDF-` magic sniff beats a lying `Content-Type`.
- Big documents stream from source io straight to the converter's stdin, so they stay off the Ruby heap.
- **Breaking:** `tty-markdown` is gone and `Listener::Terminal` prints assistant Markdown raw in both modes. Render Markdown in your own host if you want it.
- **Breaking:** `Tool::Scraper::Simple` flattens into `Tool::Scraper`. Update the constant.
- **Breaking (behavior):** whole-valued calculator results render as `2` rather than `2.0`, and complex results or float overflow come back as `Error: …` observations.

## [0.0.5] - 2026-06-04

- Add `pikuri-memory` — durable cross-conversation memory over mem0: the `recall` tool, per-turn prefetch and capture, a self-managed mem0 + Qdrant sidecar (`Mem0Server`) and `bin/pikuri-memory`. See `book/memories.md`.
- Add `Agent::Extension#on_user_message` — the per-turn hook memory prefetch rides.
- Add `Event::SystemInjected` — extension-injected `:system` blocks are visible on the listener stream instead of appearing from nowhere.
- Add `Pikuri::Finalizers` — one process-global teardown registry behind a single `at_exit`, with `Agent`, `Subprocess` and the container supervisors routed through it.
- Add `Pikuri::Paths` — the shared XDG-aware cache/temp resolver gems use instead of reading `ENV['XDG_CACHE_HOME']` themselves.
- Add incremental reindex plus a `Watcher` daemon to pikuri-vectordb, exposed as `bin/pikuri-corpus --watch`; symlinks are never indexed, and the `Extension` no longer auto-indexes (reindex is host-driven).
- Add `Backend::Qdrant` + `Server::Qdrant` — the recommended persistent backend (`bin/pikuri-corpus --qdrant`) alongside `--chroma`, with the survey behind the call in `pikuri-vectordb/DESIGN.md`.
- Add `Server::InMemory` — the null supervisor that completes the `Backend::X` ↔ `Server::X` pair set, so a host wires all three engines the same way.
- Add `vectordb_read` — parent-document retrieval: read one indexed document in full by the `source` a search cited, gated to sources the `Indexer` actually produced.
- Add `FileType.read_as_text_paged` — the lazy, line-windowed extraction `Workspace::Read` and `vectordb_read` now share.
- Add `bin/pikuri-openlibrary` — the one-MCP demo (Open Library) in pikuri-mcp.
- Add `Control::Interloper#size` so a host can show how many messages are queued.
- Follow a llama.cpp router when probing the context window, so a routed local server reports its real cap.
- Add Woodpecker CI running `rake test` on push, PR and manual trigger.
- **Breaking:** `VectorDb::{Search,Read,Reindex}` → `VectorDb::Tools::*`, and `ChromaServer` / `QdrantServer` → `VectorDb::Server::{Chroma,Qdrant}`. Update the constants; the `vectordb_*` tool names are unchanged.
- **Breaking:** `bin/pikuri-librarian` is renamed `bin/pikuri-corpus`. Update any script or alias.

## [0.0.4] - 2026-05-29

Three gems join the family — `pikuri-vectordb` (local-corpus retrieval),
`pikuri-subagents` (persona-driven delegation) and `pikuri-tasks` (a task
list the agent keeps) — and the bash tool finally gets a sandbox.

- Add `pikuri-vectordb` — local-corpus vector search: `vectordb_search` / `vectordb_reindex`, a swappable `Backend` (`InMemory`, `Chroma`) with a `ChromaServer` supervisor, embedder / reranker / chunker / tokenizer pieces, the `LIBRARIAN` persona and `bin/pikuri-librarian`. See `book/vectordb.md`.
- Add `pikuri-subagents` — the sub-agent feature moves out of core into its own gem, pivoting to a persona-driven `agent` tool with a `Persona` record, bundled `RESEARCHER` / `FILE_MINER` and `bin/pikuri-minions`.
- Add `pikuri-tasks` — an in-memory per-agent task list plus `task_create` / `task_in_progress` / `task_completed` / `task_delete`, wired into `bin/pikuri-code` by default. See `book/tasks.md`.
- Add `Code::Bash::Sandbox` — the bash subprocess runs under bubblewrap (`Sandbox::Bubblewrap`; default `NONE`) with a per-session toolchain overlay, a container-socket denylist and `/tmp` persisted across calls, and `--no-sandbox` / `--no-confirm` opt out per layer.
- Add `Workspace::Filesystem::AllowAll` — the dev-container variant accepting any path outside a hardcoded credential denylist (`~/.ssh`, `~/.aws`, `~/.gnupg`, `/etc/shadow`, …), activated together with `Sandbox::NONE` by `bin/pikuri-code --yolo`.
- Add multi-root containment to `Workspace::Filesystem` — extra readable and writable roots beyond the project root, plus an optional ephemeral temp playground cleaned up at exit.
- Add `Workspace::ProjectRoot` — climbs cwd to the nearest `.git` / `.hg` / `.svn` ancestor, so the file tools anchor on the repo rather than wherever the shell sat.
- Add `Pikuri::FileType` — magic-byte sniffing in one module (`detect_mime`, `binary?`, `read_as_text`), with `Workspace::Read` gaining page-by-page PDF text extraction and PNG / JPEG / GIF / WebP attached as image observations.
- Add `Configurator#add_sub_agent_tool` — a tool registered for personas but never sent to the parent's LLM; `bin/pikuri-code` puts `web_search` / `web_scrape` / `fetch` in that pool.
- Add `Code::GitRepoResearcher` + `Code::GitClone` and `Persona#needs_temp_workspace` — a persona that clones a repo into a minted throwaway workspace and reads it there.
- Add `Workspace::Filesystem#env` — the host's git identity, resolved lazily and overridable, threaded into the sandbox through the new `Subprocess.spawn(env:)`.
- Add `Tool::Parameters#required_enum` / `#optional_enum` for closed-choice string parameters.
- Add `--api-key-env` to `bin/pikuri-chat` / `pikuri-code` / `pikuri-assistant`, so the key comes from a named environment variable instead of a hardcoded default.
- Add the guide (`docs/guide/`) as the home for concepts, slimming the README to a front door and retiring `GETTING_STARTED.md`.
- **Breaking:** `Tool::{Workspace,Confirmer,Read,Write,Edit,Grep,Glob}` → `Pikuri::Workspace::*`, with `Tool::Workspace` renamed `Workspace::Filesystem`. Update the constants; the file tools still subclass `Pikuri::Tool`.
- **Breaking:** `Tool::Bash` → `Code::Bash` and `Tool::CodingPaths` → `Code::ToolchainPaths`. Update the constants.
- **Breaking:** `Workspace::Filesystem` is a single concrete class taking `project_root:` / `readable:` / `writable:` / `temp:` — the abstract base, the bundled `Cwd` subclass and the `anchor:` kwarg are gone. Construct it directly, or subclass it for a different containment policy.
- **Breaking:** `Tool::SubAgent` becomes the persona-driven `agent` tool in `pikuri-subagents`, and core carries no sub-agent surface at all. Depend on the gem and pass `Persona`s.
- **Breaking:** `Agent#name` → `Agent#id`. Rename the reader.
- **Breaking:** `Skill::Catalog::Bundled` collapses into a `search_bases:` kwarg on `Skill::Catalog`. Pass the bases instead of using the subclass.
- **Breaking:** `Sandbox::Bubblewrap.new` refuses a workspace that lists `/` as writable. Pair `Filesystem::AllowAll` with `Sandbox::NONE`, not with the sandbox.

## [0.0.3] - 2026-05-22

Pikuri now ships as seven sibling gems under a Rails-shape monorepo
instead of one: the minimal core is `pikuri-core`, and everything else is
an opt-in extension gem. The convenience metagem `pikuri` depends on
every sibling, so a privacy-conscious user can instead install
`pikuri-core` and add gems à la carte.

- Add the seven-gem monorepo — `pikuri-core`, `pikuri-skills`, `pikuri-mcp`, `pikuri-workspace`, `pikuri-code`, `pikuri-assistant` and the `pikuri` metagem, each with its own `lib/` / `spec/` / gemspec / README, fanned out by the top-level `Rakefile`.
- Add the Configurator + Extension protocol — `Agent.new` yields an `Agent::Configurator` (`add_tool` / `add_listener` / `append_system_prompt` / `add_extension` / `allow_sub_agent` / `on_close`), and `Agent::Extension` (`configure` + `bind`) is the duck type extension gems implement.
- Add MCP support in `pikuri-mcp` — `Mcp::Registry` (stdio + HTTP), `Mcp::Servers`, `Mcp::Extension`, `Mcp::Synthesizer` (LLM-filled server descriptions, cached on disk), `Mcp::Verifier` (pre-flight injection check across every text field) and `Mcp::ClientWrapper` (restart-on-stdio-death), with `bin/pikuri-assistant` as the demo.
- Add opt-in streaming — `Agent.new(streaming: true)` emits `Event::ThinkingDelta` / `Event::AssistantDelta` per chunk and propagates through the synthesizer and sub-agents, with `Listener::RateLimited` coalescing the flood to an fps cap.
- Add `Control::Cancellable` and `Control::Interloper` — Ctrl+C cancels between tool calls and inside the streaming block without leaving the loop half-done, and a host can push a user message mid-loop.
- Add the Workspace + Confirmer seams in `pikuri-workspace` — `Tool::Workspace` (plus a bundled `Cwd` rejecting `..`-escapes and out-of-root symlinks) and `Tool::Confirmer` (plus `TERMINAL` and `AUTO_APPROVE`), taken by all five file tools through the constructor.
- Add `Agent::Synthesizer` — one last tools-free call to summarize what the agent knows when it hits `max_steps` mid-task.
- Add `Agent::ContextWindowDetector` — resolves the model's context cap (override → ruby_llm registry → llama.cpp `/props`) at construction and emits `Event::ContextCap`.
- Add `Agent::ChatTransport` — the `model` / `provider` / `assume_model_exists` bundle passed to every `RubyLLM.chat` an agent or sub-agent starts.
- Add `Agent#close` and the `Agent.open` block form — extensions register `on_close` on the Configurator, and closing the parent fans out to every handler.
- Add `Subprocess.spawn` — the single spawn chokepoint for every `pikuri-*` `lib/`, forcing a process group per invocation and SIGTERMing tracked groups at exit, with `Mcp::ClientWrapper` as the documented exception.
- Add `Agent::Event::*` — one event stream (`UserTurn` / `Thinking` / `Assistant` / `ToolCall` / `ToolResult` / `Tokens` / `ContextCap` / `FallbackNotice` / `Cancelled` and the delta variants) consumed by pure-consumer listeners (`Base`, `Terminal`, `InMemoryEventList`, `TokenLog`, `RateLimited`), plus `TokenLog#status_line`.
- Add `--server` and `--model` to `bin/pikuri-chat` and `bin/pikuri-code` for overriding the local llama.cpp defaults from the CLI.
- `pikuri-core`'s runtime deps are tightened to what the core actually uses — the `mcp` gem moves to `pikuri-mcp`.
- `0.0.2` was an internal version bumped during the monorepo split and never released; it is skipped intentionally.
- **Breaking:** `Agent.new`'s `tools:` / `listeners:` / `extensions:` kwargs are gone. Wire everything through the Configurator block.
- **Breaking:** `Tool::SkillCatalog` → `Skill::Catalog` and `Tool::Skill` → `Skill::SkillTool`, both moving into the new `pikuri-skills` gem. Update the constants; the LLM-facing tool name stays `skill`.
- **Breaking:** `Listener::InMemoryMessageList` → `Listener::InMemoryEventList`, and a listener now overrides a single `on_event(event)`. Move message-specific handling into the event `case`.
- **Breaking:** `Pikuri::PROMPTS_DIR` → the cooperative `Pikuri::PROMPT_DIRS`, to which each gem appends its own `prompts/` at boot. Read prompts through `Pikuri.prompt(name)`, which searches all loaded gems.
- **Breaking:** the root `pikuri.gemspec` is replaced by per-gem gemspecs. Depend on `pikuri-core` or on the `pikuri` metagem.

## [0.0.1] - 2026-05-14

The first packaged release. Pikuri ships as a **library** — `gem install
pikuri` installs no executables, and the `bin/pikuri-*` scripts in the
source tree are dev/demo entry points; production binaries live in
downstream gems.

- Add `pikuri.gemspec` with the runtime deps pulled from the previous `Gemfile` (now `gemspec`-driven), the `Pikuri::VERSION` constant, and an MIT `LICENSE` with matching gemspec metadata.
- Add `Pikuri::PROMPTS_DIR` and `Pikuri.prompt(name)` so a downstream host can read pikuri's bundled system prompts as a starting point for its own wiring.
- Add `Tool::SkillCatalog` + `Tool::Skill` — pikuri's [Agent Skills](https://agentskills.io/specification) implementation over `.pikuri/skills`, `.claude/skills` and `.agents/skills` in that precedence, auto-registered when the catalog is non-empty and appended to the system prompt so the inventory costs no round-trip.
- Add a construction-time warning to `Tool::Bash`: it runs commands unsandboxed under pikuri's UID, so it can read `~/.ssh` and cloud credentials.
- Add `mise.toml` pinning Ruby 3.3, matching the gemspec floor, and this `CHANGELOG.md`.
- `UrlCache::ROOT_DIR` follows the XDG spec (`$XDG_CACHE_HOME/pikuri/url_cache`, else `~/.cache/pikuri/url_cache`) instead of `/tmp/pikuri/cache`, and `bin/pikuri-chat` / `bin/pikuri-code` read prompts via `Pikuri.prompt(name)` rather than hand-rolled `__dir__` arithmetic.
- **Breaking:** top-level `Agent`, `Tool` and `UrlCache` are now `Pikuri::Agent`, `Pikuri::Tool` and `Pikuri::UrlCache`, with every bundled tool, listener and helper under `Pikuri::*` in standard gem layout. Prefix the constants.
- **Breaking:** `Listener::InMemoryList` → `Listener::InMemoryMessageList`. Rename the constant.
