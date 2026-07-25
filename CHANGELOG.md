# Changelog

All notable changes to pikuri are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
uses semver as documented in `lib/pikuri/version.rb`.

## [Unreleased]

### Added

- **New gem: `pikuri-pdf` — PDF text extraction, split out of
  pikuri-core.** `Pikuri::Extractors::PDF` is the same in-process,
  lazily-paged pdf-reader extractor core used to bundle, now an
  opt-in sibling: pdf-reader and its five transitive deps (Ascii85,
  afm, hashery, ruby-rc4, ttfunk) leave the core audit tree, and
  pikuri-core's registry ships only HTML + Passthrough. Registration
  is an explicit `Extractors::PDF.register` — requiring the gem
  changes nothing by itself — and *front*-inserts so the `%PDF-`
  magic sniff keeps beating HTML's content-type match under lying
  headers. Wired by `bin/pikuri-corpus` (PDF corpora, no docker
  needed); deliberately NOT by `bin/pikuri-chat`, which stays pure
  pikuri-core (guide ch1) — scraping a PDF there now surfaces
  `Error: ...` until ch3 plugs the extractor in. Pick-one-per-wiring
  with pikuri-extractors' new PDF arm: `bin/pikuri-assistant`
  registers `DOCUMENTS` instead, superseding this gem in the ch13
  shape (untrusted documents on an egress-capable agent parse in the
  sandbox); this gem is the no-infrastructure wiring with lazy
  paging and PDF-specific Read-tool wording.
- **New gem: `pikuri-extractors` — sandboxed office-document
  extraction.** `Pikuri::Extractors::DOCUMENTS` plugs DOCX / ODT /
  XLSX / legacy XLS / PPTX / EPUB / RTF → Markdown into the
  `Pikuri::Extractor` registry, so `read`, `web_scrape` / `fetch`,
  and the vectordb indexer pick the formats up for free. Conversion
  is pandoc (ODF / RTF / EPUB / DOCX) or markitdown (the OOXML
  spreadsheet / presentation arms), run preferably as a one-shot
  **networkless, locally-built docker container** (`--network=none
  --read-only --cap-drop=ALL`, bytes via stdin, Markdown via stdout,
  no volume mounts — untrusted parser input never touches the host
  filesystem or network; versions pinned in the shipped Dockerfile),
  with host pandoc / markitdown CLIs as the docker-less fallback.
  Registration is an explicit `DOCUMENTS.register` call — requiring
  the gem changes nothing by itself. No result cache in v1: each
  paged read re-runs the conversion (accepted trade). ODS / ODP,
  image OCR, audio, and LibreOffice-headless are deliberately out of
  scope.
- **pikuri-extractors grows a PDF arm** — poppler's `pdftotext` in
  the converter image (and as a `pdftotext` host-CLI fallback;
  probed with `-v`, since poppler parses `--version` as a filename),
  with a Ruby post-processing pass that rebuilds pikuri-pdf's
  `--- Page N ---` markers from pdftotext's `\f` page separators —
  textless pages skipped, numbering preserved, so vectordb page
  provenance and Read-tool citations are wiring-independent. Makes
  `DOCUMENTS` a one-registration superset of pikuri-pdf's formats:
  pick one PDF extractor per host (trade-off table in the
  `Extractors::Documents` yardoc). One ordering edge vs pikuri-pdf:
  a PDF served under a lying `text/html` header goes to the HTML
  extractor (DOCUMENTS sits after HTML; pikuri-pdf front-inserts and
  wins that case).
- **`Pikuri::Subprocess.run` — the filter shape.** Second front door
  on the subprocess chokepoint for stdin→stdout children (the
  document converters): feeds `stdin_data`, redirects the child's
  stdout straight to a caller-supplied file (which is also what
  makes the pumping deadlock-free with a single writer thread),
  captures stderr separately as `Result#output`. Same process-group
  discipline and exit-sweep registration as `.spawn`.
- **`Pikuri::VectorDb::Server::InMemory` — the null supervisor.**
  In-process implementation of the Server protocol
  (`.ensure_running` / `#client(collection:)` / `#close`) the docker
  supervisors implement over containers: `client` memoizes one
  `Backend::InMemory` per collection name, `close` empties every
  store (outstanding clients go empty, mirroring a removed
  container), `ensure_running!` is a no-op. Every engine now has a
  `Backend::X` ↔ `Server::X` pair, so hosts wire all three the same
  way — `bin/pikuri-corpus` does exactly that: pick a Server class,
  `ensure_running.client(...)`, explicit `server.close` at teardown
  (with `Pikuri::Finalizers` backstopping the docker case).
