# Research — the agent-harness field: ruby_llm, langchainrb, pi, opencode, grok-build, hermes-agent and Claude Code

What the things we don't own actually do — how six OSS agent-or-agent-adjacent projects, plus
Claude Code as a black box, solve the problems pikuri solves. About *them*, never us: a sentence
starting "we chose" is a `D_`. One claim per bullet, one provenance marker per claim —
**[docs]**, **[src]**, **[verified &lt;date&gt;, &lt;version&gt;]**, **[unverified]** (a hypothesis;
a design built on it says so). Every **[src]** resolves through `R_sources`, which names the tree
and the revision each entry was read against; a claim read at a different revision names it
itself. A claim is earned by its provenance, or by having cost real work to find out. Cite by
slug, `R_<slug>`, never by position; `grep '^## R_' design/research.md` is the index. The first
entry is the ruler: later ones trim to its length. When you have written an entry, re-read it
against the one above and cut what the provenance markers already carry.

Two things in here are deliberately not claims about them, and carry no marker: the **pikuri**
column of a comparison table, and the **Takeaway** paragraph that closes most entries. They are
what the survey was *for*. Anything that grows past a paragraph of argument about pikuri has
become a `D_` and should move.

---

## R_sources — Which tree each entry was read against, and at which revision

Every **[src]** in this file resolves here. A claim read against a different revision names that
revision at the claim.

- ruby_llm: `/tmp/agent-comparison/ruby_llm` — `lib/ruby_llm/chat.rb`,
  `lib/ruby_llm/tool.rb`, `lib/ruby_llm/message.rb`
- langchainrb: `/tmp/langchainrb` — `lib/langchain/assistant.rb`,
  `lib/langchain/tool_definition.rb`, `lib/langchain/tool/*.rb`,
  `lib/langchain/llm/`, `lib/langchain/vectorsearch/`, `README.md`
- pi: `/tmp/agent-comparison/pi` — `packages/agent/src/agent-loop.ts`,
  `packages/agent/src/types.ts`, `packages/coding-agent/src/core/tools/`
- opencode: `/tmp/agent-comparison/opencode` — `packages/opencode/src/session/processor.ts`,
  `packages/opencode/src/tool/`, `packages/opencode/src/permission/index.ts`,
  `packages/opencode/src/provider/provider.ts`
- grok-build: shallow clone at `SOURCE_REV` `84ae1223` (August 2026) —
  `crates/codegen/xai-grok-tools/src/{registry/types.rs,tool_taxonomy.rs,normalization.rs,util/unicode_confusables.rs}`,
  `crates/codegen/xai-grok-tools/src/implementations/{grok_build,grok_build_concise,grok_build_hashline,codex,opencode,search_tool,use_tool,memory}/`,
  `crates/codegen/xai-grok-agent/src/{config.rs,compaction.rs,system_reminder.rs}`,
  `crates/codegen/xai-grok-sandbox/src/{lib.rs,profiles.rs,child_net.rs}`,
  `crates/codegen/xai-grok-shell/src/{agent/folder_trust.rs,session/goal_tracker.rs}`,
  `crates/common/xai-tool-types/src/task.rs`, and the user guide under
  `crates/codegen/xai-grok-pager/docs/user-guide/` (permissions, sandbox,
  skills, memory, subagents). `R_skills`' *How grok-build's conditional
  activation actually works* was read later, against `main` at
  `5163763` — `crates/codegen/xai-grok-tools/src/{types/skill_discovery_tracker/{conditional,listing,mod}.rs,implementations/skills/discovery.rs,reminders/skill_discovery.rs}`
  and `crates/codegen/xai-grok-agent/src/prompt/skills.rs`

`R_persistence` (August 2026) was read against newer revisions, since the earlier paths had
moved:

- opencode at `5f5ea53` — `packages/schema/src/v1/session.ts`,
  `packages/core/src/session/sql.ts`, `packages/core/src/database/migration/`,
  `packages/opencode/src/session/{message-v2,processor,prompt,revert}.ts`,
  `packages/opencode/src/storage/storage.ts`,
  `packages/opencode/src/cli/cmd/{import,export}.ts`
- grok-build at `9684fa3` — `crates/codegen/xai-grok-shell/src/session/`
  (`persistence.rs`, `storage/mod.rs`, `storage/jsonl/mod.rs`,
  `helpers/replay.rs`, `compaction.rs`, `export.rs`, `image_normalize.rs`,
  `goal_tracker.rs`), `crates/codegen/xai-grok-shell/src/extensions/notification.rs`,
  `crates/codegen/xai-grok-sampling-types/src/conversation.rs`,
  `crates/codegen/xai-grok-workspace/src/trust.rs`
- pi at `1defa15` — `packages/coding-agent/src/core/session-manager.ts`,
  `packages/ai/src/types.ts`, and the unshipped rewrite under
  `packages/agent/src/harness/session/` + `packages/agent/docs/harness.md`
- hermes-agent at `cced6fa` — `hermes_state_common.py`, `hermes_state.py`,
  `hermes_state_schema.py`, `agent/agent_runtime_helpers.py`,
  `agent/memory_manager.py`, `tools/memory_tool.py`
- Claude Code — no source available; read from its own transcripts on the
  author's machine (`~/.claude/projects/**/*.jsonl`, ~370 files, CLI
  `2.1.220`–`2.1.247`) plus `~/.claude/file-history/`. One claim
  (compaction record shape) rests on strings extracted from the shipped
  binary rather than an observed record, and is marked **[unverified]**
  where it appears. **[verified 2026-08, CLI 2.1.220–2.1.247]**

`R_subscription_transport` (September 2026) has no clone behind it; it was read from shipped docs:

- hermes-agent's Claude-subscription provider — hermes-agent PRs `#117451` (the core seams,
  merged 2026-09-20) and `#117622` (the catalog entry), the standalone plugin repo
  `NousResearch/hermes-plugin-claude-subscription-directsdk` at catalog pin `f1c1220`, and
  Anthropic's own help article on the Agent SDK and Claude plans. Read 2026-09-22; nothing in
  the entry was run here, so every claim is **[docs]**.

## R_project_scopes — What each project in the field is, and how big its loop is

The set spans very different scopes; nothing about anyone's size is a target.