- **`bin/pikuri-corpus --qdrant`.** Persist the index in a
  self-managed Qdrant container — the recommended persistent
  backend, alongside the existing `--chroma`. Passing both flags is
  rejected loudly.
- **Qdrant backend (`Pikuri::VectorDb::Backend::Qdrant` +
  `Pikuri::VectorDb::Server::Qdrant`).** The recommended persistent
  backend — `pikuri-vectordb/DESIGN.md` records the Chroma-vs-Qdrant
  survey behind the call. Same duck-typed `Backend` protocol and the
  same supervisor shape as the Chroma pair; chunk ids map to
  deterministic SHA1-derived point UUIDs (Qdrant rejects string ids),
  scores pass through unconverted (Qdrant's cosine score is already a
  similarity), and the boot manifest pages by the server-side scroll
  cursor. `Server::Qdrant::IMAGE` is pinned to the same tag as
  `Mem0Server::DEFAULT_QDRANT_IMAGE` (spec-enforced lockstep, one
  image on disk for hosts running both stacks). Chroma stays
  supported; `Backend::InMemory` stays the educational default.
- **`vectordb_read` tool (`Pikuri::VectorDb::Tools::Read`).** Parent-document
  retrieval: read one indexed document in full by the `source` path
  `vectordb_search` cited, instead of re-querying for more fragments
  of the same document. The `source` must be a path the `Indexer`
  actually produced (verified against `Backend#sources_with_hashes`),
  so the read domain is exactly the search domain — not an
  arbitrary-file reader. Line-windowed via the new shared
  `FileType.read_as_text_paged` (below). Reading is inbound-only, so it
  adds no egress leg: the `bin/pikuri-corpus` agent stays leak-proof
  and the `LIBRARIAN` sub-agent's privilege separation is intact.
  Auto-registered by `VectorDb::Extension` alongside `vectordb_search`
  / `vectordb_reindex`, and added to `LIBRARIAN`'s toolset.
- **`Pikuri::FileType.read_as_text_paged`.** Lazy, line-windowed
  text/PDF extraction returning a `FileType::Page` value
  (offset/limit/byte-cap, per-line truncation, `--- Page N ---` markers
  on PDFs). Extracted from `Workspace::Read`'s windowing loops so it is
  shared with `VectorDb::Tools::Read`; each tool keeps its own presentation
  (cat-n numbering and trailer wording vs. plain + source citation).
  Same refusal contract as `read_as_text` (raises on
  image/binary/missing/malformed-PDF).

### Changed

- **`Agent#run_loop` no longer silently no-ops a blank turn against a
  `:system`-only conversation — it's provider-aware.** A blank
  `user_message` whose conversation holds only `:system` messages (a fresh
  chat, or a skill-only bare-load via `Skill::Extension#schedule_load_skill`)
  used to `return false` for every provider. Now it splits on the resolved
  `@chat.model.provider`: providers that keep `:system` inside the messages
  array (OpenAI, Gemini) complete the turn against the `:system`-only history,
  so a host-loaded skill gets its chance to act; providers that hoist every
  `:system` block into a separate top-level field (Anthropic, Bedrock —
  `Agent::SYSTEM_HOISTING_PROVIDERS`) would send an empty `messages` array and
  400, so `run_loop` raises the new `Pikuri::Agent::EmptyTurnError` (carrying
  the offending `provider`) instead. The error is fail-loud by design (a
  silent `false` reproduced the very 400 it meant to prevent) and
  content-neutral (the host owns any skill-flavored wording). No existing
  caller consumes the old `false` return — `thinker` / `synthesizer` /
  `sub_agent_tool` / the bin REPLs all pass a real `user_message`.
- **`calculator` evaluates Python expression syntax natively** via a
  hand-rolled recursive-descent parser in `Pikuri::Tool::Calculator`,
  replacing dentaku. Drops four gems from pikuri-core's dependency
  closure — dentaku, concurrent-ruby (~16k lines, the heaviest audit
  item in the whole tree), bigdecimal, and the `tsort` workaround
  pin — and retires the `**` → `^` preprocessing step. The grammar
  follows Python 3 exactly: `/` is true division, `//` (new) floors,
  `**` is right-associative and binds tighter than unary minus
  (`-2**2` is -4), `2**-1` is 0.5. Output formatting tightens
  slightly: whole-valued decimal results render as `2` rather than
  `2.0`; complex results (`(-4)**0.5`) and float overflow come back
  as `Error: ...` observations.