| Project | Language | Scope | Loop size | Key abstraction |
| --- | --- | --- | --- | --- |
| **pikuri** (this repo) | Ruby on top of ruby_llm | small general-purpose CLI agent + in-repo coding agent + MCP-enabled assistant | listeners + controls on top of `RubyLLM::Chat#complete` (~1.2k lines of `agent.rb`, yardoc included) | `Tool` factory (synthetic `RubyLLM::Tool` subclass) + `Tool::Parameters` strict validator + sealed `Agent::Event` value hierarchy |
| **ruby_llm** ([crmne/ruby_llm](https://github.com/crmne/ruby_llm)) | Ruby | multi-provider SDK + Rails integration | ~37 lines across `Chat#complete` + `Chat#handle_tool_calls` | `RubyLLM::Tool` subclass + provider adapters |
| **langchainrb** ([patterns-ai-core/langchainrb](https://github.com/patterns-ai-core/langchainrb)) | Ruby | LLM-app framework: RAG/vector search + Assistant + multi-provider | ~421 lines (`assistant.rb`) state machine: `:ready` → `:in_progress` → `:requires_action` → `:completed` | `Langchain::Assistant` + class-level `ToolDefinition` DSL + per-provider `LLM::Adapter` |
| **pi** ([earendil-works/pi](https://github.com/earendil-works/pi)) | TypeScript | extensible coding-agent harness | ~700 lines (`agent-loop.ts`) | Typebox-typed tools + extensions/skills |
| **opencode** ([sst/opencode](https://github.com/sst/opencode)) | TypeScript | full terminal coding agent (Claude-Code-shaped) | effect-based, split across `processor.ts`/`session.ts` | Effect services + `.txt` prompt files |
| **grok-build** ([xai-org/grok-build](https://github.com/xai-org/grok-build)) | Rust | shipped commercial coding agent: TUI + headless + ACP-embedded | actor-per-session (`SessionActor`) over a tool registry, with a `GoalTracker` state machine driving multi-turn autonomy above it | a `ToolKind`-keyed **registry of interchangeable tool implementations** (its own, plus in-tree ports of codex's and opencode's) selected per session by named toolset preset |

**[src]** for every row but pikuri's.

- **ruby_llm** is pikuri's runtime, not a peer. It still appears because some design choices —
  tool DSL, message shape, error-return convention — live in ruby_llm and pikuri inherits them. **[src]**
- **langchainrb** is the closest existing Ruby framework to pikuri's scope — same language, same
  general "assistant + tools" target — but RAG/vector-search-first, with no MCP, no sub-agents,
  no Skills, and a state-machine loop instead of a callback-driven one. **[src]**
- **pi** is a coding-agent harness: the shape of a Claude-Code-style CLI, designed as a thin core
  with sub-agents, plan mode, MCP and permissions all pushed out to extensions. **[src]**
- **opencode** is much bigger than pikuri — closer to Claude Code itself. The value in it is
  mined ideas, not compared line counts. **[src]**
- **grok-build** is the biggest by a wide margin — ~1.6M lines of Rust across 92 crates, a
  periodic export of xAI's internal monorepo (`SOURCE_REV` records the upstream SHA; external
  contributions are refused). **[src]**
- It is also the only *shipped commercial product* in the set, which makes it the one place to
  see which ideas survived contact with paying users at scale: a permission system an order of
  magnitude more detailed than opencode's, an OS-level sandbox applied to the agent's own
  process, and a tool layer built as an A/B harness rather than a fixed set. **[src]**

**Takeaway.** Pikuri spans three application shapes — general-purpose chat (`bin/pikuri-chat`),
in-repo coding (`bin/pikuri-code`) and a network-severed OS helper (`bin/pikuri-os`) — all
on the same `Agent` + `Tool` core (~10k lines of `pikuri-core/lib`). The job is the *extension surface* on
top of ruby_llm: strict validation, the sealed `Event` hierarchy, listener-based rendering,
controls for cancellation and mid-loop injection, sub-agents, skills, MCP, and a fixed deliberate
set of bundled tools.

## R_agent_loop — What each harness's turn loop looks like, and what stops it

| | Loop shape | Streaming | Termination | Step budget |
| --- | --- | --- | --- | --- |
| pikuri | three callbacks (`after_message`, `before_tool_call`, `after_tool_result`) wired on a `RubyLLM::Chat`; controls (`Cancellable`, `Interloper`) poked at well-defined boundaries; `run_loop` is `chat.ask(message)` (`pikuri-core/lib/pikuri/agent.rb`) | opt-in via `Agent.new(streaming: true)` — per-chunk `Event::{Thinking,Assistant}Delta`; propagates to sub-agents | inherits ruby_llm's: no tool calls; also a `Cancellable::Cancelled` re-raise | **no** — deliberately unbounded; the ceilings are a watching human's `Cancellable` and the context window (`D_no_step_limit`) |
| ruby_llm | iterative (2.1.0): `Chat#complete` repeats `step` — one generation or one tool round — until done (`lib/ruby_llm/chat.rb:236–266`) | yes, optional via block | LLM returns no tool calls, OR a call awaits a human approval / MCP input (`complete` returns; call it again to resume), OR `cancel` | no |
| langchainrb | state machine over `messages.last.standard_role`: `process_latest_message` dispatches `:system / :llm / :user / :tool` to handlers; on tool-call response sets `:requires_action`; `execute_tools` sets `:in_progress`; loops until terminal state | per-LLM block at `Assistant.new(...) { \|chunk\| ... }`; provider-dependent | LLM returns no tool calls → `:completed`; or `auto_tool_execution: false` returns at `:requires_action` so host can inspect | no |
| pi | nested loops: outer for follow-up queue, inner for steering+tools (`packages/agent/src/agent-loop.ts:155–269`) | yes — `EventStream<AgentEvent>` | `shouldStopAfterTurn()` hook, `stopReason`, abort | implicit via context-window compaction |
| opencode | one-shot processor returning `"compact" \| "stop" \| "continue"` per turn (`src/session/processor.ts:115–425`) | yes — Vercel AI SDK chunk events | model emits no tool calls → `"stop"` | no — context overflow → `"compact"` |
| grok-build | a `SessionActor` per session owning the turn loop, plus an optional **goal state machine** above it (`session/goal_{tracker,classifier,strategist,evaluator,stop_detector}.rs`) that re-prompts the agent across turns until a goal's gaps close | yes — ACP `SessionUpdate` notifications, same stream for TUI / headless / editor | model emits no tool calls; goal mode adds `GoalStopDetector` + a stall trip (two identical "gap fingerprints" in a row → auto-pause) | goal-mode run cap (with a one-off `+3` bonus when the strategist restructures); context pressure handled by auto-compaction at 85% of the window, not by a step budget |

**[src]** for every row but pikuri's.

- **Nobody in the set ships a step budget.** Two bound the loop by context pressure instead (pi
  compaction, opencode's `"compact"` return), two by nothing at all (ruby_llm, langchainrb), and
  grok-build only caps *goal mode*, not the turn. **[src]**
- **grok-build's goal mode is the only supervisor in the set** — the only answer to "the agent
  stopped but isn't done" that is machinery rather than a message. A classifier scores the
  remaining gaps after each attempt, a strategist restructures the plan when progress stalls, and
  a stop detector decides the goal is met. **[src]**
- **Its stall detector fingerprints the flagged gaps** and trips when two consecutive attempts
  produce an identical fingerprint — i.e. it detects the model looping rather than converging,
  not the model working for a long time. **[src]**

**Takeaway.** Pikuri's loop is the thinnest of the six with real extension wiring: ruby_llm owns
iteration, and `Agent` is a wiring file — three callbacks, two controls, one sealed `Event`
hierarchy, and a cancellation re-raise path. Nothing caps the iteration (`D_no_step_limit`), and
the human with a `Cancellable` is the ceiling. langchainrb's state machine is the obvious Ruby
alternative shape, but it pays for orthogonal "host decides when to run tools" cases pikuri does
not need. The one thing worth borrowing is grok-build's stall fingerprint — it is the cheap half
of goal mode and exactly the **repetition detector** `D_no_step_limit` names as the first thing
to reach for if a real runaway is ever observed. Borrow it when that day comes; don't reintroduce
a count.

---

## R_provider_abstraction — How each project reaches more than one model provider

- **pikuri**: delegates to ruby_llm. `bin/pikuri-chat` / `pikuri-code` / `pikuri-os`
  configure the OpenAI provider for the local llama.cpp server (`openai_api_base` +
  `assume_model_exists: true`); switching to Anthropic / Gemini / Bedrock / Ollama is a one-block
  edit, no pikuri-side code change. `Agent::ContextWindowDetector` resolves the context-window cap
  at construction from override → ruby_llm registry → llama.cpp `/props` probe, so `TokenLog`
  renders `ctx=<used>/<cap>` against the right ceiling.
- **ruby_llm**: provider-per-class
  (`lib/ruby_llm/providers/{openai,anthropic,gemini,bedrock,ollama,...}/`). The tool schema stays
  canonical and per-provider adapters wrap it. **[src]**
- **langchainrb**: its own multi-provider layer
  (`lib/langchain/llm/{openai,anthropic,google_gemini,aws_bedrock,ollama,cohere,mistralai,...}.rb`),
  unified by `LLM::Base` + `LLM::Adapter` for Assistant integration. **[src]**
- **langchainrb** gives each provider its own message class
  (`Assistant::Messages::{OpenaiMessage,AnthropicMessage,...}`) and schema converter
  (`to_openai_format` / `to_anthropic_format` / `to_google_gemini_format`); vision (`image_url`)
  is first-class on the message type. **[src]**
- **pi**: its own multi-provider layer in `@earendil-works/pi-ai`, covering OpenAI, Anthropic,
  Google, Bedrock and others. **[src]**
- **opencode**: built on the Vercel AI SDK; adding a provider is one entry in
  `BUNDLED_PROVIDERS` (`src/provider/provider.ts:93–118`). **[src]**
- **grok-build** carries **three wire formats behind one `ApiBackend` enum**
  (`xai-grok-sampling-types/src/types.rs:1013`) — Chat Completions (`/v1/chat/completions`, the
  default), the OpenAI Responses API (`/v1/responses`), and the Anthropic Messages API
  (`/v1/messages`) — each with its own converter under
  `xai-grok-sampling-types/src/conversation/`. **[src]**
- **grok-build picks the backend per provider**: `[model_providers.<id>]` takes `base_url` +
  `api_backend` + `extra_headers` + `context_window` + an auth command
  (`xai-grok-shell/src/agent/model_providers.rs:8`), and a model inherits its provider's
  connection defaults. xAI is the *default* (OAuth-in-browser on first launch), not the only
  reachable backend — pointing it at a local llama.cpp is a config block, not a fork. **[src]**
- **grok-build invests most in the opposite direction**: ACP (Agent Client Protocol) as the
  *outward* interface, so one runtime serves the TUI, a headless `-p` invocation,
  `grok agent stdio` and an editor plugin over a single session/notification protocol. **[src]**

**Takeaway.** Pikuri inherits ruby_llm's "canonical schema + thin per-provider adapter" shape,
rather than opencode's SDK-of-SDKs or langchainrb's everything-in-house: pikuri's tools were
written against the OpenAI tool-call shape, and ruby_llm preserves that as the canonical form.
The bundled `bin/pikuri-*` scripts are hardcoded for the local llama.cpp setup; multi-provider
wiring is a `bin/`-level change, not a library rewrite.

## R_subscription_transport — hermes-agent reaches a subscription by driving the vendor's own CLI

Every provider in `R_provider_abstraction` is HTTP plus an API key. hermes-agent shipped the
exception on 2026-09-20: a model provider whose transport is the unmodified `claude` executable,
so the bytes ride the user's Claude Pro/Max subscription instead of a Developer Platform key.

- **Two halves, and only the reusable one is in-tree.** Core got generic external-process-provider
  seams — `ProviderProfile` hooks (`setup_status`, `discover_models`, …), a provider-native
  `reasoning_details` replay carrier, picker plumbing; the vendor-specific transport was pushed to
  its own repo under a stated "Hermes does not bundle vendor-specific subscription transports
  in-tree" policy, and installs as a pinned catalog plugin. **[docs]**
- **The provider owns no credential.** It never opens, copies, refreshes or prints the CLI's auth
  files; an inherited API key or custom Anthropic endpoint is a hard error before spawn, naming
  the variable without printing it, rather than a silent HTTP fallback. **[docs]**
- **One child process per `chat.completions.create`**, in a private temp dir and its own process
  group, cancelled tree-wide so the `node` behind the npm shim cannot outlive the
  request. **[docs]**
- **The load-bearing trick is a per-request loopback relay.** The plugin binds an ephemeral port
  on a random route, points the child's `ANTHROPIC_BASE_URL` at it, forwards only the *first*
  Messages request upstream and refuses the rest locally — native 2.1.263 attempts extra
  generations despite `--max-turns 1` and disabled HTTP retries. **[docs]**
- **The same relay rescues the real answer**: it captures streamed text, signed thinking, tool
  arguments, usage and stop reason before the CLI's own recovery can replace a completed response
  with synthetic error text. Native auth headers pass through memory, unlogged. **[docs]**
- **Everything agentic in the child is switched off** so the host keeps its loop: native tools,
  skills, setting sources and autocompaction disabled, and MCP advertising only Hermes' current
  tool inventory with inert callbacks denied execution by native `dontAsk`. **[docs]**
- **History is replayed in full on every request** — historical user frames carry
  `shouldQuery:false` and each takes a zero-turn acknowledgment, the last frame queries; there is
  no parked native session. Tool schemas and the system prompt arrive through a private native
  settings file plus `CLAUDE_CODE_EXTRA_BODY` rather than argv or env, clearing the OS
  per-string limit. **[docs]**
- **Replay against a CLI wrecked prompt caching until one native annotation was removed.** A real
  187K-token run read 6,989 of 190,840 input tokens from cache (3.66%); disabling the native
  token-budget reminder — which replay reconstructs across the cache boundary — restored ~98%
  cache reads. **[docs]**
- **Setup interrogates the CLI, never the vendor's API**: `claude auth status` for login, then the
  `initialize` handshake for the account's own model picker, both at zero upstream
  requests. **[docs]**
- **It meters exactly like `claude -p`, and the interactive TUI is the cheap path.** Measured on a
  Pro plan 2026-09-09, both `-p` and this provider spent ~8.9 session points per list-dollar
  against interactive Claude Code's 5.4 and 4.9 — a server-side weighting that hits every
  `-p`/SDK harness alike. **[docs]**
- **The seam is a version, not an API.** Qualified against Claude Code 2.1.263, with replay
  acknowledgments and extra-body behaviour called out as version-sensitive interfaces rather than
  a public arbitrary-history guarantee. **[docs]**
- **The policy underneath moved twice in 2026.** Anthropic's separate per-plan Agent SDK credit,
  which explicitly covered third-party apps authenticating with a Claude subscription, was paused
  on 2026-06-15; such usage draws from ordinary subscription limits again. **[docs]**

**Takeaway.** Mechanically this is reachable from pikuri's seams: a `ChatTransport` whose base URL
is a local relay, plus a `Subprocess.spawn`ed CLI, is the whole of it. What it costs is the
promises. A vendor CLI as transport pins the harness to one build of someone else's binary, and
the admission relay exists only to fight that binary's own retry behaviour — a threat model that
never closes, because the far side of the socket is free to change next release. Nor is it a
privacy win: the subscription route is a hosted provider like any other.

## R_tool_abstraction — How a tool is defined, schema'd and validated in each project

| | Definition style | Schema | Validation strictness |
| --- | --- | --- | --- |
| pikuri | `Tool.new(...)` factory returns a synthetic `RubyLLM::Tool` subclass; `Tool::Parameters` builder lives on top of ruby_llm's tool layer | fluent `Tool::Parameters` builder → JSON Schema, fed to ruby_llm's `parameters(hash)` | strict: unknown keys rejected with DidYouMean, type coercion, all errors collected. The keyrest signature on `execute(**args)` makes ruby_llm's keyword-presence checker no-op so pikuri's validator runs first |
| ruby_llm | subclass `RubyLLM::Tool`, class-level DSL | three options (2.1.0): `parameters` schema or block, `parameter :name` declarative, OR auto-inferred from `execute` keyword args | strict but **no DidYouMean** |
| langchainrb | class `extend Langchain::ToolDefinition`; `define_function :method_name, description: do property :foo, type:, required:; end`; tool can expose multiple functions, each becomes a separate tool entry named `<class>__<method>` | DSL → JSON Schema with per-provider exporters; supports `object`/`array`/`enum` recursively | required-key checked by JSON Schema export only — no DidYouMean, no coercion |
| pi | `AgentTool<TParameters>` interface, factory functions | Typebox `Type.Object()` (compile-time + runtime) | Typebox-strict; optional `prepareArguments()` shim for LLM quirks |
| opencode | Effect Schema decoders (Zod-shaped) + `.txt` description files | Effect `Schema.decodeUnknownEffect()` | strict; failure produces "rewrite the input so it satisfies..." message |
| grok-build | `impl Tool` (typed `Args`/`Output`) + an `impl ToolMetadata` declaring `kind` / `namespace` / `description_template` / `requires_expr`; a session then *selects* implementations by name from a global `ToolRegistryBuilder` | derived from the `Args` type via `schemars`, with per-field `#[schemars(description = …)]`; the registry can rename parameters per deployment | serde-strict, with deliberate leniency shims (`deserialize_lenient_i64` accepts `"-3"` for `-3`) — the model's known failure modes are absorbed at the edge rather than bounced back |

**[src]** for every row but pikuri's.

- **Both Ruby alternatives produce thin "missing keyword: x" messages on bad input** — no
  DidYouMean, no coercion, no all-errors-collected pass. **[src]**
- **langchainrb is one-class-many-functions**: `extend ToolDefinition`, then several
  `define_function`s, each exported as a separate tool entry named `<class>__<method>`. **[src]**
- **grok-build absorbs the model's known failure modes at the edge** rather than bouncing them
  back: `deserialize_lenient_i64` accepts `"-3"` where `-3` is declared. **[src]**

**Takeaway.** Pikuri's strict-with-DidYouMean validator is still the single most load-bearing
piece of code distinguishing it from ruby_llm and langchainrb. Pikuri's "one constant or instance
per tool" is closer to opencode's pattern than to langchainrb's. Method-signature introspection
(ruby_llm's auto-infer-from-`execute`) stays an option for trivial tools, but the explicit
`Parameters` builder keeps per-argument descriptions next to the schema, which is hard to give up.

MCP tools are the documented exception to pikuri's strict-validation contract: they are
synthesised as raw `RubyLLM::Tool` subclasses inside `Mcp::Servers` from each server's
`input_schema`, fed in via `Agent::ExtensionContext#add_raw_tool`. The strict-validation guarantee
covers native tools only; MCP-side validation catches bad input on the server end. See
`pikuri-mcp/lib/pikuri/mcp/servers.rb`.

### grok-build's registry: a tool layer built as an A/B harness

The one structural idea here with no analogue elsewhere in the field, and the reason its tool
crate is ~129k lines.

- **The same capability ships several times over, and which implementation the model sees is a
  per-session config decision.** `ToolRegistryBuilder::new()` registers all of them side by side
  (`crates/codegen/xai-grok-tools/src/registry/types.rs:674–765`). **[src]**
- The registry holds its own `read_file` / `search_replace` / `list_dir` / `grep` / `bash`;
  **in-tree ports of openai/codex's** `apply_patch`, `read_file`, `list_dir`, `grep_files`
  (`implementations/codex/`); **in-tree ports of sst/opencode's** `read` / `edit` / `write` /
  `grep` / `glob` / `bash` / `todowrite` / `skill` (`implementations/opencode/`); a
  `GrokBuildConcise` namespace with the same behaviour but deliberately shorter output and
  descriptions for token-tight deployments; and a `GrokBuildHashline` namespace carrying a third
  *addressing scheme* for edits. **[src]**
- Both ports carry Apache §4(b) change notices in `xai-grok-tools/THIRD_PARTY_NOTICES.md`. **[src]**

Five mechanisms hold that together, each independently interesting:

- **`ToolKind` is the semantic identity; the wire name is not.** `read_file`, codex's `read_file`
  and opencode's `Read` all declare `ToolKind::Read`, so presentation (`"Read"`), the read-only
  classification, permission rules and telemetry are written once against the *kind* and survive
  swapping the implementation. **[src]**
- **A canonical `_meta` envelope (`x.ai/tool`) stamps every tool call** with kind + namespace + a
  normalized input dict — `path` / `offset` / `limit` / `command` / `pattern` — so a consumer
  reads one vocabulary no matter which toolset produced the call (`tool_taxonomy.rs`,
  `normalization.rs`). Both matches are exhaustive: a new kind or input variant must classify
  itself or the crate does not compile. **[src]**
- **Tool descriptions are templates rendered against the live wiring.** They interpolate config
  (`{max_lines_read}`, `max_timeout_ms`), the renamed parameter names
  (`${{ params.read.target_file }}`), and *sibling tools by kind*, guarded by conditionals:
  `${%- if tools.by_kind.edit %} for use with ${{ tools.by_kind.edit }}${%- endif %}`. Every
  clause that depends on another tool existing disappears when it is not wired. **[src]**
- **`requires_expr` is a dependency expression over kinds.** `TaskTool` declares
  `And(BackgroundTaskAction, KillTaskAction)` — offer the subagent spawner only if the tools for
  retrieving and killing its results are present too. Incoherent toolsets fail validation at
  finalize rather than confusing the model at runtime. **[src]**
- **Behaviour is versioned per release.** `read_file/versions/legacy_0_4_10.rs` keeps the exact
  historical error string and the "gitignored files are readable" policy of v0.4.10, so a model
  tuned against that surface keeps the semantics it was tuned against. **[src]**

**Takeaway.** The A/B-harness framing is a first-party-model company's problem: you build it when
you are tuning a model against tool surfaces and need to measure which surface wins. Pikuri should
not grow parallel toolsets. Three of the mechanisms are independently cheap and land on real
pikuri friction:

- The **templated cross-tool reference** answers pikuri's "no tool names in a main/binary system
  prompt" rule directly. That rule exists because a name in a prompt drifts against the wiring;
  grok-build removes the drift instead of the name, resolving the reference at render time against
  the finalized toolset. The rule stays correct as written, but its *reason* is now known to be
  fixable.
- **`requires_expr`** is the missing guard on `Persona#tool_names` and on each `bin/pikuri-*`
  wiring — nothing today catches a persona listing a tool whose companion is out of scope.
- **`ToolKind` as identity** is what pikuri would need the day two tools serve one purpose (it
  already nearly happens: `web_scrape` vs `fetch`, `glob` vs `file_list`). Not needed yet.

## R_available_tools — Which tools each project actually ships

| | calc | shell/bash | read | write | edit | grep | glob | search | scrape/fetch | sub-agent | skill | mcp | todo/plan | LSP | vector/RAG |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pikuri | ✅ | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ glob + file_list | ✅ web_search | ✅ web_scrape + fetch | ✅ | ✅ Agent Skills standard | ✅ stdio + HTTP | ✅ task_* + plan mode | ✅ lsp | ✅ vectordb_* |
| ruby_llm | — (SDK only — no bundled tools) | | | | | | | | | | | | | | |
| langchainrb | ✅ | — | ✅ file_system | ✅ file_system | — | — | — | ✅ google_search / tavily | — | — | — | — | — | — | ✅ vectorsearch (Chroma, Pinecone, Pgvector, Weaviate, Qdrant, Milvus, Elasticsearch, Hnswlib) + DB, NewsRetriever, Weather, Wikipedia, RubyCodeInterpreter |
| pi | — | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ find | — | — | — (extension) | ✅ via extensions | — | — (extension) | — | — |
| opencode | — | ✅ shell | ✅ read | ✅ write | ✅ edit + patch | ✅ grep | ✅ glob | ✅ search (Exa) | ✅ fetch | ✅ task | ✅ | — | ✅ todo + plan | ✅ | — |
| grok-build | — | ✅ bash | ✅ read_file | ✅ write | ✅ search_replace + apply_patch + hashline_edit | ✅ grep | ✅ list_dir + glob | ✅ web_search | ✅ web_fetch | ✅ task | ✅ skill | ✅ (+ `search_tool`/`use_tool` deferred loading) | ✅ todo_write + enter/exit_plan_mode + update_goal + workflow | ✅ lsp | ✅ memory_search / memory_get (SQLite FTS5 + optional vec0) |

**[src]** for every row but pikuri's.

- **ruby_llm ships no tools at all** — it is an SDK; the developer subclasses `RubyLLM::Tool` and
  wires their own. **[src]**
- **langchainrb's "tools" are a different shape** — mostly *capability wrappers* (Wikipedia,
  Weather, NewsRetriever, SQL Database, Vectorsearch) rather than the file/shell building blocks
  the coding agents ship. **[src]**
- **pi ships only file/shell ops**; web search, sub-agents and the rest are pushed to
  extensions. **[src]**
- **grok-build ships everything opencode does plus five categories nobody else has**: scheduling
  (`scheduler_create` / `_delete` / `_list` — cron-style recurring agent runs), monitoring
  (`monitor` — watch a condition and re-enter), media generation (`image_gen`, `image_edit`,
  `image_to_video`, `reference_to_video`), direct user interrogation (`ask_user_question` — the
  agent pauses and asks a multiple-choice question), and goal tracking (`update_goal`,
  `workflow`). **[src]**
- **grok-build's tool count is a per-session config value, not a fixed number.** Its row is the
  union across the named toolset presets (`grok-build`, `grok-build-concise`, `grok-build-plan`,
  `codex`, `explore`, `plan`, `grok-computer`). **[src]**
- **grok-build indexes MCP tools instead of resident-loading them**: `search_tool` exposes BM25
  keyword search over the tool catalog, and `use_tool` is a single meta-dispatch that calls a
  discovered tool by qualified name. **[src]**
- **`use_tool` carries a corrective for the predictable failure**: hand it a *native* tool name
  and it answers "call it directly" rather than the generic not-an-MCP-tool error. **[src]**

**Takeaway.** The `search_tool` / `use_tool` pair solves the problem `mcp_connect` solves — don't
pay for MCP schemas you aren't using — with a different lever, search-then-call rather than
connect-then-register, and it degrades better when one server exposes a hundred tools. The pikuri
row is the union of what the bundled binaries wire: `bin/pikuri-chat` wires calc + web_search +
web_scrape + fetch + sub_agent; `bin/pikuri-code` the file/shell stack plus tasks, plan mode, MCP
and (where a language server is configured) `lsp`; `bin/pikuri-openlibrary` one MCP server;
`bin/pikuri-corpus` the vectordb tools. Pikuri covers the general-purpose,
coding-agent and MCP-augmented surfaces from one codebase, with Skills bridging static text
knowledge between them. What it still declines is the write half of an LSP — rename, formatting,
code actions, diagnostics — which is where a read-only navigator would need the `Confirmer` seam
and stop having a closeable threat model.

### Edit addressing: grok-build ships all three arms, and measures them

The candidate answers are usually framed as two: match a unique string (Claude Code, opencode,
pikuri) or ship a patch format with line context (codex's `apply_patch`).

- **grok-build ships both, plus a third**, and built a benchmark harness to choose between
  them. **[src]**
- **The third is `GrokBuildHashline`.** `hashline_read` returns every line as
  `LINE:HASH[:HASH]→CONTENT`, where the hash is a whitespace-normalized fingerprint of the line
  and (depending on scheme) its surrounding context; `hashline_edit` takes those anchors as its
  addresses. **[src]**

```
"replace"      — { "op": "replace", "anchor": "22:abc:rst", "content": "    let x = 42;" }
                 ranges via "end_anchor" (inclusive); "content": "" deletes
"insert_after" — { "op": "insert_after", "anchor": "22:abc:rst", "content": "…" }
                 "0:" for beginning-of-file, "EOF" for end
"write"        — whole-file replacement, no anchor
```

Properties fall out that neither of the usual two arms has:

- **Verification is intrinsic, not a side effect of uniqueness.** The anchor *is* a content
  fingerprint, so a stale anchor fails loudly rather than editing the wrong copy — and two
  identical lines have identical local hashes but different line numbers, so there is no
  uniqueness tax to escape. **[src]**
- **A failed edit returns fresh anchors, and the description tells the model to retry immediately
  rather than re-read.** That closes the read→edit→stale→re-read→edit loop. **[src]**
- **Batches are validated against the pre-edit snapshot and applied atomically bottom-up** — one
  bad anchor rejects the whole batch, and overlapping ranges are refused. **[src]**
- **Batching is not one of the four interchangeable `ToolKind::Edit` implementations grok-build
  maintains and benchmarks.** Where a batch appears it is a *property of the anchor scheme* —
  atomic-or-nothing against a pre-edit snapshot — not a second tool. **[src]**
- **The anchor scheme is still a parameter in a shipped product.** `scheme.rs` defines three
  candidates (content-only, chunk-fingerprint, checkpoint-chain) trading freshness detection
  against anchor churn, and `benchmark.rs` measures read-amplification and validation cost across
  them. Nobody knows which addressing scheme is best, and the team that could measure it has not
  closed the question either. **[src]**
And the cost side, which is not free:

- **An anchor validates by fingerprint, not by equality.** `util/hash.rs` encodes an FNV-1a
  32-bit hash as three lowercase letters — 26³ = 17,576 buckets — and validation recomputes that
  3-letter code for the line at the given index and compares. **[src]**
- **A collision therefore lets a stale anchor validate**, landing the edit on changed content
  silently. The probability per validation is small and not zero, where a byte-exact `old_string`
  cannot false-positive at all. Widening the hash narrows the window without closing it, and
  spends the payload win that motivated the scheme. **[src]**
- **The cost is real and named in the product's own description**: anchors are valid only for the
  file state at read time, the read output carries ~10 extra characters per line, and the model
  must never invent an anchor (the description says so twice). **[src]**

**Takeaway.** Pikuri has settled how `edit` names its target — a unique string, `occurrence: N` to
escape the uniqueness tax, no batch or patch sibling (`D_single_hunk_edit`). Hashline buys freedom
from that tax by opening a silent wrong-edit window: a straight trade against the
"predictability beats fuzz" posture of {Pikuri::Workspace::Edit}, not a free improvement, and a
reversal to argue on its own merits rather than a drop-in.

Two smaller edit-path details, instructive in opposite directions — one transfers only after being
inverted, the other does not transfer at all:

- **Sparse line-number anchors.** grok-build's default `read_file` prints the `LINE→` prefix only
  on the first line and every tenth after ("count from the nearest anchor"). Same addressability,
  a fraction of the tokens. **[src]** Pikuri already declined it: {Pikuri::Workspace::Read} picks
  `cat -n` for *training-data familiarity* over opencode's cheaper `"<n>: "` and pi's numberless
  output, and an outside-model review (Grok 4.6) confirmed the numbering and the
  read-a-larger-window nudge as a pair, with "don't trade either back for tokens".
  **[verified 2026-08]** Grok's own product does the opposite of what Grok advised pikuri, and the
  reason is the test to apply to every borrow here: **a first-party model vendor can tune the
  model to its format; a harness has to meet the model where it already is.** See
  `design/ideas/grok-build-cheap-borrows.md`.
- **Unicode confusable repair** (`util/unicode_confusables.rs`). Smart quotes, em-dashes,
  ellipses and non-breaking spaces pasted in from Slack or Google Docs render identically to ASCII
  in `read`, so the model's ASCII `old_string` never matches on `edit`. grok-build keeps a
  deliberately narrow map — only substitutions that are near-always accidental, with `U+2212
  MINUS` and `U+00D7 MULTIPLICATION` excluded as semantically meaningful — normalizes for
  *comparison only*, and keeps a byte-offset remap so the write lands on the original
  bytes. **[src]** Pikuri's `Edit` has the same failure mode with no mitigation, but the half to
  take is the *diagnosis*, not the repair: `Edit` normalizes CRLF across the whole file, so a
  normalize-edit-writeback would rewrite every smart quote behind a "1 occurrence" confirmation.
  Retrying a failed match against a normalized copy and naming the offending codepoint costs
  nothing and keeps the byte-for-byte contract intact.

## R_tool_descriptions — What a shipped tool description actually reads like, project by project

The LLM sees only the `description` and the per-parameter strings, so their quality decides how
often it picks the right tool with the right arguments. Every block below is quoted verbatim from
the project's source.

### pikuri (the reference column — post-cleanup)

All bundled tools follow one heredoc shape: a one-line summary, a blank line, a `Usage:` bullet
list. `web_scrape` as the exemplar — the tool with the biggest jump from the pre-convention state:

```
Scrapes the rendered webpage or text file at the given URL and returns its main content as Markdown.

Usage:
- Use for HTML pages where you want readable content — readability extraction strips nav, sidebars, and boilerplate.
- For raw textual payloads (JSON, CSV, robots.txt, source files), use fetch instead — it returns bytes verbatim, while web_scrape would corrupt them with a Markdown pass.
```

Two cross-cutting decisions fell out of that pass: universal `Error: ...` recovery lives in the
per-binary system prompts as one rule rather than per-tool, and per-argument constraints stay in
the *parameter* description, never duplicated in the tool description. Both are `AGENTS.md`
conventions now, so new tools land at the bar without per-PR re-litigation.

### ruby_llm (from a spec fixture — there are no shipped tools)

```ruby
class Weather < RubyLLM::Tool
  description 'Gets current weather for a location'
  param :latitude, desc: 'Latitude (e.g., 52.5200)'
  param :longitude, desc: 'Longitude (e.g., 13.4050)'
end
```

- **The standout is example values inside parameter descriptions** — `'Latitude (e.g., 52.5200)'`.
  It appears in the spec fixtures because ruby_llm ships no tools of its own. **[src]**

### langchainrb (verbatim — `Calculator.execute`)

```ruby
define_function :execute, description: "Evaluates a pure math expression" do
  property :input, type: "string", description: "Math expression", required: true
end
```

- **Per-function, single-line, no usage bullets, no parameter examples, no failure-mode
  guidance.** **[src]**
- The terse style works when the LLM was trained against named tools — the function name
  `langchain_tool_calculator__execute` carries most of the signal — but loses the
  chain-with-other-tools framing opencode and pikuri put front and centre. **[unverified]**

### pi (verbatim — `read` tool)

```
Read the contents of a file. Supports text files and images (jpg, png,
gif, webp). Images are sent as attachments. For text files, output is
truncated to 10000 lines or 2048KB (whichever is hit first). Use
offset/limit for large files. When you need the full file, continue with
offset until complete.
```

- **Crisp, behavioural, concrete numbers, one clear failure mode.** **[src]**

### opencode (verbatim — `read.txt`)

```
Read a file or directory from the local filesystem. If the path does not
exist, an error is returned.

Usage:
- The filePath parameter should be an absolute path.
- By default, this tool returns up to 2000 lines from the start of the file.
- The offset parameter is the line number to start from (1-indexed).
- To read later sections, call this tool again with a larger offset.
- Use the grep tool to find specific content in large files or files with
  long lines.
- If you are unsure of the correct file path, use the glob tool to look up
  filenames by glob pattern.
- Contents are returned with each line prefixed by its line number as
  `<line>: <content>`. ...
- Any line longer than 2000 characters is truncated.
- Call this tool in parallel when you know there are multiple files you
  want to read.
- Avoid tiny repeated slices (30 line chunks). If you need more context,
  read a larger window.
- This tool can read image files and PDFs and return them as file
  attachments.
```

- **opencode's `edit` description takes the same shape** — one-line summary, then a `Usage:`
  bullet list with explicit dos and don'ts ("ALWAYS prefer editing existing files", "NEVER write
  new files unless explicitly required", "This tool will FAIL if `oldString` is found multiple
  times in the file with an error..."). **[src]**

### grok-build (verbatim — the `bash` description, unrendered)

Same shape (summary, blank line, `Usage notes:` bullets) — but the string in the source is a
*template*, and what the model sees depends on the host and the wiring:

```
Run a ${%- if is_windows %} shell command${%- else %} bash command${%- endif %} and return its output.

Usage notes:
  - You can specify an optional ${{ params.execute.timeout }} in milliseconds (up to ${{ max_timeout_ms | default(300000) }}ms). ${%- if auto_background_on_timeout %} If not specified, foreground commands exceeding the default timeout will be automatically backgrounded instead of killed. …${%- else %} If not specified, foreground commands will timeout after ${{ default_timeout_ms | default(120000) }}ms.${%- endif %} …
  - Timeout enforcement: when the timeout fires, the wrapper${%- if is_windows %} terminates the child's Job Object, killing every descendant process immediately…${%- else %} kills the child process group (SIGTERM, escalated to SIGKILL after a ~1s grace period). Descendants that did not detach via `setsid` / `nohup` will also be killed.${%- endif %} … disables the wrapper timeout entirely${%- if tools.by_kind.kill_task_action %}; the child's lifetime is owned by the model via ${{ tools.by_kind.kill_task_action }}${%- endif %}.
  - If the output exceeds {max_output_bytes} characters, the middle is truncated (you keep the beginning and end) and the result includes the path to a log file with the full output, which you can read or search.
  - You can use the ${{ params.execute.is_background }} parameter to run the command in the background…${%- if system_reminders_enabled %} You are notified on completion, so do not poll or sleep-wait for it.${%- elif tools.by_kind.background_task_action %} Check on it later with the ${{ tools.by_kind.background_task_action }} tool.${%- endif %}
${%- if shell_uses_semicolon %}
  - '&&' is not supported in this shell; chain sequential commands with ';'.
${%- endif %}
${%- if not has_unix_utilities %}
  - The Unix utilities `grep`, `head`, `tail`, `sed`, `awk`, and `find` are NOT available in this shell. Use the dedicated tools instead.
${%- endif %}
```

- **Five things are conditional in that one description**: the host OS, the shell's chaining
  operator, whether Unix utilities exist on `PATH`, whether sibling tools (`kill_task`,
  `get_task_output`) are wired, and whether the runtime's system-reminder channel will tell the
  model when a background task finishes. **[src]**
- **Numbers come from live config** (`max_timeout_ms`, `max_output_bytes`) rather than being
  restated by hand. **[src]**
- **A render failure degrades by stripping the markers** (`strip_markers_on_render_failure`)
  rather than shipping template syntax to the model. **[src]**
- **Over the output cap, grok-build truncates the *middle*** — keeping head and tail — and hands
  the model a path to the full log. **[src]** The tail is usually the part that matters: a build's
  error summary lives at the end, so head-only truncation throws away the answer. **[unverified]**

**Takeaway.** opencode's pattern — summary, then a bullet list of usage constraints — is the gold
standard, and pikuri applies it uniformly. The one divergence: opencode bakes failure-mode hints
inline ("If the path does not exist, an error is returned") where pikuri factors them into a
single universal rule per binary prompt — cheaper to maintain, less tool-specific. langchainrb's
terse style is the floor; ruby_llm's `e.g.`-in-parameters is a free uplift pikuri now applies
universally.

grok-build is the ceiling, and it shows what pikuri's convention buys and pays for. Pikuri factors
universal recovery guidance into the prompt to avoid per-tool drift; grok-build keeps everything
in the tool and prevents drift by making the description *derive* from the wiring and config it
describes. Pikuri's version is cheaper and fits a codebase meant to be read in an evening;
grok-build's is the only one of the two that cannot go stale. The portable lesson is narrower than
the machinery: **a number that appears in a description should be interpolated from the constant
that enforces it, not typed twice.** Pikuri already does this where the cap is a constant
(`Read`'s `MAX_IMAGE_BYTES_LABEL`, `Grep`'s `MAX_BYTES_LABEL`) and does not where it isn't (`web_search`'s
"Defaults to 10; most providers cap this at 20" sits next to a hard-coded `max_results: 10`).
Closing that gap is the whole portable half of grok-build's template machinery.

## R_message_types — Message stores, event streams and token bookkeeping across the field

| | Message store | Event stream | Streaming deltas | Token bookkeeping |
| --- | --- | --- | --- | --- |
| pikuri | inherits ruby_llm's `Chat#messages` | sealed `Agent::Event` hierarchy: `UserTurn(mid_loop)`, `Thinking`, `Assistant`, `ThinkingDelta`, `AssistantDelta`, `ToolCall`, `ToolResult`, `Tokens`, `ContextCap`, `Cancelled` — all flow through one `Listener::Base#on_event` entry point | opt-in via `Agent.new(streaming: true)`; per-chunk `*Delta` events alongside message-level bookends | `Tokens` event carries `input`/`output`/`cached`/`cache_creation`/`thinking`/`model_id`; `Listener::TokenLog` tracks running context-window size; `Event::ContextCap` carries the detected cap from `ContextWindowDetector` |
| ruby_llm | plain Array of `Message` objects (no log wrapper) | three registered callbacks (`after_message`, `before_tool_call`, `after_tool_result`); structured events not exposed | yes, optional via block | per-message `tokens` field on `Message`; no running aggregate |
| langchainrb | `messages` (Array of provider-specific `Messages::*Message`); `add_message_callback` proc fires on every append | none beyond the two callbacks (`add_message_callback`, `tool_execution_callback`) | per-LLM block at `Assistant.new(...) { ... }` | running totals on `Assistant`: `total_prompt_tokens` / `total_completion_tokens` / `total_tokens` |
| pi | TypeScript discriminated union; custom message types extensible via declaration merging | `EventStream<AgentEvent>` | yes | per-event |
| opencode | `MessageV2` with `ErrorPart` / `ToolPart` / `TextPart` etc.; parts are typed and persisted in SQLite per session | Vercel AI SDK chunks; bus emits typed events for permission flows | yes | per-message |
| grok-build | per-session actor + SQLite journal (`xai-sqlite-journal`); sessions are listable, resumable, forkable, and searchable (`session_search`) | **ACP `SessionUpdate` notifications** — one protocol serving TUI, headless, and editor clients alike; tool calls carry the canonical `x.ai/tool` `_meta` envelope | yes | `xai-token-estimation` + auto-compaction at 85% of the window, with an optional speculative two-pass compaction that summarizes the history prefix in the background *before* the threshold is hit |

**[src]** for every row but pikuri's.

- **Every project in the field has context compaction; pikuri does not.** **[src]**
- **grok-build's compaction is the most developed**: auto-compact at 85% of the window, a
  configurable summarizer model, a wall-clock budget per compaction (a generation that overruns is
  cut and retried — the backstop token limits miss when reasoning runs away), an optional
  memory-flush turn that writes durable notes *before* the history is discarded, and a two-pass
  mode that speculatively summarizes the prefix in the background so the compaction itself is
  cheap. **[src]**
- **grok-build has a second channel with no pikuri equivalent: reminders riding tool output.**
  `<system-reminder>` blocks are appended to a tool's *observation* on the way back to the model,
  either by the tool itself (an empty file read) or by cross-cutting reminders registered on the
  registry — fresh LSP diagnostics, newly discovered skills, a completed background task, a nudge
  to use `todo_write` after N turns without one. It costs nothing when quiet and tells the model
  something without spending a turn. **[src]**
- That is genuinely a *second* channel: grok-build also injects standalone reminder **messages**,
  and those are user turns (`R_synthetic_user_turns`). **[src]**

**Takeaway.** Pikuri has the richest structured-event surface among the Ruby implementations: a
sealed `Data.define` hierarchy covering turns, thinking, assistant text, both delta modes, tool
calls, tool results, token usage, context cap and cancellation, all through one `on_event` entry
point. langchainrb's two-callback model is the same *architectural shape* pikuri started with; the
sealed hierarchy is the upgrade pi and opencode have and Ruby otherwise lacks. The four bundled
listeners (`Terminal`, `InMemoryEventList`, `TokenLog`, `RateLimited`) are examples of the shape a
new sink would take, not "the" listener.

On compaction, pikuri's answer today is `exit 1` in a `bin/` script
(`design/ideas/context-overflow-behavior.md`) — a demo shortcut, not a library position. The
memory-flush *ordering* is the piece worth remembering when that changes, because pikuri-memory's
capture step has exactly the same before-or-after question.

## R_synthetic_user_turns — grok-build's injection channel: every synthetic turn is a user turn

Read in August 2026 against `xai-org/grok-build` at `SOURCE_REV`, because pikuri had just found
that a mid-conversation `role: system` message is silently discarded by some chat templates
(`D_reference_text_as_user_turn` carries the finding, the Jinja excerpt and the three-model canary
table; `book/wire.md` is the reader-facing version). The question was narrow: what role does
grok-build use for mid-conversation reference text, over which APIs, and does it probe the model
first?

- **There is no mid-conversation system message anywhere in grok-build.** The conversation is a
  `Vec<ConversationItem>` of `System | User | Assistant | ToolResult | BackendToolCall | Reasoning`
  (`xai-grok-sampling-types/src/conversation.rs:70`), and `SystemItem`'s doc is one line —
  *"System instructions/prompt"*. **[src]**
- **Every production construction of `ConversationItem::system(…)` is index 0 of some request**:
  the main conversation's prompt (`install_system_prompt`,
  `xai-chat-state/src/conversation_util.rs:40`), a subagent's own prompt, or the leading prompt of
  a separate nested one-shot call (goal evaluator, session summary, recap, memory-dream, two-pass
  compaction, the auto-mode permission classifier). None appends. **[src]**
- **What it has instead is 15 tagged synthetic user kinds** — `SyntheticReason`
  (`conversation.rs:119`), each with a constructor that builds a `UserItem`: `CompactionMeta`,
  `SystemReminder`, `ProjectInstructions` (its CLAUDE.md/AGENTS.md load), `AutoContinue`,
  `AutoRecovery`, `Interjection`, `AgentMessage`, `TaskCompleted`, `SubagentCompleted`,
  `NotificationDrain`, `GoalSummary`, `GoalClassifierNudge`, `SchedulerFired`, `StopHookFeedback`,
  `WorkingDirectorySwitch`. **[src]**
- That set covers everything pikuri once injected as `:system` — a host-loaded skill body, a
  memory prefetch, a path-activation promotion, retrieved RAG context — plus ten cases pikuri has
  no equivalent for. **[src]**
- **The generic sink is 19 call sites deep and wraps as it pushes**
  (`acp_session_impl/reminders.rs:546`), escaping a nested closing tag so injected content cannot
  forge the envelope. **[src]**

```rust
let content = content.replace(&format!("</{tag}>"), &format!("<\\/{tag}>"));
let message = ConversationItem::system_reminder(format!("<{tag}>\n{content}\n</{tag}>"));
self.chat_state_handle.push_user_message(message);
```

- **The tag, not a second role, distinguishes a synthetic turn from a real one.**
  `SyntheticReason` is a nullable field on `UserItem`, and consumers interrogate it:
  `starts_prompt_turn()`, `extract_last_real_user_query`, `is_real_user_turn`, and the parent-ask
  scan that skips synthetics so they do not burn lookback
  (`implementations/grok_build/task/mod.rs:114`). One role plus a reason tag, not two roles. **[src]**
- **The Anthropic backend hoists unconditionally, so position is not preserved there anyway.**
  `MessageRole` is `User | Assistant` only — the Messages API has no system variant — and a
  `System` item anywhere in the sequence is flushed onto the top-level `system` param
  (`conversation/messages.rs:168`). Lossless for grok-build *because* it never has a
  mid-conversation one. **[src]**
- **The other two converters are positional**: `System → Role::System` wherever it sits, no hoist,
  no warning. **[src]**
- **ruby_llm does the same hoist** — its Anthropic provider is
  `messages.partition { |msg| msg.role == :system }` — so a chronological `:system` injection
  arrives at Anthropic reordered to the front, presented as if it had been part of the original
  prompt. **[src]**
- **There is no detector, and nothing that needs one.** No `/apply-template`, no `/props`, no
  chat-template introspection; the vendored MiniJinja renders *tool descriptions*, not
  prompts. **[src]**
- **Nor is there an empty-messages guard on the Messages path**, which grok-build can afford
  because every wake path (scheduler, task-completed, notification drain, goal summary) is a
  synthetic *user* message — there is always something to complete against. **[src]**
- **The capability is exposed to third parties and unused.** The turn-hook wire protocol lets a
  workspace server ask for an injection as `System | Developer | User`
  (`xai-tool-protocol/src/turn_hook.rs:155`), and only the `User` variant carries an example —
  *"(e.g. a `<system-reminder>`-wrapped message)"*. grok-build's own workspace answers
  `HookReply::default()` — no injections — on every phase. **[src]**
- **The one exception is memory, and it goes to the system prompt rather than mid-conversation.**
  `inject_memory_reminder` (`xai-chat-state/src/actor/request_builder.rs:189`) upserts a
  `<memory-context>` block into `items.first()`'s `SystemItem` on the first turn, after which
  `conversation_has_memory_context` short-circuits forever. The source states the reason: *"a
  re-scored block would mutate the system-prompt prefix and bust the KV cache for the whole
  downstream conversation."* Post-compaction recovery of the same content goes back through the
  reminder path as a user message. **[src]**
- **Neither grok-build nor Claude Code writes down why.** grok-build carries no comment explaining
  the choice, and the unused `System` / `Developer` hook variants suggest it was never
  litigated. **[src]**

**Takeaway.** grok-build is a second independent implementation that supports every backend where
the mid-conversation-`system` hazard exists and is immune only because nothing ever constructs the
dangerous item; Claude Code's `<system-reminder>` shape is the third data point. The convergence is
probably not "models dropped system support because harnesses tagged user turns" but the reverse:
Anthropic's Messages API never *had* a mid-conversation system role, so any harness spanning
providers needs a non-system channel for reference text, the `<tag>`-in-a-user-turn convention grew
to fill it, and models are now trained on enough of it that it carries real weight. **[unverified]**
Either way the operative fact is the one worth recording: the portable channel for mid-conversation
reference text is a user turn with an XML envelope. Pikuri moved to it wholesale —
`D_reference_text_as_user_turn`.

## R_persistence — How five harnesses persist a conversation and resume it

Surveyed August 2026 for issue #1 (`Agent#export_history` / `#load_history!`), because an exported
conversation is written to disk and is therefore a *file format*, not a return value — and every
harness here has already had to answer the same questions. Five systems read at the source:
**Claude Code** (its own transcripts on the author's machine, ~370 files, CLI
`2.1.220`–`2.1.247`), **opencode** (`5f5ea53`), **grok-build** (`9684fa3`), **PI** (`1defa15`) and
**hermes-agent** (`cced6fa`) — revisions in `R_sources`. Pikuri's own answers are the five history
entries in `design/decisions.md`; this entry is only what the others do.

| | container | ground truth | tool call ↔ result | attachments | per-msg tokens | schema version |
| --- | --- | --- | --- | --- | --- | --- |
| **Claude Code** | JSONL, one file per session, append-only | the JSONL itself | separate records, `id` ↔ `tool_use_id`, wire shape verbatim **plus** a parallel internal `toolUseResult` | base64 inline, duplicated into both shapes | yes, full `usage` + a `cost-state` rollup record | none (a CLI build `version` only) |
| **opencode** | SQLite; one row per *part* | the DB | one `tool` part, `state` transitions `pending→running→completed\|error` in place | base64 `data:` URI inline (5 MiB cap); `@file` text refs stay paths and re-read | yes, plus denormalized session columns | none per record; 30+ SQL migrations |
| **grok-build** | dir per session: append-only `updates.jsonl` + derived `chat_history.jsonl` + N sidecar JSONs | `updates.jsonl` (the wire/event log) | separate items linked by `tool_call_id` | base64 inline, 1.5 MB cap, strip-invalid-on-load | no — per **turn**, on a `TurnCompleted` event | `schema_version` on checkpoints only |
| **PI** (shipped) | JSONL, one file per session | the JSONL | call inside the assistant message, result a separate entry | base64 inline | yes, on the message | `version` 1→2→3 with real migrations |
| **hermes-agent** | single SQLite `state.db` | the DB | plain columns | base64 inline | yes | `SCHEMA_VERSION = 26`, additive |

**[src]**, except the Claude Code row — **[verified 2026-08, CLI 2.1.220–2.1.247]**, read from
transcripts rather than source.

### The one thing all five agree on: repair dangling tool calls on the way *out*

An assistant turn carrying tool calls plus the results answering it is one indivisible unit on the
wire; an orphan on either side is a hard 400 from OpenAI and Anthropic alike.

- **Every system surveyed handles the interrupted case, and every one repairs when *building the
  request*, leaving the stored record untouched.** **[src]**
- **opencode** turns any part still `pending`/`running` into a synthetic `output-error` while
  assembling the payload, with the reason in a code comment: *"Anthropic/Claude APIs require every
  tool_use to have a corresponding tool_result"* (`session/message-v2.ts:349`). **[src]**
- **opencode runs no boot-time reconciliation after a SIGKILL** — the read-time rule suffices
  precisely because the constraint is enforced on every request regardless of what is on
  disk. **[src]**
- **grok-build**'s `repair_dangling_tool_calls` splices a synthetic result (*"cancelled by the
  user (tool `X` was not executed)"*) into the derived cache, and `dedup_duplicate_tool_results`
  handles the opposite race — a cancelled call whose real result lands late, giving two results for
  one id — by keeping the last (`conversation.rs:2144`, `:2258`). **[src]**
- **hermes-agent**'s `repair_message_sequence` drops orphans at replay; the stored transcript stays
  untouched (`agent_runtime_helpers.py:562`). **[src]**
- **PI's in-flight rewrite is the most elaborate**: commit *intent* before running the effect, in a
  `ToolStartedRecord` carrying a pre-reserved `resultEntryId` and `replay: "never" | "safe"`. On
  restart a `"safe"` (read-only) call re-executes with the persisted arguments; anything else gets
  a synthetic `"interrupted"` result under the reserved id (`session/types.ts:150`). Nothing unsafe
  runs twice, and every call ends with a result. **[src]**
- **PI shipped is the counter-example proving the rule**: no repair at all, replays the dangling
  call as-is, and depends on the provider tolerating it. **[src]**

### Nobody versions the record; evolution is additive-only

The most useful negative result in the survey.

- **No system surveyed carries a per-record schema version it migrates on.** **[src]**
- **Claude Code** stamps the CLI build (`"version":"2.1.233"`) on every record, not a format
  version; envelope keys are byte-identical between a `2.1.220` transcript and a `2.1.247`
  one. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **opencode**'s `SessionTable.version` is likewise the installing app version. Its 30-odd SQL
  migrations add columns and backfill them; a grep for `json_set` / `json_remove` / `json_insert`
  across all of them finds none — the stored JSON blob's shape has only ever grown. **[src]**
- **grok-build** achieves the same with `#[serde(default)]` on every post-v1 field, doc comments
  stating the intent (*"`None` for sessions created before this field was added"*), and
  `deny_unknown_fields` applied **only** to tool-argument schemas and wire protocols, never to a
  session type. **[src]**
- **PI shipped is the exception** — a real `CURRENT_SESSION_VERSION = 3` with ordered in-place
  migrations — and its own rewrite keeps the idea while adding what shipped code lacks:
  *"version > current → refuse to open (older binary, newer session)"* (`harness.md:2734`). **[src]**

Two refinements worth more than the headline:

- **Split strictness by consequence, not uniformly.** grok-build's general chat loader skips a bad
  line, quarantines the file to `*.jsonl.corrupt` and warns — availability matters more there. Its
  *compaction checkpoints* hard-refuse an unknown `schema_version` (`replay.rs:380`), because a
  wrong load silently replaces what the model sees. Same codebase, opposite policies, chosen by
  what getting it wrong costs. **[src]**
- **An unknown enum value must decode to the inert variant.** grok-build's `GoalStatus` maps
  anything unrecognized to `UserPaused` via a custom `Deserialize`, with the reason in the doc
  comment: *"a corrupt or forward-version snapshot can never resurrect as a self-driving goal"*
  (`goal_tracker.rs:8`). **[src]**

### Strict-on-load: PI reversed itself

The clearest evidence available, because it is one project's before and after.

- **PI's shipped loader try/catches each line and silently skips what will not parse**
  (*"Skip malformed lines"*, `session-manager.ts:299`), with a second comment conceding the
  liability: *"Session files are parsed without validation; old versions, forks, or hand-edited
  files can contain messages with null/missing content"*. **[src]**
- **Its in-flight rewrite does the opposite** — strict field-by-field decoding, `JsonlDecodeError`
  on any bad record, and the whole session fails to load. **[src]**
- **The one carve-out is worth copying verbatim**: a torn last line from a crash mid-append is
  normal, not corruption, so it is repaired by truncating to the last valid line
  (`jsonl/storage.ts:84`) while interior corruption still throws. The write side pairs with it —
  `publishFileAtomically`, temp file plus atomic rename. **[src]**
- **opencode is the cautionary tale**: its import path validates with a hard-throwing decoder *and*
  is non-transactional, inserting the session row before looping over messages — so a bad record
  partway through leaves a half-imported session with no rollback
  (`cli/cmd/import.ts:196`). **[src]**

### Tree, linear, or append-only log — the rewind question

Three genuinely different containers, and the choice is about whether history can be *edited*.

- **Claude Code: a real tree.** Every conversation record carries `uuid` + `parentUuid`, and a
  `last-prompt` record's `leafUuid` names the active tip; editing a message or regenerating appends
  a new branch and the abandoned one is never deleted. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **Branch points are common in practice**: scanning sampled transcripts found shared parents in
  about two-thirds of the larger files, one with eleven. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **PI (shipped): also a tree** — `SessionEntryBase.parentId`, with `getBranch` / `getTree` on the
  read API. **[src]**
- **grok-build: append-only log plus markers.** `updates.jsonl` is never truncated; a rewind
  appends a `RewindMarker` and a replay algorithm interprets it. **[src]**
- **opencode: linear, with a hard delete.** Revert stores only a marker and restores a filesystem
  snapshot — fully undoable — until the next turn supersedes it, at which point `cleanup` actually
  deletes the reverted-away messages. No branching model, no tombstones. **[src]**
- **Claude Code splits records into two disjoint kinds**: tree nodes (carrying `uuid` /
  `parentUuid`) and unparented *current-state* records (`mode`, `permission-mode`, `last-prompt`,
  `ai-title`, `cost-state`, `queue-operation`) that are last-one-wins on replay. One append-only
  stream, two semantics; a reader reconstructing message history can ignore the second kind
  entirely. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **Its records are finer-grained than an API message**: an assistant turn with thinking + tool_use
  + text is *three* JSONL lines chained by `parentUuid`, never one record with a three-element
  content array. **[verified 2026-08, CLI 2.1.220–2.1.247]**

### Where out-of-band state goes: four answers

Nobody folds everything into the transcript, and nobody leaves it all out.

- **grok-build — a file per subsystem** in the session dir: `goal/state.json`, `plan.json`,
  `plan_mode.json`, `signals.json`, `announcement_state.json`, plus `summary.json` for
  cwd/model/sandbox/title. **[src]**
- **grok-build keeps folder trust out of the session entirely** — a global
  `~/.grok/trusted_folders.toml` keyed by path. **[src]**
- **Claude Code — unparented records in the same file**, plus a sibling
  `~/.claude/file-history/<session>/` holding versioned file backups outside the
  JSONL. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **opencode — typed columns on the session row**: `permission` ruleset, `directory`, `agent`,
  `model`, with todos in their own table. **[src]**
- **PI — an opaque slot inside the transcript.** `CustomEntry` / `CustomMessageEntry` are
  documented as exactly that: *"Persist extension state across session reloads"*
  (`session-manager.ts:104`). **[src]**
- **PI's shipped session model otherwise persists the conversation and its cost and nothing
  else** — no todos, no permission grants, no file-read state. **[src]**

The rule that reconciles all four: **state whose lifecycle matches the conversation may ride in the
conversation; state with a different lifecycle must not.** Folder trust is the clinching case — a
trust decision has to outlive any one session, so a session file would be the wrong home.

### The system prompt is regenerated, never replayed

- **Four of five regenerate.** Claude Code stores no `role: "system"` record anywhere (confirmed
  across every sampled transcript) **[verified 2026-08, CLI 2.1.220–2.1.247]**; grok-build never
  persists a `System` chunk **[src]**; opencode builds the prompt fresh each turn **[src]**; PI
  recomputes it per load **[src]**.
- **PI adds the refinement the others lack**: it persists an explicit *override* when one was set
  (`OperationStartedRecord.intent.systemPromptOverride`), separating "the prompt is assembled from
  current state" from "someone deliberately pinned this text". **[src]**
- **Only hermes-agent stores the prompt**, deduped through a `system_prompts(hash→prompt)` table —
  a storage trick for auditing, not a replay source. **[src]**
- **Claude Code logs each mid-conversation injection as its own typed, parented `attachment`
  record** — `skill_listing`, `task_reminder`, `total_tokens_reminder`, `deferred_tools_delta`,
  `command_permissions`, `edited_text_file`, `agent_listing_delta`, `queued_command` — so the
  prompt is regenerated but every individual thing the harness slipped into the conversation stays
  durably logged and distinguishable, rather than dissolving into opaque user
  text. **[verified 2026-08, CLI 2.1.220–2.1.247]**

### Attachments: everyone inlines base64; nobody has a blob store

- **Unanimous across the five**, with caps the only variation: opencode 5 MiB per image, grok-build
  1.5 MB with a re-encode-if-over normalizer. None writes attachment bytes to a sidecar file or a
  content-addressed store. **[src]**
- **opencode is not uniform about it.** Pasted images and tool-result media inline as `data:` URIs,
  but an `@file` mention of a *text* file stores `file://<path>` and re-reads live content at every
  send — so a resumed session is only self-contained for some part types. **[src]** This reads as
  drift rather than design. **[unverified]**
- **grok-build strips invalid images on load** rather than ignoring them, so a stale poison image
  cannot 400 every subsequent turn (`replay.rs:405`). **[src]**
- **Claude Code stores the bytes twice** — once in the wire-shaped `message.content` and again in
  the internal `toolUseResult` — the cost of keeping both
  shapes. **[verified 2026-08, CLI 2.1.220–2.1.247]**

### Reasoning signatures: verbatim, and scoped to the producing model

- **Every system preserves provider-opaque reasoning state byte-for-byte**, and the field names say
  what they are for: PI's `thinkingSignature` (*"Provider-specific opaque or serialized reasoning
  replay data"*) plus `redacted` for safety-filtered blocks whose encrypted payload still has to
  ride along for multi-turn continuity; grok-build's `ReasoningContent { text, encrypted, id }`
  (*"Encrypted reasoning content (Responses API only). This can be passed back to the API"*);
  hermes' Codex-specific `codex_reasoning_items`, explicitly exempted from message-merging so the
  encrypted chain is not corrupted; Claude Code's opaque ~400-char `signature` on every thinking
  block. **[src]**
- **A signature is only valid for the model that produced it.** opencode degrades a reasoning part
  to plain text and drops the provider metadata when a session resumes under a different model
  (`message-v2.ts:362`). **[src]**
- **opencode preserves an *empty-text* separator part on purpose**, because dropping it "shifts
  signed thinking positions" for Anthropic adaptive thinking (`:262`) — the signature can cover
  position, not just content. **[src]**
- **grok-build keeps reasoning as a sibling item** rather than nested in the assistant message, for
  two stated reasons: parallel tool calls produce N reasoning blocks that would clobber each other
  under last-write-wins, and preserving the model's interleaved `[reasoning, tool_call, reasoning,
  …]` order byte-stably is what lets the server-side prefix KV-cache hit
  (`conversation.rs:87`). **[src]**

### Ground truth vs derived cache

The pattern shared by the two most-evolved systems, and it reframes what an exported history *is*.

- **grok-build treats the append-only wire/event log as authoritative and the model-facing
  transcript as a rebuildable cache.** `chat_history.jsonl` is regenerated from `updates.jsonl`
  whenever its format version is stale or the file is empty, via temp-file-then-rename. Its own
  export code says so: *"Uses `updates.jsonl` (ACP SessionNotifications) as the source of truth,
  not `chat_history.jsonl` which is only for LLM API calls"* (`session/export.rs:1`). **[src]**
- **grok-build's compaction never truncates the log** — it appends a checkpoint marker pointing at
  a sidecar file, so the system can reconstruct *either* the compacted view or the raw one from the
  same log. **[src]**
- **Claude Code is the same shape with the roles less separated**: the JSONL is the record, and
  what goes to the model is derived from it by walking the
  branch. **[verified 2026-08, CLI 2.1.220–2.1.247]**

The corollary for a *message-list* format like pikuri's: it is the derived artifact, not the
record — which lowers its stability bar rather than raising it. If the host keeps an event log, a
bad export is regenerable.

### Sub-agent conversations

- **Claude Code keeps them in physically separate files** — `<session>/subagents/agent-<id>.jsonl`
  plus a small `agent-<id>.meta.json` carrying `agentType`, `toolUseId` (linking back to the
  spawning tool call in the parent transcript) and
  `spawnDepth`. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **Every record inside carries `isSidechain: true` and its own `parentUuid` tree rooted at
  `null`**, so the flag partitions files rather than interleaving one stream: the main transcript's
  size stays proportional to the main conversation, and a viewer can skip loading sub-agent detail
  unless asked. **[verified 2026-08, CLI 2.1.220–2.1.247]**

## R_error_handling — What each project does with a malformed call, a recoverable failure and a bug

| | Tool argv malformed | Tool execute failure (recoverable) | Tool execute failure (bug) |
| --- | --- | --- | --- |
| pikuri | `"Error: <msg>"` string fed back to model (with full schema reprinted by `Tool::Parameters`) — pikuri's validator runs *before* ruby_llm's would | `"Error: <msg>"` string by tool convention; ruby_llm passes it through verbatim to the next observation | raises through ruby_llm; kills the loop |
| ruby_llm | `{ error: "..." }` hash sent to model | tool returns whatever; exceptions **bubble up** to host (not caught) | bubbles up to host |
| langchainrb | tools are expected to handle and return `tool_response(content: "...")` — failures surface as observation text; required-key validation happens at JSON Schema export, not at run time | tool returns whatever; `execute_tools` catches any exception, logs it, and transitions to `:failed` state — loop ends, host inspects | same as recoverable — caught at the `execute_tools` boundary |
| pi | caught and wrapped as `ToolResultMessage` with `isError: true` | caught and wrapped as text `"Error: <msg>"` | caught and wrapped (same path) |
| opencode | tool catches Effect Schema decode failure and returns "rewrite the input..." text | text observation | caught and converted to `MessageV2.ErrorPart`; loop continues |
| grok-build | typed `ToolError` returned to the model; several classes of malformed argv are *absorbed* rather than rejected (a stringified integer, a JSON-encoded array where an array was expected), and a wrong-namespace call gets a corrective ("call it directly") instead of a generic error | typed `ToolError` observation, with `<system-reminder>` hints appended; `xai-circuit-breaker` guards repeatedly-failing external legs | `anyhow` up through the actor; the session survives and reports |

**[src]** for every row but pikuri's.

- **ruby_llm shares pikuri's philosophy**: `Chat#handle_tool_calls` calls `.to_s` on whatever the
  tool returns and writes it as the tool message's content, so a `"Error: …"` String flows through
  to the model unchanged, and an exception bubbles to the host. **[src]**
- **langchainrb, pi and opencode all trap everything at one boundary**: langchainrb at
  `execute_tools` with a transition to `:failed`, pi by wrapping into a `ToolResultMessage`,
  opencode by converting to a `MessageV2.ErrorPart` and continuing the loop. **[src]**
- **grok-build absorbs the model's input errors where it can confidently fix them**: its readers
  accept `"-3"` where `-3` was declared, its edit tool accepts a JSON-encoded string where an array
  was declared, and `use_tool` answers a native tool name with "call it directly". **[src]**
- **grok-build guards repeatedly-failing external legs with a circuit breaker**
  (`xai-circuit-breaker`) rather than letting the model keep retrying. **[src]**

**Takeaway.** Pikuri's split — recoverable failures become observations, bugs raise — is explicit
in `pikuri-core/lib/pikuri/tool.rb` and survives the survey unchanged. The trap-everything posture
is what you want when the agent is long-running and unattended; the raise-on-bugs posture is what
you want during development, and pikuri's carve-out for loop-secondary best-effort paths (the
context-window probe hitting a wedged server) keeps the agent alive when the failure is cosmetic.

grok-build adds a third axis pikuri's split does not cover: *when the model's input is wrong in a
way you can confidently fix, fix it.* Each absorbed error is a round trip the model does not spend.
That sits uneasily against pikuri's strict-validator-with-DidYouMean bet, which spends the round
trip deliberately to teach the schema — and the honest reading is that the two optimize for
different things. A first-party model vendor can fix the model; pikuri can only fix the harness, so
the corrective error message is doing more work here than it does there. A real fork, noted rather
than adopted.

## R_permissions — What each project does about permissions and sandboxing

The pikuri entry is the reference column; everything else carries its provenance.

- **pikuri**: three seams. `Workspace::Filesystem` is one concrete class with explicit
  `project_root:` / `readable:` / `writable:` / `temp:`, routing every coding tool's paths through
  `#resolve_for_read` / `#resolve_for_write` and rejecting `..`-escapes and symlinks that resolve
  outside a declared root; `Filesystem::AllowAll` is the `--yolo` variant, same accessor surface
  but accepting any path *except* a hardcoded credential denylist (`~/.ssh`, `~/.aws`, `~/.gnupg`,
  `~/.kube`, `~/.docker`, `~/.netrc`, `/etc/shadow`, …). `Workspace::Confirmer` gates
  state-mutating tools through `#confirm?(request:)`, all presentation owned by the confirmer.
  `Code::Bash::Sandbox` is the third seam, governing the bash subprocess's filesystem view rather
  than what the LLM observes: `Sandbox::Bubblewrap` composes a `bwrap` argv from
  `workspace.readable` / `writable` plus a curated `/etc` baseline and per-toolchain *content-only*
  ephemeral overlays, so credentials in `~/.gradle/gradle.properties`, `~/.m2/settings.xml` or
  `~/.cargo/credentials.toml` never appear in the sandbox and writes vanish at process exit. Its
  threat model is blast-radius containment and cross-project contamination, not malware resistance;
  construction refuses if any workspace root contains a container/VM control socket. Every
  subprocess in any `pikuri-*/lib/` goes through `Pikuri::Subprocess.spawn`, one entry point that
  creates a process group per invocation and SIGTERMs everything tracked at exit. Opencode-style
  glob rules are deferred (`design/ideas/coding-agent.md`).
- **ruby_llm**: nothing — out of scope for an SDK. **[src]**
- **langchainrb**: nothing. `Tool::FileSystem` reads and writes anywhere the host process can, and
  `Tool::RubyCodeInterpreter` uses `safe_ruby`, a whitelist-based sandbox the README itself notes
  is "in need of a better solution". **[src]**
- **pi**: a `beforeToolCall` extension hook can return `{ block: true, reason: "..." }`; no built-in
  UI prompt, safety delegated to the host or an extension. **[src]**
- **opencode**: declarative, glob-aware rules (`src/permission/index.ts`) with three actions —
  `allow` / `deny` / `ask`. On `ask`, execution pauses via a `Deferred`, the bus emits a request,
  and the UI replies "once" / "always" / "reject"; denial returns a typed error to the
  model. **[src]**

  ```ts
  {
    "*": "allow",
    question: "deny",
    plan_enter: "deny",
    repo_clone: "deny",
    read: { "*": "allow", "*.env": "ask", "*.env.example": "allow" },
    external_directory: { "*": "ask", ...whitelistedDirs: "allow" },
  }
  ```

- **grok-build**: the most developed of the six on both axes, and the only project here whose OS
  sandbox covers the *agent's own process* rather than just its shell subprocess. **[src]**

**Takeaway.** Pikuri's three seams are the v1 answer for an interactively supervised agent.
opencode's three-action glob model is the obvious next step on the *permission* axis once friction
shows up; the seams are already in place to swap implementations without touching tool internals.
Bubblewrap is not malware-resistant — network egress stays open by design and in-project mutation
is on the table — so adversarial isolation still needs a container or VM around pikuri, with
bubblewrap as the inner layer. langchainrb is the cautionary tale: `FileSystem.read_file` /
`write_to_file` take arbitrary paths from the LLM with no validation.

### Pikuri vs. Claude Code: structural vs. operational defense

Claude Code is not in the project table (it is closed-source), but it is the reference coding agent
the others are shaped after, and its security model is the instructive contrast.

- **Claude Code's main agent holds all three legs of the lethal trifecta at once** — private data,
  untrusted content, egress — across `Read` / `Write` / `Edit`, `Bash`, `WebFetch` / `WebSearch`
  and MCP. It does not attempt a trifecta-break. **[verified 2026-08, CLI 2.1.220–2.1.247]**
- **Its defense is operational, in three layers**: (1) human-in-the-loop permission gating
  (`allow` / `deny` / `ask` rules, permission modes); (2) an OS sandbox (`sandbox-exec` /
  bubblewrap) plus working-directory confinement and a trust-this-folder gate; (3) model-level
  injection resistance plus platform-side monitoring. **[docs]**

**Takeaway.** Pikuri defends *structurally* — remove a leg per agent, so the agent that touches
untrusted content cannot act on an injection, a property of the capability graph that holds even
against a fully injected model. The asymmetry worth recording is that Claude Code's first two
defenses were never primarily injection defenses: the human gate is a *mistake* control (it catches
the hallucinated `rm -rf` whether or not an attacker is involved) and the sandbox is a
*code-execution* control (it bounds blast radius regardless of cause). They blunt injection as a
side effect, so they survive the threat model shifting. Pikuri's trifecta-break is *specifically*
an anti-injection bet, which makes it the one defense that goes obsolete if data-vs-instruction
separation is ever solved — the lethal trifecta is lethal only because injection exists. The flip
side in pikuri's favour: a model's own injection resistance is the one leg living *inside* the
component an injection compromises, so it cannot be leaned on alone, and neither project does.

Where they converge: pikuri cannot break the trifecta for its own coding agent either —
`bin/pikuri-code` holds `read` + `bash` + `fetch` on the parent and falls
back to system-prompt nudging plus the `Confirmer` (SECURITY.md "Non-goals"). Coding is the harness
where the structural model runs out and the operational one takes over. And Claude Code's visible
investment in reducing confirmation fatigue is the same conclusion driving pikuri's
confirmer-as-last-line-of-defense framing (`book/security.md` §"The human gate, and why fatigue is
the enemy"): for an *attended* coding agent the human gate is the load-bearing control, and its
whole value rides on not inducing fatigue. The shared nuance is deployment shape — the human gate
is worth zero *unattended* (cron, CI, a `minions` fan-out), where only structural defense or an
egress allowlist survives.

### Prior art deep-dive: PI's two isolation weights, opencode's permission system

The deeper survey of *how*, done while scoping pikuri's own security posture.

Common ground:

- **Neither has prompt-injection defenses.** No provenance markers on tool output, no "treat
  results as data" language in system prompts, no separate channels. **[src]**
- **Both cap tool output** at ~2000 lines / 50 KB, with the overflow spilled to a tempfile whose
  path is returned to the LLM. **[src]**
- **Both validate sub-agent privilege separation as the right shape** — PI via a `--tools`
  allowlist on the spawned child
  (`packages/coding-agent/examples/extensions/subagent/index.ts:267`), opencode via inherited
  parent-denies plus per-preset deny baselines
  (`packages/opencode/src/agent/subagent-permissions.ts`, `agent/agent.ts:178-220`). **[src]**

PI:

- **PI ships nothing security-related in core.** No permission system (only a 30-line example
  extension regex-matching `rm -rf` / `sudo` / `chmod 777`), no workspace constraint (paths resolve
  absolutely with `~` expansion, no `..` rejection — `core/tools/path-utils.ts:54-93`), bash
  unrestricted, no MCP, no provider warnings, no Dockerfile. **[src]**
- **The README's stance is one line: "Run in a container yourself."** **[docs]**
- **The lighter isolation extension is `sandbox`**: it wraps the `bash` tool only — bubblewrap on
  Linux, `sandbox-exec` on macOS — driven by `~/.pi/agent/extensions/sandbox.json`, with a default
  policy of network *on* behind an npm/pypi/github allowlist, deny-read for `~/.ssh` / `~/.aws` /
  `~/.gnupg`, and deny-write for `.env*` / `*.pem` / `*.key`
  (`packages/coding-agent/examples/extensions/sandbox/index.ts`). **[src]**
- **Only `bash` is wrapped** — `edit` / `write` / `read` execute outside the sandbox, so an
  injection that prefers `edit` over `bash sed` walks past it. **[src]**
- **Sub-agents spawn as separate `pi` child processes that do not inherit the `-e ./sandbox`
  flag** — no recursion. **[src]**
- **The heavier isolation story is Gondolin** (github.com/earendil-works/gondolin, a separate
  Apache-2.0 project from the same org): lightweight Linux micro-VMs (QEMU by default, experimental
  `krun` backend), explicitly stronger isolation than containers or namespaces, and the PI-side
  extension runs the *whole toolset* inside with the project mounted at `/workspace`. **[docs]**
- **Gondolin ships a programmable HTTP/TLS egress proxy with allowlists** — a real proxy that
  inspects what is leaving, not iptables. **[docs]**
- **Its VFS mounts are JS-configurable**: the host decides what filesystem the guest sees. **[docs]**
- **Its secret-placeholder pattern is genuinely novel prior art.** Guest env vars hold
  placeholders, not real values; the egress proxy substitutes the real secret only on outbound
  requests to allowlisted hosts, so `echo $STRIPE_KEY > attacker.com` fails twice — the env does not
  contain the real key, and `attacker.com` is not allowlisted. **[docs]**
- **Gondolin is also the substrate for `pi-chat`** (a Discord/Telegram → Claude bridge from the
  same org), one micro-VM per channel for multi-tenant isolation — though pi-chat's own docs say
  *"All outbound HTTP/TLS open by default"*, so the egress policy is available but not aggressively
  configured in that product. **[docs]**

opencode:

- **A three-action `allow` / `deny` / `ask` system keyed on `(permission-name, glob-pattern)`**,
  last-match-wins, default-`ask`, persisted to per-project SQLite for `always` approvals
  (`permission/evaluate.ts:11`, `permission/index.ts:140-145`). **[src]**
- **A tree-sitter bash parser derives sticky-approval prefix patterns** like `git status *`
  (`tool/shell.ts:261-265, 308-333`). **[src]**
- **Its `SECURITY.md` is explicit at the top**: *"OpenCode does not sandbox the agent. The
  permission system exists as a UX feature... it is not designed to provide security
  isolation."* **[docs]**
- **The workspace is soft**: out-of-tree access triggers an `external_directory` prompt rather than
  a denial, with no realpath or symlink resolution
  (`project/instance-context.ts:18-23`). **[src]**
- **MCP servers spawn as raw subprocesses inheriting `process.env`, with schemas loaded eagerly**
  (`mcp/index.ts:412-445, 513-549`). **[src]**
- **Sub-agent presets `general` / `explore` / `scout` use `"*": "deny"` with selective allows**, and
  parent denies propagate into the child. **[src]**
- **Skills load from arbitrary URLs with no signature or integrity check**
  (`skill/discovery.ts:54-104`). **[src]**
- **No egress controls, no provider warnings.** **[src]**

**Takeaway.** Five things are worth borrowing or considering: disk spillover for over-cap output
(per-tool byte caps already exist in `Bash` / `Read` / `WebScrape`; the missing piece is writing the
overflow to a tempfile and returning the path — cross-cutting version in
`design/ideas/security-open-questions.md`); sub-agent toolset narrowing, already shipped via
personas (`R_sub_agents`); opencode's `(permission-name, glob-pattern)` ruleset shape if `Confirmer`
ever expands beyond binary approve/deny; PI's credential-dir deny-read defaults, partially shipped
already as `Filesystem::AllowAll`'s denylist; and Gondolin's secret-placeholder pattern, which is a
structural defense against exfil-via-injection rather than "an approval prompt the user is no longer
reading" — heavyweight, needing an HTTP/TLS interceptor, and flagged as future thought. opencode's
"this is UX, not security" framing is the honest baseline pikuri's `SECURITY.md` borrows under
"Non-goals".

The mental model worth recording: PI ships no isolation in core and offers *two extensions of
different weights* — bash-only bubblewrap, and a full micro-VM. That makes it prior art for "ship
the sandbox primitive separately, let the user opt in at the weight they need", a different shape
from opencode's explicit "we're not a sandbox, run it in Docker yourself".

### Prior art deep-dive: grok-build's authorization pipeline and in-process sandbox

The strongest prior art in this file for pikuri's two deferred security threads — glob permission
rules (`design/ideas/coding-agent.md`) and agentic review of bash commands.

- **The authorization pipeline is ordered and documented.** Every tool call walks five stages: (1)
  `PreToolUse` hooks, which may deny but whose *allow* only declines to deny; (2) permission rules
  from every config source, merged and evaluated **by severity, not by order or file** — `deny` >
  `ask` > `allow`, so a global deny cannot be overridden by a project allow; (3) remembered
  per-command grants, scoped to the git repository root; (4) built-in auto-approvals for read-only
  tools and a curated read-only shell-command list; (5) the permission mode's prompt policy. **[src]**
- **Six modes span the range** from `default` (ask) through `acceptEdits`, `auto`, `dontAsk`
  (deny-by-default allowlists for CI) to `bypassPermissions` (`--yolo`). **[docs]**
- **Rules cover `Bash`, `Read`, `Edit`, `Grep`, `MCPTool`, `WebFetch`, `WebSearch`**, and
  grok-build reads Claude Code's `.claude/settings.json` directly. **[src]**
- **Commands are parsed and split on `&&`, `||`, `;`, `|` and newlines**, with `deny` / `ask`
  checked per segment; a command that cannot be split into simple segments (subshells, `$(…)`,
  backticks, background `&`, control flow) prompts as one unit. **[src]**
- **Segment checks strip env prefixes** (`RUST_LOG=debug …`) and peel a fixed wrapper set
  (`timeout`, `nice`, `ionice`, `chrt`, `stdbuf`, `env`); `sudo`, `xargs` and `nohup` are
  deliberately *not* peeled, and `deny` / `ask` also reach inside inline `bash -c` scripts. **[src]**
- **The read-only allowlist is word-boundary matched** (`ls` does not match `lsof`). **[src]**
- **Its exclusions are the education**: `tee` is off the list because it writes arbitrary files;
  `cargo check` because it compiles and runs `build.rs`, proc-macros and any
  `build.rustc-wrapper` from the repo; `rg --pre` because it spawns a preprocessor per file;
  `sort --compress-program=…` likewise. **[src]**
- **A git command whose local config installs an executable hook raises a prompt floor** —
  `core.fsmonitor`, a `diff.*.command` / `textconv` / `external` driver, or an
  `alias.<safe-subcommand> = !…` — because `git log` in a hostile repo is arbitrary code
  execution. **[src]**
- **A dangerous-command list** (`rm`, `chmod`, `chown`, `chgrp`, `chattr`, `pkill`, `kill`,
  `killall`, `git push`) never honours a remembered *prefix*, only an exact grant for the whole
  command; and where no rememberable grant could stop the prompt recurring, the "always allow" row
  is not offered at all rather than saving a rule that would not work. **[src]**
- **An honest documented footgun**: `allow` rules match the whole command string only, so
  `Bash(git *)` auto-approves `git status && rm -rf /`. The docs say so in as many words. **[docs]**
- **The sandbox inverts pikuri's posture**: `xai-grok-sandbox` applies Landlock (Linux) / Seatbelt
  (macOS) *once at process startup* via the `nono` crate, covering the agent's own `tokio::fs` calls
  as well as every child. Five profiles — `off` (default), `workspace` (read everywhere, write CWD +
  temp + `~/.grok`), `devbox`, `read-only`, `strict` — with custom profiles in
  `sandbox.toml`. **[src]**
- **Network is the mirror image of pikuri's `FullFsNoNet`**: open at the process level (the agent
  needs the LLM API) and blocked per-subprocess via seccomp, Linux only, explicitly a no-op on
  macOS. **[src]**
- **A custom profile's `deny` list is kernel-enforced for read *and* write/rename**, specifically to
  close the `mv secret x && cat x` bypass. On Linux that requires bubblewrap, and if bubblewrap is
  missing or any single deny path cannot be bound, grok-build refuses to start rather than run with
  denied paths exposed. **[src]**
- **Nested user namespaces are disabled inside the bwrap layer** so mount binds cannot be rearranged
  from within, and the seccomp filter rejects `clone` / `clone3` carrying namespace bits —
  grok-build blocks from inside its own sandbox the very primitive pikuri's sandbox is built
  on. **[src]**
- **Folder trust closes a gap pikuri has open.** A cloned repository can ship `.mcp.json`, a project
  `.grok/config.toml` carrying `[permission]` auto-approve rules and `[mcp_servers]` commands, or
  `.grok/lsp.json` — all of which the CLI would otherwise honour on `cd`-and-launch. grok-build's
  own module comment calls this **"a 1-click RCE / policy bypass"**, and it resolves a VS-Code-style
  trust decision once per workspace, before any repo-local server is spawned, with every loader
  consulting a cheap `project_scope_allowed` check. **[src]**
- **Two grants are deliberately provisional and never cached**: the "there were no repo configs"
  allow (so a config appearing after a `git pull`, or written by the agent itself, is re-checked)
  and the unrecordable-key case (cwd is `$HOME` or the filesystem root). **[src]**
- **No prompt-injection defense** — same as PI and opencode. Every hit for "prompt injection" in the
  tree is the benign sense, injecting text *into* the prompt. **[src]**
- **It does have a mechanical Unicode confusable pre-pass**, aimed at edit-matching failures rather
  than hidden instructions. **[src]**

**Takeaway.** The load-bearing tag in pikuri's `SECURITY.md` stands: three of the largest coding
agents in the world, including a shipped commercial one, all decline to claim an injection defense.
The six-mode permission system, the persisted grant store and the managed
`/etc/grok/requirements.toml` admin layer are enterprise-shaped and out of scope. Three things are
not:

- **The read-only shell-command list, with its exclusions** — the `git -c` / `textconv` / `!alias`
  finding in particular. If pikuri ever auto-approves a bash command, this list is the starting
  point, and re-deriving it independently would be negligent.
- **Folder trust.** `Skill::Catalog::Bundled` scans `.pikuri/skills`, `.claude/skills` and
  `.agents/skills` under whatever bases the host passes — typically the project root — so a cloned
  repository's skill names and descriptions land in the system prompt with no trust decision at all.
  The `skill` tool already tags a skill body `untrusted: :hard`, which is the right classification
  of the *content*; what is missing is a gate on the *source*. `Mcp::Registry` is host-supplied
  today, so skills are the live exposure.
- **Per-segment analysis before any policy decision.** `Confirmer` shows the human one command
  string; splitting on the shell operators and showing the segments — the way grok-build does
  before any rule matches — is a presentation change that costs nothing and directly serves the
  confirmer-fatigue argument in `book/security.md`.

## R_sub_agents — How each project delegates to a child agent, and what it ships by default

- **pikuri** (`SubAgent::SubAgentTool`, wired via `c.add_extension SubAgent::Extension.new(personas:
  […])`): the LLM-visible `agent` tool delegates to a fresh `Agent` by *persona name*. A `Persona`
  is a four-field record (`name`, `description`, `tool_names`, `system_prompt`); spawning runs the
  persona's prompt verbatim with the subset of `parent.tools` whose name appears in
  `persona.tool_names`, reusing the parent's tool *instances* so workspace and confirmer wiring
  travels along. The child's loop is unbounded, as the parent's is; `transport`, `cancellable`,
  `context_window_cap` and `streaming` travel through unchanged. Listeners propagate via the
  duck-typed `for_sub_agent(id:)` convention; controls do not use that hook — the policy is inlined
  in `SubAgentTool#execute` (shared parent `Cancellable` by reference, `nil` `Interloper`).
  Extensions are not inherited. Recursion is structurally impossible: no bundled persona lists
  `agent` in its `tool_names`.
- **ruby_llm**: no built-in sub-agent. **[src]**
- **langchainrb**: no built-in sub-agent. Multiple `Assistant`s could model one, but there is no
  first-class delegation, filtered-tool or control-propagation story. **[src]**
- **pi**: not in core; pushed to extensions. **[src]**
- **opencode's `task` tool** (`src/tool/task.ts:32–174`) creates a **new `Session`**, not just a new
  chat history — backed by SQLite, so sessions are inspectable and resumable. **[src]**
- **opencode's `task` takes an optional `task_id` to resume a prior subagent session**, derives
  permissions from the parent filtered to what the parent may do, can hand the child a different
  tool list (unavailable tools passed as `{name: false}`), and wraps the return in
  `<task_result>…</task_result>` tags. **[src]**
- **grok-build's `task` tool plus a coordinator actor is the most featureful of the six**: three
  built-in types (`general-purpose`, `explore`, `plan`) plus user-defined personas. **[src]**
- **grok-build's children are background by default** — the call returns a subagent id immediately,
  results are retrieved via `get_task_output` / `wait_tasks`, and `kill_task` cancels. **[src]**
- **grok-build's children are resumable** via `resume_from: <subagent_id>`, which keeps the child's
  full transcript and tool state so the parent only describes what changed. **[src]**
- **An `isolation` parameter can run the child in its own git worktree**
  (`session/worktree_pool.rs`). **[src]**
- **grok-build bounds recursion with a depth counter and a configurable maximum**, rather than
  pikuri's structural no-`agent`-in-the-persona rule. **[src]**
- **Its children receive a *compacted* copy of `CLAUDE.md`** rather than the full project
  instructions, with the tool description telling the parent to inline any convention the child
  actually needs. **[src]**
- **Each type's toolset is a named preset, and the read-only guarantee is a property of that
  preset**: the `explore` toolset omits bash "so exploration cannot mutate the workspace — the
  read-only guarantee is enforced by the toolset, not merely by the prompt." **[src]**

**Takeaway.** Pikuri's `agent` tool is closer in spirit to opencode's `task` than to a "filter the
parent's tools" model: each delegation is identified by a *persona* the host registers explicitly,
so the child's toolset and system prompt are declared up front rather than inherited and trimmed.
That is where privilege separation comes from — a `FILE_MINER` spawned from a coding agent with
`bash` in scope still does not get `bash`. opencode's session persistence and resumability is a
fair amount of machinery for one feature, not worth porting until pikuri has another reason to
introduce a session store.

The sentence in grok-build's source — *"the read-only guarantee is enforced by the toolset, not
merely by the prompt"* — is worth quoting because it is pikuri's structural-defense argument,
arrived at independently by a team with no stake in pikuri's framing, and written as a code comment
rather than a security claim. Two projects reaching the same conclusion from opposite directions
(pikuri from the lethal trifecta, grok-build from "what does `explore` need") is the strongest
external validation of the persona model here.

Where grok-build goes further and pikuri deliberately does not: **resumability** (a follow-up costs
one delta instead of a re-run) and **worktree isolation** (parallel children editing the same repo
without colliding). Both are the same trade opencode's `task` makes — real capability for a session
store's worth of machinery. `GIT_REPO_RESEARCHER` already does the throwaway-workspace half for the
read-only case; the worktree variant is what a *writing* sub-agent would need, and pikuri has none.

### Bundled persona inventory

What ships by default, as against how the mechanism works. Each project picks a different mid-line
between "ship nothing, the host wires everything" and "ship the whole zoo."

| Project | Personas shipped | Source |
| --- | --- | --- |
| pikuri | `RESEARCHER` (web_search/web_scrape/fetch); `FILE_MINER` (file_list/read/grep/glob); `GIT_REPO_RESEARCHER` (git_clone + file_list/read/grep/glob + web reads, per-invocation temp workspace) — queued: `reviewer` | `pikuri-subagents/lib/pikuri/sub_agent/{researcher,file_miner}.rb`; `pikuri-code/lib/pikuri/code/git_repo_researcher.rb` |
| ruby_llm / langchainrb | none — no sub-agent surface | — |
| pi | `planner`, `reviewer`, `scout`, `worker` | `packages/coding-agent/examples/extensions/subagent/agents/` |
| opencode | `build`, `plan` (primary modes); `general`, `explore`, `scout` (subagents); `compaction`, `title`, `summary` (hidden housekeeping) | `packages/opencode/src/agent/agent.ts` |
| Claude Code | `general-purpose`, `Explore`, `Plan`, `statusline-setup`, `claude-code-guide` | <https://code.claude.com/docs/en/sub-agents> |
| grok-build | `general-purpose`, `explore`, `plan` (+ user-defined personas, + an orchestrator mode on the main agent) | `crates/common/xai-tool-types/src/task.rs`; toolsets in `xai-grok-agent/src/config.rs` |

**[src]** for every row but pikuri's and Claude Code's; Claude Code's is **[docs]**.

Cross-cutting by role:

| Role | pikuri | pi | opencode | Claude Code |
| --- | --- | --- | --- | --- |
| read-only recon (cheap model) | `RESEARCHER` (web) + `FILE_MINER` (fs) + `GIT_REPO_RESEARCHER` (clone-and-dig) | `scout` (Haiku) | `explore` + `scout` | `Explore` (Haiku) |
| planner (read-only, intent-shaping) | — | `planner` (Sonnet) | `plan` (primary mode, not subagent) | `Plan` |
| reviewer (read-only correctness) | queued | `reviewer` (Sonnet, bash for git) | — | — |
| general-purpose catch-all | — (escape hatch documented in `design/ideas/subagent-deferrals.md`) | `worker` | `general` | `general-purpose` |
| infra housekeeping | — | — | `compaction`, `title`, `summary` (tools: none) | — |
| UX helpers (slash-command-driven) | — | — | — | `statusline-setup`, `claude-code-guide` |

- **grok-build's three built-ins are the same three Claude Code ships** (`general-purpose` /
  `explore` / `plan`), which makes that trio look like a settled convergent answer rather than one
  vendor's taste. **[src]**
- **grok-build also has an orchestrator mode** — not a subagent but a system-prompt body appended to
  the main agent, telling it to delegate coding and exploration and to treat subagents "as expert
  peers, not junior helpers". A prompt-level answer to the problem opencode solves with primary
  modes. **[src]**
- **opencode mixes primary modes and subagents in one registry** — `build` and `plan` are modes of
  the main agent, not delegated children. pi and Claude Code keep modes separate from
  subagents. **[src]**
- **opencode's hidden housekeeping agents** (`compaction` / `title` / `summary`) dress LLM-driven
  internal workflows up as personas with `tools: none`. **[src]**
- **pi ships its personas under `examples/`**, leaving the inventory a per-host decision rather than
  a harness-core fact. **[src]**
- **Only pi pins a model per persona** — Haiku for `scout`, Sonnet for the rest. **[src]**

**Takeaway.** Pikuri ships a lean set — three against pi's four, opencode's eight and Claude Code's
five — which matches the read-it-in-an-evening ceiling: ship the personas that demonstrate the
mechanism along each axis, document the rest as queued in `design/ideas/subagent-deferrals.md`, and
let downstream gems publish more. `RESEARCHER` and `FILE_MINER` are the direct analogues of pi's
`scout` / opencode's `explore` / Claude Code's `Explore`, split by *what* gets read;
`GIT_REPO_RESEARCHER` is a third axis with no direct analogue in the set — the closest move
elsewhere is letting `bash` (with `git`) reach inside a sandbox, where the persona shape collapses
that into one privilege-separated delegation with no `bash` in scope. Pikuri covers `explore` three
times over and covers neither `plan` nor `general-purpose`; "planner = read-only + intent-shaping"
is now four-for-four across the projects that ship personas at all, and pikuri has not committed
either way. opencode's hidden-housekeeping trick is worth knowing if compaction ever lands
(`design/ideas/context-overflow-behavior.md`) — pikuri's one equivalent, a hard-coded
step-exhaustion synthesizer, went with the step limit (`D_no_step_limit`). Per-persona model pinning
is deferred in `design/ideas/subagent-deferrals.md`, since it needs `ChatTransport` variations per
sub-agent.

## R_skills — How each harness discovers, advertises and gates Agent Skills

- **pikuri**: the `pikuri-skills` gem — `Skill::Catalog` (abstract base) + `Catalog::Bundled`
  (on-disk scanner) + `Skill::Renderer` (the XML) + `Skill::Extension` (the wiring) — implements the
  [Agent Skills standard](https://agentskills.io/specification). Discovery is **host-supplied, not
  walked**: `Catalog::Bundled.new(search_bases: […])` scans `.pikuri/skills`, `.claude/skills`,
  `.agents/skills` under each base it is given. Precedence is bases left-to-right then subdirs in
  that order, first name seen winning, so "project beats global" is the *typical wiring* rather than
  a rule the catalog enforces. One directory level only, each entry needing a `SKILL.md`;
  frontmatter validation is lenient — a missing `description` is the sole hard failure. Wiring is
  opt-in via `c.add_extension(Skill::Extension.new(catalog:, root:))`, which on a non-empty catalog
  contributes the `<available_skills>` block as a system-prompt snippet and registers the `skill`
  tool. `Catalog#roots` is exposed so the host can fold the skill dirs into the workspace's readable
  set, which is what makes a skill's sidecar files reachable through `read`. Flat `*.md` slash
  commands are a *separate* registry over the same search bases (`R_slash_commands`).
- **pi implements the same Agent Skills standard**; pikuri's implementation reuses pi's XML block
  shape so a skill folder authored against any compliant harness renders consistently. **[src]**
- **opencode ships its own skill mechanism** (related but pre-standard), and **v2 moved the
  inventory into the prompt** — `<available_skills>` renders into a system-context block
  (`core/src/skill/guidance.ts`, `SystemContext.Key "core/skill-guidance"`); only its docs page
  still claims the tool description carries it. **[src]**
- **opencode's block is *live* where pikuri's is assembled once.** It declares `baseline` / `update`
  / `removed` renders, so a mid-session change to the skill set arrives as a delta (*"The available
  skills have changed. This list supersedes the previous available skills list."*), and the whole
  block vanishes when the `skill` tool is denied. **[src]**
- **grok-build has the widest discovery net of anyone** — `.grok/skills`, `.agents/skills`,
  `.claude/skills` *and* `.cursor/skills`, at local / repo / user tiers, walking every directory
  between CWD and the repo root, deduplicated by name with higher tiers winning. **[src]**
- **Vendor compatibility is a config cell you can switch off per vendor** (`[compat.claude] skills =
  false`), and known vendor-shipped defaults (Cursor's `shell`, `canvas`, `statusline`) are always
  filtered out. **[src]**
- **grok-build's discovery deliberately ignores `.gitignore`** — teams gitignore `.claude/**` as
  local config yet still expect project commands to work. **[src]**
- **A `[skills] disabled` list keeps a skill listed but inert**, distinct from `ignore`, which hides
  it; and flat `*.md` under a `commands/` directory become user-invocable slash commands. **[src]**
- **grok-build also ships plugins** — a marketplace-installable bundle of skills + commands + agents
  + hooks + MCP servers, gated by the same folder-trust decision. **[src]**
- **grok-build's catalog is not a system-prompt block at all**: baseline and updates alike arrive as
  `<system-reminder>` injections, and a `paths:` frontmatter key holds a skill out of the listing
  until a tool reads or edits a matching file. **[src]**
- **ruby_llm and langchainrb have no concept of skills.** **[src]**

**Takeaway.** With opencode v2's move, pikuri, pi, Claude Code and opencode all render the listing
into the prompt and grok-build is the sole holdout. opencode's live block is the mechanism a
hot-reload would need and the one that costs a prompt-cache invalidation to run; pikuri scans at
boot and does not watch the filesystem, so it buys the cache instead.

### Nobody batches the load call

| harness | load tool input |
|---|---|
| pikuri | `name` |
| opencode | `name` (`core/src/tool/skill.ts`) — v1 and v2 both |
| grok-build | `skill` + optional `args` (`implementations/skills/skill.rs`), where `args` is the slash-command argument, not a batch |

- **Three independent implementations, none of which grew a `names: []`.** **[src]** Weak evidence,
  but it is the only evidence available.

**Takeaway.** pikuri needs no such parameter anyway: ruby_llm executes *every* tool call in an
assistant message (`chat.rb:346`, `tool_calls.each_value`), so `skill("cop")` + `skill("tuile")` +
a `read` in one message is already one round trip. An array would be a second way to do the same
thing, and would make the pathological case — four bodies in one shot — the easier one to type.

### The *human* path is zero-round-trip everywhere — by three routes

- **Neither surveyed harness optimizes the model's load path; both optimize the human's,
  identically** — by expanding the body at prompt-assembly time rather than routing it through a
  tool. **[src]**
- **opencode auto-registers every skill as a slash command whose `template` *is* the skill body**
  (`opencode/src/command/index.ts:142`). The `/skills` picker
  (`tui/component/dialog-skill.tsx`) injects nothing — it types `/<skill> ` into the prompt input,
  and the body lands as the user message. **[src]**
- **grok-build expands `/commit fix the build` into a `<skill_information>` envelope** appended
  after `<user_query>`, with a `<skills_referenced>` index of name + path. Its source calls this, in
  so many words, "the new zero-round-trip path". **[src]**

**Takeaway.** pikuri ships the same human path by a different route.
`Skill::Extension#schedule_load_skill` is the seam, and since `D_reference_text_as_user_turn` it
lands the body as a `<system-reminder>`-wrapped `:user` turn, so the `:system`-vs-`:user`
divergence that used to be the interesting difference here has closed on its own. `bin/pikuri-code`
wires it as the third leg of the typed-`/name` chain (host built-in > command > skill). Two real
differences remain: pikuri's `/name` skill leg is deliberately argument-less (a command is a
template with `$ARGUMENTS`; a skill body is fixed text, so there is nothing for an argument to do,
where grok-build routes both kinds through one mechanism), and pikuri declines the
auto-registration — the two-registry split (`D_slash_commands`) keeps a model-invoked, advertised
skill apart from a human-invoked, never-advertised command, because collapsing them would put a body
pikuri charges per *use* onto a surface charged per *install*. Both of pikuri's doors render through
the same `Renderer.format_skill`.

### Frontmatter: the six standard fields, and the nine invented ones

Verified 2026-08-16 against the spec and the same grok-build `SOURCE_REV` as the rest of this file.

- **The [Agent Skills spec](https://agentskills.io/specification) defines exactly six frontmatter
  fields.** **[docs]**

| field | purpose | pikuri reads |
| --- | --- | --- |
| `name` | skill identifier | yes — falls back to the parent directory name |
| `description` | what it does / when to use it | yes — the only hard requirement |
| `license` | license identifier | no |
| `compatibility` | free text, ≤500 chars, for a human | no |
| `metadata` | arbitrary client key-value map | no |
| `allowed-tools` | tools the skill may use | no |

- **None of the six expresses *when* a skill applies** — precisely the field every harness wanting
  conditional activation has had to invent. **[docs]**
- **grok-build invents nine, all at top level** (`discovery.rs:300–318`): `short_description`,
  `author`, `argument_hint`, `model`, `effort`, `user_invocable`, `disable_model_invocation`,
  `when_to_use`, `paths`. **[src]**

Four findings worth carrying:

1. **grok-build uses the sanctioned extension point *and* top-level keys.** `metadata` is *"an
   arbitrary key-value mapping … clients can use this to store additional properties not defined by
   the Agent Skills spec"*, with a recommendation to pick "reasonably unique" key names **[docs]**;
   grok-build parses it (`discovery.rs` `parse_metadata`), promoting `metadata.author` and
   `metadata.short-description` to typed fields and keeping the rest in a generic string map, and
   documents that in its user guide **[src]**. The nine extension keys sit at top level *alongside*
   that, which is off-spec for those nine — any could collide with a future official field — but the
   extension point is not declined. A harness adding a key therefore has a real fork with proven
   precedent on both sides: the top-level spelling buys two-harness agreement and inherits the
   collision risk, while `metadata: {<vendor>-<key>: …}` is spec-clean, agrees with nobody, and is
   nonetheless the shape grok-build itself reads. For a *newly invented* predicate there is no
   agreement to buy, so `metadata:` wins by default.
2. **An empty `paths:` marks a skill *unconditional*, not "never".**
   `…/skill_discovery_tracker/conditional.rs:38` gates on
   `s.paths.as_ref().is_some_and(|p| !p.is_empty()) && …`, so `paths: []` means always-listed — the
   opposite of what an author writing "this skill matches no paths" would intend. `paths: ["**"]`
   lands the same way: `normalize_skill_paths` (`discovery.rs:243`) drops empties, strips a trailing
   `/**` (`src/**` → `src`), and returns `None` when the result is empty *or* every pattern is `**`
   — and `None` is exactly how "unconditional" is spelled internally. **[src]**
3. **Unknown keys fail open, everywhere.** pikuri's `Catalog::Bundled#parse_skill` reads `name`,
   `description`, `paths` and `when-to-use` and drops the rest; Claude Code listed a skill carrying
   `argument-hint:` — a slash-command key, not a skill one — normally for months. A skill tagged
   with a key the host does not implement is simply advertised unconditionally, costing nothing and
   buying nothing until someone implements it. **[verified 2026-08-16, Claude Code 2.1.233]**
4. **`paths:` is not a grok-build invention — Claude Code implements it too.** Observed directly on
   2026-08-16 on **Claude Code 2.1.233**; the behaviour is undocumented, so it carries no
   compatibility promise and a later build may move it. Five skills under `~/.claude/skills` were
   annotated with `paths:`, and the four whose globs matched nothing read that session vanished from
   the session's skill listing, while `ideas-folder` (`design/ideas/**`) stayed — `design/ideas/*.md`
   had been read. Reading a single `.rb` file then caused exactly the two `**/*.rb`-gated skills
   (`writing-rdoc`, `tuile`) to be announced mid-session **with their full descriptions**, while the
   `**/*.java`- and `src/test`-gated ones stayed hidden. That is grok-build's shape precisely:
   withheld until a touched file matches, then promoted description-and-all.
   **[verified 2026-08-16, Claude Code 2.1.233]**

**The pattern dialect is gitignore's, on both harnesses — measured 2026-08-17.** grok-build's
`skill_matches_any` (`skill_discovery_tracker/conditional.rs:96–121`, `main`) hands every pattern to
an unmodified `ignore::gitignore::GitignoreBuilder` rooted at cwd and matches with
`matched_path_or_any_parents`; `coerce_path_list`'s own doc comment says a `{a,b}` group is left
intact *"for the gitignore matcher to expand"*. **[src]** Claude Code 2.1.233 was then probed
black-box — throwaway gated skills in a scratch project, each body revealing a magic word, the model
told to *invoke* the skill and report the verbatim result. That invoke-or-error signal is the sound
one: asking the model whether a skill was "available" contradicted itself across identical runs.
**[verified 2026-08-17, Claude Code 2.1.233]**

| `paths:` | file read | Claude Code | rule |
| --- | --- | --- | --- |
| `probeleaf` | `unrelated/file.txt` | `Unknown skill` | the gate holds |
| `probeleaf` | `probeleaf/file.txt` | activated | a direct hit fires |
| `probeleaf` | `nested/probeleaf/file.txt` | activated | **a slash-less pattern floats to any depth** |
| `/probeleaf` | `nested/probeleaf/file.txt` | `Unknown skill` | a leading slash roots it |
| `nested/probeleaf` | `deep/nested/probeleaf/x.txt` | `Unknown skill` | a slash *anywhere* roots it |
| `{alpha,beta}/**` | `beta/x.txt` | activated | a brace group expands |

**[verified 2026-08-17, Claude Code 2.1.233]**

- **That dialect is not minimatch**, which is what Cursor's `globs:` and GitHub Copilot's
  `applyTo:` — the same idea under two other names — take: there `*` never crosses a `/`, so `foo`
  covers neither `nested/foo/` nor anything beneath the directory, and a pattern copied in from
  either under-matches here. **[docs]**
- **Nor is it git's own gitignore**: git treats `{a,b}` literally (a `.gitignore` of `{a,b}/**`
  hides nothing under `git check-ignore`, while `rg` hides both directories), so the brace row is
  specifically ripgrep's flavour. **[verified 2026-08-17]**
- **"Hidden" means unreachable, not merely unlisted.** `skill(name: "writing-javadoc")` — on disk,
  valid frontmatter, `**/*.java` never touched — returned `Unknown skill: writing-javadoc`,
  *byte-identical* to the reply for a name that exists nowhere. A gated skill is indistinguishable
  from a nonexistent one, and the listing withholds the whole entry, name included: Claude Code
  ships grok-build's capability gate, not a visibility
  filter. **[verified 2026-08-17, Claude Code 2.1.233]**
- **That refusal came back as a *tool-execution* error, not a schema rejection**, so Claude Code's
  skill tool takes a free-form `name` rather than an enum of the active set. The two choices are a
  package — an enum of only-active names would have to be rebuilt on every promotion, churning the
  tool schema mid-session. **[verified 2026-08-17, Claude Code 2.1.233]**
- **The gate binds the human operator too, in both harnesses.** In a fresh Claude Code session,
  `/writing-rdoc` — a skill the operator wrote, whose name they typed from memory — returned
  `Unknown command: writing-rdoc`. **[verified 2026-08-17, Claude Code 2.1.233]**
- **grok-build does the same by construction**: `slash_skills()`
  (`skill_discovery_tracker/mod.rs:475`) combines `discovered_skills` with `startup_skills`, and
  `startup_skills` is what `take_unconditional` left behind after partitioning the gated ones into
  `ConditionalSkills::held` (`mod.rs:334-336`). `bridge.rs:411-415` calls that projection *"the
  authoritative source for slash command advertisement"*, and
  `SlashCommandSet::skill_resolvable` (`slash_commands.rs:659-665`) searches only it — so a gated
  name does not resolve when typed, not merely fail to autocomplete. **[src]**
- **The one accessor that reaches held skills has a single model-facing consumer.**
  `ConditionalSkills::held` — commented *"so registry-wide lookups can see skills the listing
  withholds"* — is consumed only by `suggest_skill_path`, a did-you-mean for a failed `SKILL.md`
  read. There is no operator escape hatch in either implementation. **[src]**
- **`paths:` is absent from grok-build's own user guide**, whose optional-frontmatter table
  documents ten other fields — so this is convergence on undocumented behaviour. **[docs]**
- **That guide documents `user-invocable: false` and `disable-model-invocation: true` as
  deliberately orthogonal axes for the two audiences** — which `paths:`, undocumented,
  collapses. **[docs]**
- **Bash does not count as a touch**: repeated `grep` / `sed` over `.rb` files through the shell
  promoted nothing across four separate turns, and a single `Read` of one `.rb` file promoted both
  `**/*.rb` skills at once. **[verified 2026-08-17, Claude Code 2.1.233]**
- **Promotion is once per conversation**: `ideas-folder` fired on the first `design/ideas/` read and
  never re-fired across a later read, a write and an edit in the same
  folder. **[verified 2026-08-17, Claude Code 2.1.233]**
- **The announcement carries the description only, never the
  body.** **[verified 2026-08-17, Claude Code 2.1.233]**
- **Claude Code did not render `when-to-use:` in those announcements**, so it implements at least one
  of grok-build's nine extensions and not another — "non-standard" is not one
  bucket. **[verified 2026-08-17, Claude Code 2.1.233]**
- **`compatibility` is the nearest existing field in spirit** — its own examples are *"Requires git,
  docker, jq"* and *"Designed for Claude Code"* — but it is free text aimed at a human judging "will
  this work in my environment". Nothing parses it, and it cannot carry a machine
  predicate. **[docs]**

**Takeaway.** The practical consequence for a shared skill folder is that annotating it is *not*
inert: `~/.claude/skills` is where most pikuri-visible skills actually live, so a `paths:` added for
pikuri's benefit changes Claude Code sessions today. And the load-bearing part is convergence: two
independent harnesses ship this predicate, which makes it an emerging extension rather than one
vendor's idea — and the strongest available argument that pikuri is *behind* on this axis rather
than declining to follow a fad.

### How grok-build's conditional activation actually works

Read 2026-08-16 against `main` at `5163763` — a newer monorepo sync than the `84ae1223` the rest of
this file cites, so treat this subsection as the later reading where the two disagree. grok-build is
the only harness whose *implementation* can be read, but per finding 4 above it is not the only one
shipping the feature, so read it as the documented reference implementation of a predicate two
harnesses honour.

1. **The trigger is a file the model *touched*, not a project shape.** `SkillDiscoveryReminder` runs
   after every tool call, but `extract_activation_paths` (`reminders/skill_discovery.rs:68`) yields
   paths from only four output variants — `ReadFile`, `ListDir`, `SearchReplace` and `ApplyPatch`
   (every file of a multi-file patch, rename targets included). Its comment is explicit that
   *"Bash/grep paths are excluded (unparseable / incidental)"*. So `paths: [build.gradle]` fires only
   when the model reads or edits that file; a `grep` hit, a `bash` invocation, or the file merely
   existing all fail to activate it. `paths:` cannot express "this is a Gradle project". **[src]**
2. **Matching is gitignore syntax; activation is sticky and session-scoped.** `skill_matches_any`
   (`conditional.rs:96`) builds an `ignore::GitignoreBuilder` matcher from the patterns relative to
   cwd and uses `matched_path_or_any_parents`, so a bare directory pattern matches files beneath it.
   Activated skills stay in `held`, gated by an `activated` set, so a re-seed can re-promote them;
   `/clear` calls `rehide()` (`conditional.rs:86`), which clears activations and re-partitions so a
   promoted skill drops back to held. **[src]**
3. **There is no resident skill catalog in the system prompt at all — the startup baseline is an
   injection too.** `<available_skills>` occurs in exactly one file repo-wide (the tracker's listing
   renderer); no prompt template renders it. `seed()` marks `pending = BaselineChange` and the first
   `take_pending()` emits the whole listing as a `<system-reminder>`, the same channel a later
   activation uses. A test is named for the property:
   `seed_produces_system_reminder_not_prompt_mutation` (`skill_discovery_tracker/mod.rs:1047`). **[src]**
4. **`when-to-use:` is a rendering split, and the renderer retro-fits it when the field is absent.**
   Parsed as either `when-to-use` or `when_to_use`, capped at 1024 chars like `description`.
   Rendered as `description — Use when: <trigger>` (XML) or a separate `Use when:` line. When the
   field is missing, `build_skill_entry` (`listing.rs:525`) derives one by splitting the
   *description* at the first of ten recognized connectives (`use this skill when`, `use when`,
   `triggers on`, `invoke when`, …, case-insensitive) and treating the tail as the trigger; the
   leading connective is stripped so the renderer's own label is not doubled, with a word-boundary
   guard so `Use whenever` does not match. A description that *opens* with a connective is left
   unsplit. The split takes everything after the first match, so trailing non-trigger prose lands in
   the trigger half. **[src]**
5. **Names-only listing exists, but only as budget overflow.** Per entry, `description` +
   `when_to_use` share a 400-byte cap, split proportionally to their lengths with a 20-byte floor
   each; the listing as a whole gets 50 % of the context window, and `name_only()` renders when that
   budget runs out. A comment at `mod.rs:446` records that a names-only footer for disabled skills
   was considered and rejected because it *"wastes tokens and looks like skills with no
   description"*. **[src]**
- **The spec's own client guide is behind its ecosystem on this point.**
  `agentskills.io/client-implementation/adding-skills-support` states that *"most implementations
  rely on the model's own judgment as the activation mechanism, rather than implementing harness-side
  trigger matching or keyword detection"* — and `paths:` glob matching is harness-side trigger
  matching, shipped by two of the four surveyed harnesses. **[docs]**

**Takeaway.** Two consequences of finding 3 are worth borrowing independently of `paths:`.
Promotion mutates no prefix, so it costs no prompt-cache invalidation — the cost that would
otherwise price conditional activation out on a provider that hoists system content. And skill
descriptions, which are attacker-influenceable text in a bundle that travels between harnesses, sit
in *conversation* position rather than the most-trusted slot in the request — which is where
untrusted text belongs, and which pikuri's own `<available_skills>` system-prompt snippet does not
do.

The pattern across all four harnesses is worth naming: **every one leaves the decision to model
judgment, and then bolts a nudge mechanism on beside it.** Claude Code and grok-build ship `paths:`;
grok-build adds `when-to-use` and a retro-fitting extractor for descriptions that lack it; opencode
v2 moved its inventory into the prompt to make the listing louder. Nobody trusts the description
alone, and nobody replaces it either. The reason is the capability/correction asymmetry
`book/skills.md` teaches: a tool description advertises a capability the model can feel the lack of,
so it only has to name what fills the gap — while a skill mostly advertises a *correction*, which
the model cannot miss the absence of, because nothing in the task tells it a relevance check is due.
No amount of description tuning closes that, which is why four independent harnesses converged on
adding a trigger. pikuri's `paths:` gate therefore follows the *implementations* rather than the
spec's guide, which is worth knowing before anyone cites that sentence as a reason not to gate. The
guide's two other recommendations pikuri does not follow are both decided on the record: an enum
`name` on the load tool is rejected in `D_skill_path_activation`, and exempting skill content from
context compaction is moot until something compacts.

## R_slash_commands — The human-invoked half, and what Claude Code's expansion actually does

- **Claude Code** reads `~/.claude/commands/*.md` (user) and `.claude/commands/*.md` (project),
  with subdirectories namespacing as `/frontend:foo`. Frontmatter: `description`, `argument-hint`,
  `allowed-tools`, `model`, `disable-model-invocation`. **[docs]**
- **Its body interpolates `$ARGUMENTS` and `$1`…`$9`, inlines a file with `@path`, and runs a shell
  command with `` !`cmd` `` *before the prompt is sent*** — gated only by that same file's
  `allowed-tools:`, i.e. by the untrusted file itself. **[docs]**
- **grok-build** takes flat `*.md` under a `commands/` directory. **[src]**
- **No harness in this survey defines an `.agents/commands` convention**, which is why pikuri scans
  two subdirs and not three. **[src]**
- **pikuri**: `Command::Registry` + `Command::Renderer` in `pikuri-skills`, over the same
  `Bundle::Base` search bases as the skill catalog. Names come from the path (a frontmatter `name:`
  is ignored — for a command the name is the *address the human types*), frontmatter is entirely
  optional, neither inlining leg ships (`` !`cmd` `` is refused outright and `@path` is left as
  literal text — `D_command_inlining_legs`), `allowed-tools:` is refused rather than silently
  widening a toolset its author asked to narrow, and `disable-model-invocation` is the default and
  only behaviour.

Measured against **Claude Code 2.1.233** (headless, throwaway project, each result reproduced on two
models), because three of its behaviours are documented nowhere:

- **The expansion is wrapped** in `<command-message>` / `<command-name>` / `<command-args>`, the
  last omitted when no arguments were typed. The wrapper carries no *location*, so it does not solve
  sidecar-path resolution. **[verified 2026-08, Claude Code 2.1.233]**
- **Arguments a body never references are appended** after two blank lines as
  `ARGUMENTS: <raw>`. **[verified 2026-08, Claude Code 2.1.233]**
- **`$n` is 0-based** — `/probed AAA BBB CCC` against `one=[$1] two=[$2] three=[$3]` yields
  `one=[BBB] two=[CCC] three=[$3]` — while being documented as 1-based and written as 1-based by
  every author, including in Claude Code's own shipped command
  files. **[verified 2026-08, Claude Code 2.1.233]**
- **An out-of-range `$n` stays literal.** **[verified 2026-08, Claude Code 2.1.233]**

**Takeaway.** pikuri ships a `(this command lives in …)` footer where the wrapper carries no
location, copies the `ARGUMENTS:` spelling verbatim so a body authored there reads identically here,
and implements `$n` as 1-based (`D_command_substitution`) while keeping the stays-literal half.

## R_mcp — Who supports the Model Context Protocol, and how they keep its surface cheap

- **pikuri**: `Mcp::Registry` (pure config) + `Mcp::Servers` (runtime — spawns servers, holds
  clients, registers `at_exit`) + per-client `Mcp::ClientWrapper` (restart-on-stdio-death retry) +
  `Mcp::Synthesizer` (LLM-driven summarization of MCP tool surfaces whose `instructions` /
  `serverInfo.title` are unhelpful) + `Mcp::Verifier` (pre-flight injection check: mechanical
  Unicode pre-pass plus LLM inspection for instruction-override, exfiltration, tool-chain hijacking,
  authority-impersonation) + `Mcp::Cache` (on-disk, keyed on the full server surface so any upstream
  change invalidates). Two transports — stdio (the carve-out from the `Subprocess.spawn` chokepoint)
  and HTTP. MCP tools bypass `Pikuri::Tool` and are synthesized as raw `RubyLLM::Tool` subclasses
  with a provenance prefix; the LLM connects on demand via the auto-registered `mcp_connect` tool.
- **opencode ships MCP support**; pikuri's `Mcp::Servers` is informed by its shape but uses the
  `mcp` Ruby gem for the transport layer. **[src]**
- **grok-build loads MCP servers from config, gated by folder trust**, plus the `search_tool` /
  `use_tool` deferred-loading pair (`R_available_tools`) — a BM25 index over the tool catalog
  instead of every schema in the window. **[src]**
- **grok-build truncates descriptions to 2 KB and fingerprints a server's surface** as
  `(tool_count, description_hash, names_hash)` to detect when it changed. **[src]**
- **grok-build has no pre-flight injection scan**; the trust gate is the analogous control, firing
  earlier (before the server is spawned) but coarser (whole workspace, not per-server). **[src]**
- **ruby_llm, langchainrb and pi core have no MCP.** **[src]**

**Takeaway.** Skills and MCP are extension surfaces pikuri added deliberately — Skills for "give the
agent static text knowledge that loads on demand", MCP for "expose third-party tool servers the user
already runs". Both auto-wire when their registry or catalog is non-empty, and `EMPTY` singletons
keep the no-feature path zero-config. `Mcp::Verifier` is the novel-to-pikuri piece: pre-flight
injection scanning of a server's surface before any tool is exposed, with `InjectionDetected`
aborting startup for that server.

## R_memory — The two cross-conversation memory implementations, and their opposite substrates

- **Only two projects in the field ship cross-conversation memory**, and they picked opposite
  substrates. **[src]**
- **pikuri** (`pikuri-memory`): durable memory backed by mem0, run as a self-managed sidecar, with a
  `recall` tool plus per-turn prefetch and capture.
- **grok-build uses Markdown files plus a local SQLite index** — `~/.grok/memory/MEMORY.md` global,
  `<project-slug>-<hash8>/MEMORY.md` per workspace (keyed on the `origin` remote in `org/repo` form
  when there is one, so clones and worktrees of a repo share memory), plus per-session logs. **[src]**
- **Search is FTS5 keyword by default, with `vec0` vector search layered on when an embedding model
  is configured**, behind two tools, `memory_search` and `memory_get`. Experimental, off by
  default. **[src]**
- **Automatic per-session saves are metadata only and use no LLM call** — message counts, up to five
  substantive prompt topics, a timestamp. **[src]**
- **Richer capture is an explicit `/flush`, and a `/remember` write shows the user a review panel**,
  with an optional rewritten version, before anything is written. **[src]**
- **grok-build searches memory once, on the first turn**, and upserts the block into the leading
  system prompt, never re-scoring it because that would bust the KV-cache prefix
  (`R_synthetic_user_turns`). **[src]**

**Takeaway.** The substrate difference matters more than the feature difference: grok-build's memory
is greppable Markdown a human can edit and own; pikuri's is a service. Given pikuri's privacy-first
positioning and its read-it-in-an-evening ceiling, Markdown-plus-SQLite is arguably the more
pikuri-shaped answer than the one pikuri shipped — and the fallback ladder (FTS5 always, vectors
only if an embedder is configured) is exactly the degradation story `pikuri-vectordb` has to tell
anyway. Worth revisiting; not worth churning a shipped gem over. `pikuri-rag` shipped the FTS5 half
for the *corpus* side, though as a peer rather than a ladder — both legs always run and are fused by
reciprocal rank, because it was built for retrieval quality rather than for degrading gracefully
without an embedder. The ladder shape is still unbuilt here and would be cheap: the decorator
already holds a working keyword index that answers with no model at all.

Two mechanisms are cheap and orthogonal to the substrate: the **no-LLM-call automatic save**
(metadata summaries cost nothing and still make a session findable later) and the
**confirm-before-write review panel**, which is the `Confirmer` seam applied to memory writes — a
place pikuri's memory capture currently writes unattended.

A third difference is in *when* recall is delivered, and it is not cosmetic. Pikuri prefetches per
turn, which is the better product — recall tracks what the conversation is currently about — but it
forecloses the system-prompt home: a re-scored block written into the prefix every turn would
invalidate the cache every turn. Per-turn recall and prefix-resident recall are mutually exclusive,
and pikuri chose the one that has to ride an injected message.