- **`Workspace::Read` delegates windowing to
  `FileType.read_as_text_paged`** instead of its own
  `format_slice`/`format_pdf`. Behavior is unchanged except that a
  malformed-PDF error now quotes the resolved path (matching
  `read_as_text`'s existing contract) rather than the relative path.
  The `DEFAULT_LIMIT` / `MAX_LINE_LENGTH` / `MAX_BYTES` /
  `LINE_TRUNCATION_MARKER` constants now alias the `FileType::PAGE_*`
  ones (single source of truth).
- **`Pikuri::Workspace::Filesystem::AllowAll`.** Unrestricted variant
  of `Filesystem` for dev-container / Docker mode where the container
  is the security boundary. Same accessor surface as the base class,
  but `resolve_for_read` / `resolve_for_write` accept any path *except*
  those under a hardcoded credential denylist (`~/.ssh`, `~/.aws`,
  `~/.gnupg`, `~/.docker`, `~/.kube`, `~/.netrc`, `/etc/shadow`, plus
  `/root` variants). Pairs with `--yolo` + `Sandbox::NONE` inside a
  container; combining with `Sandbox::Bubblewrap` defeats the sandbox
  (and bash inside Bubblewrap bypasses the denylist anyway).
- **`bin/pikuri-code --yolo` now activates `Filesystem::AllowAll`** in
  addition to disabling the Bubblewrap sandbox and Confirmer prompts.
  Help text and startup banner updated accordingly. `--no-sandbox` and
  `--no-confirm` continue to act on their individual layers only —
  `--yolo` is now the dedicated "I'm inside a container, just let it
  rip" shorthand.
- **`Code::Bash::Sandbox::Bubblewrap.new` refuses construction when
  the supplied workspace lists `/` as writable** (typically
  `Filesystem::AllowAll`). Bubblewrap exists for filesystem
  containment, which is structurally meaningless when the entire
  filesystem is the workspace; the host gets a clear error pointing
  at `Sandbox::NONE`. Pure defense-in-depth — `pikuri-code --yolo`
  already wires `Sandbox::NONE` alongside `AllowAll`, so this check
  only fires for hosts that compose the pieces directly.

### Changed

- **pikuri-vectordb's tools and supervisors moved into `Tools::` /
  `Server::` namespaces.** `Pikuri::VectorDb::{Search,Read,Reindex}` →
  `Pikuri::VectorDb::Tools::{Search,Read,Reindex}` — the gem's
  `tools/` directory is now its whole LLM-facing surface, visibly
  separate from the indexing plumbing. `Pikuri::VectorDb::ChromaServer`
  → `Pikuri::VectorDb::Server::Chroma` and `…::QdrantServer` →
  `…::Server::Qdrant` — supervisors now pair with their backends by
  name (`Backend::Qdrant` ↔ `Server::Qdrant`). Tool string names
  (`vectordb_search` / `vectordb_read` / `vectordb_reindex`) are
  unchanged. `Reranker::LlamaServer` / `Tokenizer::LlamaServer` stay
  put — they are HTTP clients, not supervisors.
- **pikuri-workspace classes moved to the `Pikuri::Workspace::*`
  namespace.** `Pikuri::Tool::Workspace` → `Pikuri::Workspace::Filesystem`
  (renamed too — `Workspace::Workspace` stutter avoided);
  `Pikuri::Tool::{Confirmer,Read,Write,Edit,Grep,Glob}` →
  `Pikuri::Workspace::{Confirmer,Read,Write,Edit,Grep,Glob}`. The
  Zeitwerk loader now mounts plainly at the gem's `lib/` root
  (dropping the `namespace: Pikuri::Tool` workaround). The file
  tools still subclass `Pikuri::Tool`; only their declared
  namespace changed.
- **pikuri-code's `Bash` tool moved to the `Pikuri::Code::*`
  namespace.** `Pikuri::Tool::Bash` → `Pikuri::Code::Bash`;
  `Pikuri::Tool::Bash::Sandbox::{NONE,Bubblewrap}` →
  `Pikuri::Code::Bash::Sandbox::{NONE,Bubblewrap}`. The dual
  Zeitwerk loader collapses into one rooted plainly at the gem's
  `lib/` root, alongside the existing `Pikuri::Code::ToolchainPaths`.
  `Bash` still subclasses `Pikuri::Tool`; only its declared
  namespace changed.
- **`Pikuri::Workspace::Filesystem` is a single concrete class.**
  The earlier abstract base + bundled `Cwd` subclass collapsed
  into one class parameterized by explicit `anchor:` /
  `readable: []` / `writable: []` / `temp: false` keyword args.
  Multi-root containment (extra read-only and writable roots
  beyond the anchor) and an optional ephemeral `Dir.mktmpdir`
  playground (cleaned up via `at_exit`) are built in. Hosts that
  need a different containment policy subclass `Filesystem`
  directly.

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
