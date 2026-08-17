# COMPARISON.md

A side-by-side look at how six OSS agent-or-agent-adjacent projects solve
the same problems pikuri solves, and a ranked list of ideas worth porting.
*Pikuri-as-shipped state* — the pikuri rows describe the codebase as it is
post-MCP/skills/coding-tools migration; ruby_llm itself is now infrastructure
under us, not a peer to compare against.

## Projects in this comparison

| Project | Language | Scope | Loop size | Key abstraction |
| --- | --- | --- | --- | --- |
| **pikuri** (this repo) | Ruby on top of ruby_llm | small general-purpose CLI agent + in-repo coding agent + MCP-enabled assistant | listeners + controls on top of `RubyLLM::Chat#complete` (~885 lines of `Agent`) | `Tool` factory (synthetic `RubyLLM::Tool` subclass) + `Tool::Parameters` strict validator + sealed `Agent::Event` value hierarchy |
| **ruby_llm** ([crmne/ruby_llm](https://github.com/crmne/ruby_llm)) | Ruby | multi-provider SDK + Rails integration | ~37 lines across `Chat#complete` + `Chat#handle_tool_calls` | `RubyLLM::Tool` subclass + provider adapters |
| **langchainrb** ([patterns-ai-core/langchainrb](https://github.com/patterns-ai-core/langchainrb)) | Ruby | LLM-app framework: RAG/vector search + Assistant + multi-provider | ~421 lines (`assistant.rb`) state machine: `:ready` → `:in_progress` → `:requires_action` → `:completed` | `Langchain::Assistant` + class-level `ToolDefinition` DSL + per-provider `LLM::Adapter` |
| **pi** ([earendil-works/pi](https://github.com/earendil-works/pi)) | TypeScript | extensible coding-agent harness | ~700 lines (`agent-loop.ts`) | Typebox-typed tools + extensions/skills |
| **opencode** ([sst/opencode](https://github.com/sst/opencode)) | TypeScript | full terminal coding agent (Claude-Code-shaped) | effect-based, split across `processor.ts`/`session.ts` | Effect services + `.txt` prompt files |
| **grok-build** ([xai-org/grok-build](https://github.com/xai-org/grok-build)) | Rust | shipped commercial coding agent: TUI + headless + ACP-embedded | actor-per-session (`SessionActor`) over a tool registry, with a `GoalTracker` state machine driving multi-turn autonomy above it | a `ToolKind`-keyed **registry of interchangeable tool implementations** (its own, plus in-tree ports of codex's and opencode's) selected per session by named toolset preset |

The six are at very different scopes:

- **ruby_llm** is now pikuri's runtime, not a peer. It still appears in the
  comparison because some design choices (tool DSL, message shape, error-
  return convention) live in ruby_llm now and pikuri inherits them.
- **langchainrb** is the closest existing Ruby framework to pikuri's scope
  — same language, same general "assistant + tools" target — but with a
  RAG/vector-search-first orientation, no MCP, no sub-agents, no Skills,
  and a state-machine loop instead of a callback-driven one.
- **pi** is a coding-agent harness: same shape as a Claude-Code-style CLI but
  designed as a thin core with everything (sub-agents, plan mode, MCP, perms)
  pushed to extensions.
- **opencode** is much bigger than pikuri — closer to Claude Code itself. The
  value here is mining ideas, not comparing line counts.
- **grok-build** is the biggest by a wide margin — ~1.6M lines of Rust across
  92 crates, a periodic export of xAI's internal monorepo (`SOURCE_REV`
  records the upstream SHA; external contributions are refused). It is the
  only *shipped commercial product* in the set, so it is the one place to see
  which ideas survived contact with paying users at scale: a permission
  system an order of magnitude more detailed than opencode's, an OS-level
  sandbox applied to the agent's own process, and a tool layer built as an
  A/B harness rather than a fixed set. Ideas only — nothing about its size is
  a target.

Pikuri now spans two distinct application shapes — general-purpose chat
(`bin/pikuri-chat`), in-repo coding (`bin/pikuri-code`), and an
MCP-augmented assistant (`bin/pikuri-assistant`) — all wired on the same
`Agent` + `Tool` core (~9.1k lines of `lib/`). The job is the *extension
surface* on top of ruby_llm: strict validation, the sealed `Event`
hierarchy, listener-based rendering, controls for cancellation/step-
budget/mid-loop injection, sub-agents, skills, MCP, and a fixed
deliberate set of bundled tools.

---

## Agent loop

| | Loop shape | Streaming | Termination | Step budget |
| --- | --- | --- | --- | --- |
| pikuri | three callbacks (`after_message`, `before_tool_call`, `after_tool_result`) wired on a `RubyLLM::Chat`; controls (`StepLimit`, `Cancellable`, `Interloper`) poked at well-defined boundaries; `run_loop` is `chat.ask(message)` (`pikuri-core/lib/pikuri/agent.rb`) | opt-in via `Agent.new(streaming: true)` — per-chunk `Event::{Thinking,Assistant}Delta`; propagates to sub-agents + synthesizer | inherits ruby_llm's: no tool calls (or `Tool::Halt`); also `StepLimit::Exceeded` → `Synthesizer.run` rescue, or `Cancellable::Cancelled` re-raise | yes (`Control::StepLimit`, with step-exhaustion rescue via `Synthesizer`) |
| ruby_llm | recursive: `Chat#complete` calls itself after running tool calls (`lib/ruby_llm/chat.rb:156–293`) | yes, optional via block | LLM returns no tool calls, OR `Tool::Halt` short-circuits | no — bounded only by `Halt` |
| langchainrb | state machine over `messages.last.standard_role`: `process_latest_message` dispatches `:system / :llm / :user / :tool` to handlers; on tool-call response sets `:requires_action`; `execute_tools` sets `:in_progress`; loops until terminal state | per-LLM block at `Assistant.new(...) { \|chunk\| ... }`; provider-dependent | LLM returns no tool calls → `:completed`; or `auto_tool_execution: false` returns at `:requires_action` so host can inspect | no |
| pi | nested loops: outer for follow-up queue, inner for steering+tools (`packages/agent/src/agent-loop.ts:155–269`) | yes — `EventStream<AgentEvent>` | `shouldStopAfterTurn()` hook, `stopReason`, abort | implicit via context-window compaction |
| opencode | one-shot processor returning `"compact" \| "stop" \| "continue"` per turn (`src/session/processor.ts:115–425`) | yes — Vercel AI SDK chunk events | model emits no tool calls → `"stop"` | no — context overflow → `"compact"` |
| grok-build | a `SessionActor` per session owning the turn loop, plus an optional **goal state machine** above it (`session/goal_{tracker,classifier,strategist,evaluator,stop_detector}.rs`) that re-prompts the agent across turns until a goal's gaps close | yes — ACP `SessionUpdate` notifications, same stream for TUI / headless / editor | model emits no tool calls; goal mode adds `GoalStopDetector` + a stall trip (two identical "gap fingerprints" in a row → auto-pause) | goal-mode run cap (with a one-off `+3` bonus when the strategist restructures); context pressure handled by auto-compaction at 85% of the window, not by a step budget |

**Takeaway.** Pikuri's loop is now the thinnest of the six with real
extension wiring: ruby_llm owns iteration, and pikuri's `Agent` is a
wiring file — three callbacks, three controls, one sealed `Event`
hierarchy, plus a step-exhaustion rescue (`Synthesizer.run`) and a
cancellation re-raise path. Streaming is opt-in (`streaming: true`)
and propagates to sub-agents and the synthesizer consistently. The
langchainrb state-machine approach is the obvious Ruby alternative
shape but pays for orthogonal "host decides when to run tools" cases
pikuri doesn't need.

The contrast worth recording is grok-build's **goal mode**, which is the
only thing in the set that answers "the agent stopped but isn't done"
with machinery rather than a message. Where pikuri's `StepLimit` is a
*budget* (run out → raise, or synthesize a final answer) and opencode's
overflow is a *compaction*, grok-build's `GoalTracker` is a *supervisor*:
a classifier scores the remaining gaps after each attempt, a strategist
restructures the plan when progress stalls, and a stop detector decides
the goal is met. Its interesting property is the failure mode it designs
for — a stall is detected by *fingerprinting the flagged gaps* and
tripping when two consecutive attempts produce an identical fingerprint,
i.e. the model is looping rather than converging. That's a real answer
to a question pikuri currently answers with "the human is watching."
Out of scope for pikuri as shipped, but the stall fingerprint is the
cheap half and would transfer to `StepLimit` on its own.

---

## Provider / transport abstraction

- **pikuri**: delegates to ruby_llm. `bin/pikuri-chat`/`pikuri-code`/
  `pikuri-assistant` configure the OpenAI provider for the local
  llama.cpp server (`openai_api_base` + `assume_model_exists: true`);
  switching to Anthropic / Gemini / Bedrock / Ollama / etc. is a
  one-block edit in `RubyLLM.configure` — no pikuri-side code change.
  `Agent::ContextWindowDetector` resolves the model's context-window
  cap at construction time from override → ruby_llm registry →
  llama.cpp `/props` probe, so listeners (`TokenLog`) can render
  `ctx=<used>/<cap>` against the right ceiling.
- **ruby_llm**: provider-per-class (`lib/ruby_llm/providers/{openai,anthropic,gemini,bedrock,ollama,...}/`).
  Tool schema stays canonical; per-provider adapters wrap it.
- **langchainrb**: own multi-provider layer (`lib/langchain/llm/{openai,
  anthropic,google_gemini,aws_bedrock,ollama,cohere,mistralai,...}.rb`),
  unified by `LLM::Base` + `LLM::Adapter` for Assistant integration. Each
  provider supplies its own message class
  (`Assistant::Messages::{OpenaiMessage,AnthropicMessage,...}`) and
  schema converter (`to_openai_format` / `to_anthropic_format` /
  `to_google_gemini_format`). Vision (image_url) is first-class on the
  message type.
- **pi**: own multi-provider layer in `@earendil-works/pi-ai` covering OpenAI,
  Anthropic, Google, Bedrock, etc.
- **opencode**: built on Vercel AI SDK. Adding a provider is one entry in
  `BUNDLED_PROVIDERS` (`src/provider/provider.ts:93–118`).
- **grok-build**: first-party by construction — the transport talks to xAI's
  own backend, with OAuth-in-browser on first launch and custom-model config
  as the escape hatch (its user guide's custom-models page). The abstraction
  it *does* invest in is the opposite direction: **ACP** (Agent Client
  Protocol) as the outward interface, so the same runtime serves the TUI, a
  headless `-p` invocation, `grok agent stdio`, and an editor plugin over one
  session/notification protocol.

**Takeaway.** Pikuri inherits ruby_llm's "canonical schema + thin
per-provider adapter" shape — chosen over opencode's SDK-of-SDKs and
langchainrb's everything-in-house approach because we already wrote
tools against the OpenAI tool-call shape and ruby_llm preserves that
as the canonical form. The bundled `bin/pikuri-*` scripts are hard-
coded for the local llama.cpp setup; multi-provider wiring would be a
small `bin/`-level change rather than a library-level rewrite.

---

## Tool abstraction

| | Definition style | Schema | Validation strictness |
| --- | --- | --- | --- |
| pikuri | `Tool.new(...)` factory returns a synthetic `RubyLLM::Tool` subclass; `Tool::Parameters` builder lives on top of ruby_llm's tool layer | fluent `Tool::Parameters` builder → JSON Schema, fed to ruby_llm's `params(hash)` | strict: unknown keys rejected with DidYouMean, type coercion, all errors collected. The keyrest signature on `execute(**args)` makes ruby_llm's keyword-presence checker no-op so pikuri's validator runs first |
| ruby_llm | subclass `RubyLLM::Tool`, class-level DSL | three options: `params { ... }` block, `param :name` declarative, OR auto-inferred from `execute` keyword args | strict but **no DidYouMean** |
| langchainrb | class `extend Langchain::ToolDefinition`; `define_function :method_name, description: do property :foo, type:, required:; end`; tool can expose multiple functions, each becomes a separate tool entry named `<class>__<method>` | DSL → JSON Schema with per-provider exporters; supports `object`/`array`/`enum` recursively | required-key checked by JSON Schema export only — no DidYouMean, no coercion |
| pi | `AgentTool<TParameters>` interface, factory functions | Typebox `Type.Object()` (compile-time + runtime) | Typebox-strict; optional `prepareArguments()` shim for LLM quirks |
| opencode | Effect Schema decoders (Zod-shaped) + `.txt` description files | Effect `Schema.decodeUnknownEffect()` | strict; failure produces "rewrite the input so it satisfies..." message |
| grok-build | `impl Tool` (typed `Args`/`Output`) + an `impl ToolMetadata` declaring `kind` / `namespace` / `description_template` / `requires_expr`; a session then *selects* implementations by name from a global `ToolRegistryBuilder` | derived from the `Args` type via `schemars`, with per-field `#[schemars(description = …)]`; the registry can rename parameters per deployment | serde-strict, with deliberate leniency shims (`deserialize_lenient_i64` accepts `"-3"` for `-3`) — the model's known failure modes are absorbed at the edge rather than bounced back |

**Takeaway.** Pikuri's strict-with-DidYouMean validator is still the single
most load-bearing piece of code distinguishing it from ruby_llm and
langchainrb. Both Ruby alternatives produce thin "missing keyword: x"
messages on bad input; pikuri layers DidYouMean / coercion / all-errors-
collected on top. Langchainrb's one-class-many-functions shape
(`extend ToolDefinition` then multiple `define_function`s) is a different
ergonomic — pikuri's "one constant or instance per tool" is closer to
opencode's pattern. Method-signature introspection (ruby_llm's
auto-infer-from-`execute`) remains an option for trivial tools, but the
explicit `Parameters` builder keeps per-argument descriptions next to
the schema, which is hard to give up entirely.

### grok-build's registry: a tool layer built as an A/B harness

The one structural idea in grok-build with no analogue anywhere else in
this comparison, and the reason its tool crate is ~129k lines: **the same
capability ships several times over, and which implementation the model
sees is a per-session config decision.** `ToolRegistryBuilder::new()`
registers all of them side by side
(`crates/codegen/xai-grok-tools/src/registry/types.rs:674–765`):

- its own `read_file` / `search_replace` / `list_dir` / `grep` / `bash`;
- **in-tree ports of openai/codex's** `apply_patch`, `read_file`,
  `list_dir`, `grep_files` (`implementations/codex/`);
- **in-tree ports of sst/opencode's** `read` / `edit` / `write` / `grep` /
  `glob` / `bash` / `todowrite` / `skill` (`implementations/opencode/`) —
  both ports carry Apache §4(b) change notices in
  `xai-grok-tools/THIRD_PARTY_NOTICES.md`;
- a `GrokBuildConcise` namespace: same behaviour, deliberately shorter
  output and descriptions, for token-tight deployments;
- a `GrokBuildHashline` namespace: a third *addressing scheme* for edits
  (below).

Four mechanisms hold that together, and each is independently interesting:

- **`ToolKind` is the semantic identity, the wire name is not.** `read_file`,
  codex's `read_file` and opencode's `Read` all declare `ToolKind::Read`, so
  presentation (`"Read"`), the read-only classification, permission rules, and
  telemetry are written once against the *kind* and survive swapping the
  implementation. A canonical `_meta` envelope (`x.ai/tool`) stamps every tool
  call with kind + namespace + a **normalized input dict** — `path` / `offset` /
  `limit` / `command` / `pattern` — so a consumer reads one vocabulary no matter
  which toolset produced the call (`tool_taxonomy.rs`, `normalization.rs`).
  Both matches are exhaustive: a new kind or a new input variant must classify
  itself or the crate doesn't compile.
- **Tool descriptions are templates rendered against the live wiring.** They
  interpolate config (`{max_lines_read}`, `max_timeout_ms`), the renamed
  parameter names (`${{ params.read.target_file }}`), and — the good part —
  *sibling tools by kind*, guarded by conditionals:
  `${%- if tools.by_kind.edit %} for use with ${{ tools.by_kind.edit }}${%- endif %}`.
  Every clause that depends on another tool existing disappears when it isn't
  wired.
- **`requires_expr` is a dependency expression over kinds.** `TaskTool`
  declares `And(BackgroundTaskAction, KillTaskAction)` — offer the subagent
  spawner only if the tools for retrieving and killing its results are also
  present. Incoherent toolsets fail validation at finalize instead of
  confusing the model at runtime.
- **Behaviour is versioned per release.** `read_file/versions/legacy_0_4_10.rs`
  keeps the exact historical error string and the "gitignored files are
  readable" policy of v0.4.10, so a model tuned against that surface keeps the
  semantics it was tuned against.

**Takeaway for pikuri.** The A/B-harness framing is a first-party-model
company's problem, not pikuri's — you build it when you're tuning a model
against tool surfaces and need to measure which surface wins. Pikuri
should not grow parallel toolsets. But three of the four mechanisms are
independently cheap and land on real pikuri friction:

- The **templated cross-tool reference** is a direct answer to pikuri's
  "no tool names in a main/binary system prompt" rule (`CLAUDE.md`
  §Conventions). That rule exists because a name in a prompt drifts
  against the wiring; grok-build removes the drift instead of the name,
  by resolving the reference at render time against the finalized
  toolset. Pikuri's rule stays correct as written, but the *reason* for
  it is now known to be fixable.
- **`requires_expr`** is the missing guard on pikuri's `Persona#tool_names`
  and on each `bin/pikuri-*` wiring — nothing today catches a persona
  that lists a tool whose companion isn't in scope.
- **`ToolKind` as identity** is what pikuri would need the day two tools
  serve one purpose (it already nearly happens: `web_scrape` vs `fetch`,
  `glob` vs `file_list`). Not needed yet.

MCP tools are the documented exception to pikuri's strict-validation
contract — they're synthesised as raw `RubyLLM::Tool` subclasses inside
`Mcp::Servers` from each server's `input_schema`, fed in via
`Agent::ExtensionContext#add_raw_tool`. The strict-validation guarantee covers
native tools only; MCP-side validation catches bad input on the server
end. See `pikuri-mcp/lib/pikuri/mcp/servers.rb` for the rationale.

---

## Available tools

| | calc | shell/bash | read | write | edit | grep | glob | search | scrape/fetch | sub-agent | skill | mcp | todo/plan | LSP | vector/RAG |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pikuri | ✅ | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ glob + file_list | ✅ web_search | ✅ web_scrape + fetch | ✅ | ✅ Agent Skills standard | ✅ stdio + HTTP | — | — | — |
| ruby_llm | — (SDK only — no bundled tools) | | | | | | | | | | | | | | |
| langchainrb | ✅ | — | ✅ file_system | ✅ file_system | — | — | — | ✅ google_search / tavily | — | — | — | — | — | — | ✅ vectorsearch (Chroma, Pinecone, Pgvector, Weaviate, Qdrant, Milvus, Elasticsearch, Hnswlib) + DB, NewsRetriever, Weather, Wikipedia, RubyCodeInterpreter |
| pi | — | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ find | — | — | — (extension) | ✅ via extensions | — | — (extension) | — | — |
| opencode | — | ✅ shell | ✅ read | ✅ write | ✅ edit + patch | ✅ grep | ✅ glob | ✅ search (Exa) | ✅ fetch | ✅ task | ✅ | — | ✅ todo + plan | ✅ | — |
| grok-build | — | ✅ bash | ✅ read_file | ✅ write | ✅ search_replace + apply_patch + hashline_edit | ✅ grep | ✅ list_dir + glob | ✅ web_search | ✅ web_fetch | ✅ task | ✅ skill | ✅ (+ `search_tool`/`use_tool` deferred loading) | ✅ todo_write + enter/exit_plan_mode + update_goal + workflow | ✅ lsp | ✅ memory_search / memory_get (SQLite FTS5 + optional vec0) |

ruby_llm ships **no tools at all** — it's an SDK; the developer subclasses
`RubyLLM::Tool` and wires their own. langchainrb's "tools" are a different
shape — most are *capability wrappers* (Wikipedia, Weather, NewsRetriever,
SQL Database, Vectorsearch) rather than the file/shell building blocks
pikuri ships. pi ships only file/shell ops; web search, sub-agents, etc.
are pushed to extensions. opencode is the most batteries-included on the
coding-agent axis — except against grok-build, which ships everything
opencode does plus five categories nobody else has: **scheduling**
(`scheduler_create` / `_delete` / `_list` — cron-style recurring agent
runs), **monitoring** (`monitor` — watch a condition and re-enter),
**media generation** (`image_gen`, `image_edit`, `image_to_video`,
`reference_to_video`), **direct user interrogation**
(`ask_user_question` — the agent pauses and asks a multiple-choice
question), and **goal tracking** (`update_goal`, `workflow`). The
grok-build row is also the widest column set of any project here because
its tool *count* is a per-session config value, not a fixed number: the
matrix shows the union across its named toolset presets (`grok-build`,
`grok-build-concise`, `grok-build-plan`, `codex`, `explore`, `plan`,
`grok-computer`).

The `search_tool` / `use_tool` pair deserves its own note: rather than
putting every MCP tool's schema in the context window, grok-build indexes
them and exposes **BM25 keyword search over the tool catalog** plus a
single meta-dispatch tool that calls a discovered tool by qualified name.
That is the same problem pikuri's `mcp_connect` solves (don't pay for MCP
schemas you aren't using) with a different lever — search-then-call
rather than connect-then-register — and it degrades better when one
server exposes a hundred tools. `use_tool` even carries a corrective for
the predictable failure: hand it a *native* tool name and it answers
"call it directly" instead of the generic not-an-MCP-tool error.

The pikuri row reflects the union of three bundled binaries:
`bin/pikuri-chat` wires calc + web_search + web_scrape + fetch +
sub_agent; `bin/pikuri-code` wires the file/shell stack (read, write,
edit, grep, glob, bash) plus the same web/calc/sub_agent set as
auxiliaries; `bin/pikuri-assistant` adds the MCP connector on top of
the chat tool set. Three binaries on a shared `Agent` + `Tool` core.

**Takeaway.** Pikuri now covers the *general-purpose*, *coding-agent*,
and *MCP-augmented assistant* tool surfaces from one codebase, with
Skills bridging static text knowledge between them. The remaining gaps
versus opencode are todo/plan tools and LSP — both deliberately
deferred (see `ideas/coding-agent.md`). The gap versus
langchainrb is vector search / RAG — out of scope by design; pikuri is
an agent, not a RAG framework.

### Edit addressing: grok-build ships all three arms, and measures them

Pikuri has settled how an `edit` call *names* the place it edits — a
unique string, with `occurrence: N` to escape the uniqueness tax, and no
batch or patch sibling (`DECISIONS.md` `D-single-hunk-edit`). The
candidate answers are usually framed as two: match a unique string
(Claude Code, opencode, pikuri) or ship a patch format with line context
(codex's `apply_patch`). grok-build ships **both, plus a third**, and
built a benchmark harness to choose between them.

The third is `GrokBuildHashline`. `hashline_read` returns every line as
`LINE:HASH[:HASH]→CONTENT`, where the hash is a whitespace-normalized
fingerprint of the line and (depending on scheme) its surrounding
context. `hashline_edit` then takes *those anchors* as its addresses:

```
"replace"      — { "op": "replace", "anchor": "22:abc:rst", "content": "    let x = 42;" }
                 ranges via "end_anchor" (inclusive); "content": "" deletes
"insert_after" — { "op": "insert_after", "anchor": "22:abc:rst", "content": "…" }
                 "0:" for beginning-of-file, "EOF" for end
"write"        — whole-file replacement, no anchor
```

Three properties fall out that neither of the usual two arms has:

- **Verification is intrinsic, not a side effect of uniqueness.** The
  anchor *is* a content fingerprint, so a stale anchor fails loudly
  rather than editing the wrong copy. Pikuri's string-uniqueness rule
  buys the same safety by refusing ambiguous matches — which is exactly
  the tax `occurrence: N` was added to escape. Anchors get the safety
  without the tax, because two identical lines have identical local
  hashes but different line numbers.
- **A failed edit returns fresh anchors, and the description tells the
  model to retry immediately rather than re-read.** That closes the
  read→edit→stale→re-read→edit loop that costs pikuri a full file read
  on every miss.
- **Batches are validated against the pre-edit snapshot and applied
  atomically bottom-up** — one bad anchor rejects the whole batch, and
  overlapping ranges are refused. Pikuri ships no batch tool
  (`D-single-hunk-edit`), and the sweep behind that decision is worth
  restating here: grok-build maintains *four* interchangeable
  `ToolKind::Edit` implementations and benchmarks them, and batching is
  not among the four. Where a batch does appear it is as a *property of
  the anchor scheme* — atomic-or-nothing against a pre-edit snapshot —
  not as a second tool.

The cost is real and worth naming: anchors are only valid for the file
state at read time, the read output carries ~10 extra characters per
line, and the model must never invent an anchor (the description says so
twice). grok-build hedges it by keeping the anchor scheme *pluggable* —
`scheme.rs` defines three candidates (content-only, chunk-fingerprint,
checkpoint-chain) trading freshness detection against anchor churn — and
shipping `benchmark.rs` to measure read-amplification and validation
cost across them. That the scheme is still a parameter, in a shipped
product, is itself the finding: nobody knows which addressing scheme is
best, and the team that could measure it hasn't closed the question
either.

The cost that would decide it *against* pikuri, though, is one grok-build
doesn't have to care about: **an anchor validates by fingerprint, not by
equality.** `util/hash.rs` encodes an FNV-1a 32-bit hash as three
lowercase letters — 26³ = 17,576 buckets — and validation recomputes that
3-letter code for the line at the given index and compares. A collision
means a stale anchor *validates*, and the edit lands on changed content
silently. The probability per validation is small and it is not zero,
where a byte-exact `old_string` cannot false-positive at all. So the
scheme buys freedom from the uniqueness tax by opening a silent
wrong-edit window — a straight trade of pikuri's "predictability beats
fuzz" posture (see {Pikuri::Workspace::Edit}), not a free improvement.
Adopting it would be a reversal to argue for on its own merits, not a
drop-in. Widening the hash narrows the window without closing it, and
spends the payload win that motivated the scheme.

Two smaller edit-path details, both cheap — and instructive in opposite
directions: one transfers only after being inverted, the other doesn't
transfer at all.

- **Sparse line-number anchors.** grok-build's default `read_file`
  prints the `LINE→` prefix only on the first line and every tenth line
  after ("count from the nearest anchor"), rather than on every line.
  Same addressability, a fraction of the tokens — but *not* a free win
  here, and pikuri already declined it: {Pikuri::Workspace::Read} picks
  `cat -n` for **training-data familiarity** over opencode's cheaper
  `"<n>: "` and pi's numberless output, and an outside-model review
  (Grok 4.6, August 2026) confirmed the numbering and the
  read-a-larger-window nudge as a pair, with "don't trade either back
  for tokens." Grok's own product does the opposite of what Grok
  advised pikuri, and the reason is the test to apply to every borrow
  in this section: **a first-party model vendor can tune the model to
  its format; a harness has to meet the model where it already is.**
  grok-build can teach its model any encoding; pikuri targets small
  local models it will never train, so familiarity is a feature it is
  buying, not a cost it failed to notice. (See
  `ideas/grok-build-cheap-borrows.md`.)
- **Unicode confusable repair** (`util/unicode_confusables.rs`). Smart
  quotes, em-dashes, ellipses and non-breaking spaces pasted in from
  Slack or Google Docs render identically to ASCII in `read`, so the
  model's ASCII `old_string` never matches on `edit`. grok-build keeps a
  deliberately narrow map (only substitutions that are near-always
  accidental — `U+2212 MINUS` and `U+00D7 MULTIPLICATION` are excluded
  as semantically meaningful), normalizes for *comparison only*, and
  keeps a byte-offset remap so the write lands on the original bytes.
  Pikuri's `Edit` has the same failure mode with no mitigation — but the
  half to take is the *diagnosis*, not the repair: `Edit` normalizes
  CRLF across the whole file, so a normalize-edit-writeback would
  rewrite every smart quote in the file behind a "1 occurrence"
  confirmation. Retrying a failed match against a normalized copy and
  naming the offending codepoint costs nothing and keeps the
  byte-for-byte contract (`D-single-hunk-edit`) intact. See
  `ideas/grok-build-cheap-borrows.md`.

---

## Tool description quality

This is the section most worth reading. The LLM only gets to see the
`description` and per-parameter strings; their quality directly affects how
often the model picks the right tool with the right arguments.

### pikuri (verbatim — post-cleanup)

All bundled tools follow a single heredoc shape: one-line summary,
blank line, `Usage:` bullet list. Showing `web_scrape` as the exemplar
— this tool had the biggest jump from the pre-convention state:

```
Scrapes the rendered webpage or text file at the given URL and returns its main content as Markdown.

Usage:
- Use for HTML pages where you want readable content — readability extraction strips nav, sidebars, and boilerplate.
- For raw textual payloads (JSON, CSV, robots.txt, source files), use fetch instead — it returns bytes verbatim, while web_scrape would corrupt them with a Markdown pass.
```

Two cross-cutting decisions fell out of the pass:

- **Universal `Error: ...` recovery lives in the per-binary system
  prompts** (`prompts/pikuri-chat.txt`, `prompts/pikuri-assistant.txt`,
  `prompts/coding-system-prompt.txt`) as one rule, not per-tool. The
  same guidance (use what you have, or tell the user; do not retry the
  same call) covers search rate-limits, scrape 404s, fetch refusals,
  calculator parse errors, MCP exceptions, and tool argument validation
  failures — writing it once avoids per-tool drift.
- **Per-argument constraints stay in the parameter description**, never
  duplicated in the tool description. String parameters use inline
  `e.g. "..."` examples in the ruby_llm pattern; integer parameters
  (`max_results`, `max_chars`) state default and cap as the anchoring
  equivalent.

The convention is documented in `CLAUDE.md` under "Conventions" so new
tools land at the same bar without per-PR re-litigation.

### ruby_llm (from spec fixture — there are no shipped tools)

```ruby
class Weather < RubyLLM::Tool
  description 'Gets current weather for a location'
  param :latitude, desc: 'Latitude (e.g., 52.5200)'
  param :longitude, desc: 'Longitude (e.g., 13.4050)'
end
```

The standout is **example values inside parameter descriptions**
(`'Latitude (e.g., 52.5200)'`). Pikuri now applies this convention
universally — every string parameter carries an inline `e.g. "..."` and
every integer parameter states default + cap.

### langchainrb (verbatim — `Calculator.execute`)

```ruby
define_function :execute, description: "Evaluates a pure math expression" do
  property :input, type: "string", description: "Math expression", required: true
end
```

Per-function description, single-line. No usage bullets, no examples in
parameter descriptions, no failure-mode guidance. The terse style is
fine when the LLM has been trained against named tools (the function
name `langchain_tool_calculator__execute` carries most of the signal),
but loses the chain-with-other-tools framing pikuri and opencode put
front and center.

### pi (verbatim — `read` tool)

```
Read the contents of a file. Supports text files and images (jpg, png,
gif, webp). Images are sent as attachments. For text files, output is
truncated to 10000 lines or 2048KB (whichever is hit first). Use
offset/limit for large files. When you need the full file, continue with
offset until complete.
```

Crisp, behavioural, concrete numbers, clear failure mode.

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

opencode's `edit` description is similar in shape — a one-line summary, then
a `Usage:` bullet list with explicit dos/don'ts ("ALWAYS prefer editing
existing files", "NEVER write new files unless explicitly required",
"This tool will FAIL if `oldString` is found multiple times in the file with
an error...").

### grok-build (verbatim — the `bash` description, unrendered)

Same shape (summary, blank line, `Usage notes:` bullets) — but the string
in the source is a *template*, and what the model sees depends on the
host and the wiring:

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

Five things are conditional here: the host OS, the shell's chaining
operator, whether Unix utilities exist on `PATH`, whether sibling tools
(`kill_task`, `get_task_output`) are wired, and whether the runtime's
system-reminder channel will tell the model when a background task
finishes. Numbers (`max_timeout_ms`, `max_output_bytes`) come from live
config rather than being restated by hand. A render failure degrades by
stripping the markers (`strip_markers_on_render_failure`) rather than
shipping template syntax to the model.

Note also the output-cap bullet: over the cap, grok-build truncates the
*middle* (keeping head and tail) and hands the model a path to the full
log. That is the disk-spillover idea already listed below as
worth-borrowing, plus the detail that the tail is usually the part that
matters — a build's error summary lives at the end, so head-only
truncation throws away the answer.

**Takeaway.** opencode's pattern — _summary, then bullet list of usage
constraints_ — is the gold standard, and pikuri now applies it uniformly
across all bundled tools. The one place pikuri diverges: opencode bakes
failure-mode hints inline ("If the path does not exist, an error is
returned"), pikuri factors them into a single universal rule in each
binary's system prompt. Cheaper to maintain, loses some tool-specific
specificity. Langchainrb's terse style is the floor; ruby_llm's
`e.g.`-in-parameters is a free uplift pikuri now applies universally.

grok-build is the ceiling, and it shows what pikuri's own convention is
buying and paying for. Pikuri factors universal recovery guidance into
the system prompt to avoid per-tool drift; grok-build keeps everything
in the tool and prevents drift by making the description *derive* from
the wiring and config it describes. Pikuri's version is cheaper and fits
a codebase meant to be read in an evening; grok-build's is the only one
of the two that cannot go stale. The concrete, portable lesson is
narrower than the machinery: **a number that appears in a description
should be interpolated from the constant that enforces it, not typed
twice.** Pikuri already does this where the cap is a constant
(`Read`'s `MAX_BYTES_LABEL` / `MAX_IMAGE_BYTES_LABEL`) and doesn't where
it isn't (`web_search`'s "Defaults to 10; most providers cap this at 20"
is typed next to a hard-coded `max_results: 10`). Closing that gap is
the whole portable half of grok-build's template machinery.

---

## Conversation / message types and event streams

| | Message store | Event stream | Streaming deltas | Token bookkeeping |
| --- | --- | --- | --- | --- |
| pikuri | inherits ruby_llm's `Chat#messages` | sealed `Agent::Event` hierarchy: `UserTurn(mid_loop)`, `Thinking`, `Assistant`, `ThinkingDelta`, `AssistantDelta`, `ToolCall`, `ToolResult`, `Tokens`, `ContextCap`, `FallbackNotice`, `Cancelled` — all flow through one `Listener::Base#on_event` entry point | opt-in via `Agent.new(streaming: true)`; per-chunk `*Delta` events alongside message-level bookends | `Tokens` event carries `input`/`output`/`cached`/`cache_creation`/`thinking`/`model_id`; `Listener::TokenLog` tracks running context-window size; `Event::ContextCap` carries the detected cap from `ContextWindowDetector` |
| ruby_llm | plain Array of `Message` objects (no log wrapper) | three registered callbacks (`after_message`, `before_tool_call`, `after_tool_result`); pikuri-style structured events not exposed | yes, optional via block | per-message `tokens` field on `Message`; no running aggregate |
| langchainrb | `messages` (Array of provider-specific `Messages::*Message`); `add_message_callback` proc fires on every append | none beyond the two callbacks (`add_message_callback`, `tool_execution_callback`) | per-LLM block at `Assistant.new(...) { ... }` | running totals on `Assistant`: `total_prompt_tokens` / `total_completion_tokens` / `total_tokens` |
| pi | TypeScript discriminated union; custom message types extensible via declaration merging | `EventStream<AgentEvent>` | yes | per-event |
| opencode | `MessageV2` with `ErrorPart` / `ToolPart` / `TextPart` etc.; parts are typed and persisted in SQLite per session | Vercel AI SDK chunks; bus emits typed events for permission flows | yes | per-message |
| grok-build | per-session actor + SQLite journal (`xai-sqlite-journal`); sessions are listable, resumable, forkable, and searchable (`session_search`) | **ACP `SessionUpdate` notifications** — one protocol serving TUI, headless, and editor clients alike; tool calls carry the canonical `x.ai/tool` `_meta` envelope | yes | `xai-token-estimation` + auto-compaction at 85% of the window, with an optional speculative two-pass compaction that summarizes the history prefix in the background *before* the threshold is hit |

**Takeaway.** Pikuri now has the richest structured-event surface among
Ruby implementations: a sealed `Data.define` value hierarchy covering
turns, thinking, assistant text, both streaming-delta modes, tool calls,
tool results, token usage, context-window cap, fallback notices, and
cancellation — all flowing through one `on_event` entry point that
listeners override. Langchainrb's two-callback model
(`add_message_callback` + `tool_execution_callback`) is the same
*architectural shape* pikuri started with, but the sealed event
hierarchy is the upgrade pi/opencode have and Ruby otherwise lacks.

The one capability every project here has and pikuri doesn't is
**context compaction**. grok-build's is the most developed: auto-compact
at 85% of the window, a configurable summarizer model, a wall-clock
budget per compaction (a generation that overruns is cut and retried —
the backstop token limits miss when reasoning runs away), an optional
memory-flush turn that writes durable notes *before* the history is
discarded, and a two-pass mode that speculatively summarizes the prefix
in the background so the compaction itself is cheap. Pikuri's answer
today is `exit 1` in a `bin/` script (`ideas/context-overflow-behavior.md`),
which is a demo shortcut and not a library position; the memory-flush
ordering is the piece worth remembering when that changes, because
pikuri-memory's capture step has exactly the same before-or-after
question.

A second grok-build channel pikuri has no equivalent for:
**system reminders** — `<system-reminder>` blocks appended to *tool
output* on the way back to the model, either by the tool itself (an empty
file read) or by cross-cutting reminders registered on the registry
(fresh LSP diagnostics, newly discovered skills, a completed background
task, a nudge to use `todo_write` after N turns without one). It is a
control channel that costs nothing when quiet, and it lets the harness
tell the model something without a user turn or a system-prompt rewrite.
Pikuri's nearest thing is `Control::Interloper`'s `:system` kind, which
is host-driven and lands as a message rather than riding an observation.

The four bundled listeners (`Terminal`, `InMemoryEventList`, `TokenLog`,
`RateLimited`) demonstrate the surface: TUI rendering, test capture,
running token accounting, and pacing for shared cloud quotas. None are
"the" listener — they're examples of the shape new sinks (a web UI,
a JSON log) would take.

---

## Error handling

| | Tool argv malformed | Tool execute failure (recoverable) | Tool execute failure (bug) |
| --- | --- | --- | --- |
| pikuri | `"Error: <msg>"` string fed back to model (with full schema reprinted by `Tool::Parameters`) — pikuri's validator runs *before* ruby_llm's would | `"Error: <msg>"` string by tool convention; ruby_llm passes it through verbatim to the next observation | raises through ruby_llm; kills the loop |
| ruby_llm | `{ error: "..." }` hash sent to model | tool returns whatever; exceptions **bubble up** to host (not caught) | bubbles up to host |
| langchainrb | tools are expected to handle and return `tool_response(content: "...")` — failures surface as observation text; required-key validation happens at JSON Schema export, not at run time | tool returns whatever; `execute_tools` catches any exception, logs it, and transitions to `:failed` state — loop ends, host inspects | same as recoverable — caught at the `execute_tools` boundary |
| pi | caught and wrapped as `ToolResultMessage` with `isError: true` | caught and wrapped as text `"Error: <msg>"` | caught and wrapped (same path) |
| opencode | tool catches Effect Schema decode failure and returns "rewrite the input..." text | text observation | caught and converted to `MessageV2.ErrorPart`; loop continues |
| grok-build | typed `ToolError` returned to the model; several classes of malformed argv are *absorbed* rather than rejected (a stringified integer, a JSON-encoded array where an array was expected), and a wrong-namespace call gets a corrective ("call it directly") instead of a generic error | typed `ToolError` observation, with `<system-reminder>` hints appended; `xai-circuit-breaker` guards repeatedly-failing external legs | `anyhow` up through the actor; the session survives and reports |

Pikuri's split — _recoverable failures become observations, bugs raise_ — is
explicit and documented in `pikuri-core/lib/pikuri/tool.rb`. ruby_llm shares the
philosophy; pikuri's String convention is what flows through to the model
(ruby_llm's `Chat#handle_tool_calls` calls `.to_s` on whatever the tool
returns and writes it as the tool message's content). Langchainrb is closer
to pi/opencode: trap everything at the `execute_tools` boundary, transition
to `:failed`, surface to the host. The trade-off is well-documented in
pikuri's CLAUDE.md (`Errors are loud`) — bugs should be loud during
development; the carve-out for loop-secondary best-effort paths (e.g.
the context-window probe hitting a wedged server) keeps the agent alive
when the failure is cosmetic.

**Takeaway.** Pikuri's choice survives unchanged. The opencode/pi/langchainrb
"trap-everything" posture is what you want when the agent is long-running
and unattended; the "raise on bugs" posture is what you want during
development. Pikuri's choice is the latter — fine for its scope.

grok-build adds a third axis pikuri's split doesn't cover: *when the
model's input is wrong in a way you can confidently fix, fix it.* Its
readers accept `"-3"` where `-3` was declared, its edit tool accepts a
JSON-encoded string where an array was declared, and `use_tool` answers
a native tool name with "call it directly." Each of those is a round
trip the model doesn't spend. That sits uneasily against pikuri's
strict-validator-with-DidYouMean bet, which spends the round trip
deliberately to teach the schema — and the honest reading is that the
two are optimizing for different things. A first-party model vendor can
fix the model; pikuri can only fix the harness, so the corrective error
message is doing more work here than it does there. Worth noting as a
real fork, not adopting wholesale.

---

## Permission / sandboxing

- **pikuri**: three-seam approach for v1.
  - **`Workspace::Filesystem`** is a single concrete class with
    explicit `project_root:` / `readable:` / `writable:` / `temp:`
    parameters. `project_root` is the writable containment ceiling
    AND the relative-path base AND the chdir target for Bash /
    Grep / Glob — one anchor, no separate cwd (hosts that want the
    agent scoped to a subtree pass that subtree as `project_root`).
    Every coding tool (`Read`/`Write`/`Edit`/`Grep`/`Glob`/`Bash`)
    takes a workspace via constructor and routes paths through
    `#resolve_for_read(path)` / `#resolve_for_write(path)`,
    rejecting `..`-escapes and symlinks that resolve outside any
    declared root. `Filesystem::AllowAll` is the unrestricted
    variant for `--yolo` / in-container use: same accessor surface,
    but `resolve_for_*` accept any path *except* those on a
    hardcoded credential denylist (`~/.ssh`, `~/.aws`, `~/.gnupg`,
    `~/.kube`, `~/.docker`, `~/.netrc`, `/etc/shadow`, …).
  - **`Workspace::Confirmer`** abstract base + `TERMINAL` /
    `AUTO_APPROVE` bundled implementations: `Write`/`Bash` route
    every prompt through `#confirm?(request:)` — a semantic
    question + optional detail, with all presentation (color,
    escaping, the y/n cue) owned by the confirmer — rather than
    touching `$stdin`/`$stdout` — `--yolo` swaps in
    `AUTO_APPROVE`. The seam exists so a future TUI / IDE host
    plugs in by writing a new `Confirmer` subclass, not by
    editing tool internals.
  - **`Code::Bash::Sandbox`** is a third seam, distinct from
    Workspace: Workspace governs what the LLM observes via the
    file tools; Sandbox governs the filesystem view of the bash
    subprocess. `Sandbox::NONE` is the identity wrap (default for
    `Bash.new`, what `--no-sandbox` / `--yolo` swap in);
    `Sandbox::Bubblewrap` composes a `bwrap` argv from
    `workspace.readable` / `writable` plus a curated `/etc`
    baseline (`ETC_BASELINE` — TLS certs, DNS, timezone, hosts)
    and per-toolchain ephemeral overlays for `~/.gradle/caches`,
    `~/.m2/repository`, `~/.cargo/registry`, etc. Overlays are
    *content-only subdirs* (not the toolchain's whole `$HOME`),
    so credentials in `~/.gradle/gradle.properties`,
    `~/.gradle/init.d`, `~/.m2/settings.xml`,
    `~/.cargo/credentials.toml` never appear in the sandbox at
    all; writes vanish at process exit. Threat model: blast-radius
    containment + prevention of cross-project contamination via
    shared toolchain caches — *not* malware-resistance (network
    egress stays open by design so `git pull` / `curl` work; prompt
    injection can still modify project sources). Construction
    refuses if any workspace root contains a container / VM
    control socket (`/var/run/docker.sock`, `containerd.sock`,
    `podman.sock`, `libvirt-sock`, …) — exposing one effectively
    undoes the sandbox via `docker run --privileged -v / /host`.
  Opencode-style glob rules (`allow` / `deny` / `ask`) are
  deferred — see `ideas/coding-agent.md`. The next step
  per that note: ClaudeCode-style agentic review of bash commands
  for auto-approval / -denial of the obviously-safe cases,
  layered *on top of* (not replacing) bubblewrap.
- **`Pikuri::Subprocess.spawn` chokepoint**: every subprocess spawn
  in any pikuri-* `lib/` goes through one entry point that creates
  a new process group per invocation, tracks pgids, and SIGTERMs
  everything tracked via `at_exit` so backgrounded shell children
  can't outlive pikuri. Grep-enforceable:
  `grep -rn 'Process\.spawn\|Open3\|system' pikuri-*/lib/` should
  only hit `pikuri-core/lib/pikuri/subprocess.rb` (one carve-out,
  in `pikuri-mcp/lib/pikuri/mcp/client_wrapper.rb` — the `mcp` gem
  owns its own subprocess lifecycle for stdio MCP entries).
- **ruby_llm**: nothing — out of scope for an SDK.
- **langchainrb**: nothing — `Tool::FileSystem` reads and writes anywhere
  the host process can. `Tool::RubyCodeInterpreter` uses `safe_ruby` (a
  whitelist-based sandbox the README notes is "in need of a better
  solution").
- **pi**: `beforeToolCall` extension hook can `{ block: true, reason: "..." }`.
  No built-in UI prompt. Safety is delegated to the host or to extensions.
- **opencode**: declarative rules, glob-aware (`src/permission/index.ts`):

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

  Three actions: `allow` / `deny` / `ask`. On `ask`, execution is paused via
  a `Deferred`, the bus emits a request, the UI replies "once" / "always" /
  "reject". Denial returns a typed error to the model.
- **grok-build**: the most developed of the six, on both axes at once —
  and the only project here whose OS sandbox covers the *agent's own
  process*, not just its shell subprocess. Detailed below.

**Takeaway.** Pikuri's three-seam approach — `Workspace` locks the
file tools' read/write paths to the discovered project root;
`Confirmer` gates user-state mutations (`Write`, `Bash`);
`Sandbox::Bubblewrap` constrains the bash subprocess's filesystem
view to the same project + a curated runtime baseline + ephemeral
toolchain overlays — is the v1 answer for an interactively
supervised agent. Opencode's three-action glob model is the
obvious next step on the *permission* axis once friction shows up
in practice; the seams are already in place to swap
implementations without touching tool internals. Bubblewrap is
*not* malware-resistant — network egress stays open by design and
in-project mutation is on the table — so adversarial isolation
still needs a container or VM around pikuri, with bubblewrap as
the inner layer. Langchainrb is the cautionary tale here —
`FileSystem.read_file` / `write_to_file` take arbitrary paths
from the LLM with no validation.

### Pikuri vs. Claude Code: structural vs. operational defense

Claude Code isn't in the project table (it's closed-source), but it's
the reference coding agent the others are shaped after, and its security
model is the instructive contrast. Inspect the toolset on its *main*
agent — `Read` / `Write` / `Edit`, `Bash`, `WebFetch` / `WebSearch`,
MCP — and it holds all three legs of the lethal trifecta at once
(private data + untrusted content + egress). It does **not** attempt
pikuri's trifecta-break. That's not an oversight; it's the opposite bet.

- **Pikuri defends structurally.** Remove a leg *per agent*: sub-agent
  capability boundaries (`RESEARCHER` has no `read`, `FILE_MINER` has no
  egress), so the agent that touches untrusted content literally can't
  act on an injection. The defense is a property of the capability
  graph, so it holds even against a fully injected model.
- **Claude Code defends operationally.** Keep all three legs; insert a
  trusted human + an OS sandbox + an injection-hardened model at the
  moment of the dangerous action. Its top three, in order:
  (1) human-in-the-loop permission gating (`allow` / `deny` / `ask`
  rules, permission modes); (2) OS sandbox (`sandbox-exec` / bubblewrap)
  + working-directory confinement + a trust-this-folder gate;
  (3) model-level injection resistance plus platform-side monitoring.

**The asymmetry worth recording.** Claude Code's first two defenses
were never *primarily* injection defenses — the human gate is a
*mistake* control (it catches the hallucinated `rm -rf` whether or not
an attacker is involved); the sandbox is a *code-execution* control
(it bounds blast radius regardless of cause). They blunt injection as a
side effect, so they survive the threat model shifting. Pikuri's
trifecta-break is *specifically* an anti-injection bet — which makes it
the one defense that goes obsolete if a data-vs-instruction separation
("an NX flag for tokens") is ever solved, because the lethal trifecta
is lethal *only* because injection exists: solve injection and the
trifecta stops being a category. The flip side, in pikuri's favor: a
model's own injection resistance (Claude Code's #3) is the one leg that
lives *inside* the component an injection compromises, so it can't be
leaned on alone — and neither project does (pikuri via capability
boundaries, Claude Code via the human + sandbox beneath it).

**Where they converge.** Pikuri can't break the trifecta for its own
coding agent either: `bin/pikuri-code` / `bin/pikuri-assistant` hold
`read` + `bash` + `fetch` on the parent and fall back to system-prompt
nudging plus the `Confirmer` (SECURITY.md "Non-goals", last bullet). So
coding is the harness where pikuri's structural model runs out and the
operational one takes over — exactly Claude Code's territory. And
Claude Code's visible investment in reducing confirmation fatigue
(smarter triage so the human is interrupted less, and better when they
are) is the same conclusion driving pikuri's confirmer-as-last-line-of-defense
framing (book [the security chapter](book/security.md) §"The human gate, and why
fatigue is the enemy"; the not-yet-shipped seam residue in
`ideas/more-confirmers.md`): for an *attended*
coding agent the human gate is the load-bearing control, and its whole
value rides on not inducing fatigue. The shared nuance is deployment
shape — the human gate is worth zero *unattended* (cron / CI / a
`minions` fan-out), where only structural defense or an egress
allowlist survives.

### Prior art deep-dive: PI's two isolation weights, opencode's permission system

The bullets above sketch what PI and opencode *ship*; this is the
deeper survey of *how*, done while scoping pikuri's own security
posture. Findings reinforce pikuri's framing more than they contradict
it.

**Common ground.**
- **Neither has prompt-injection defenses.** No provenance markers on
  tool output, no "treat results as data" language in system prompts,
  no separate channels. Confirms the load-bearing tag — nobody in this
  space has solved it.
- **Both cap tool output** at ~2000 lines / 50KB with overflow
  spilled to a tempfile and the path returned to the LLM. Cheap to add
  to pikuri.
- **Both validate sub-agent privilege separation as the right shape** —
  PI via a `--tools` allowlist on the spawned child
  (`packages/coding-agent/examples/extensions/subagent/index.ts:267`),
  opencode via inherited parent-denies plus per-preset deny baselines
  (`packages/opencode/src/agent/subagent-permissions.ts`,
  `agent/agent.ts:178-220`).

**PI ships nothing security-related in core**, but offers isolation
through two opt-in extensions of very different weights. No
permission system in core (only a 30-line example extension
regex-matching `rm -rf` / `sudo` / `chmod 777`), no workspace
constraint (paths resolve absolutely with `~` expansion, no `..`
rejection — `core/tools/path-utils.ts:54-93`), bash unrestricted, no
MCP, no provider warnings, no Dockerfile. The README's stance is one
line: "Run in a container yourself."

The **lighter isolation extension** is `sandbox`: wraps the `bash`
tool only — **bubblewrap on Linux / `sandbox-exec` on macOS** —
driven by `~/.pi/agent/extensions/sandbox.json`. Default policy:
network *on* with an npm / pypi / github allowlist; deny-read for
`~/.ssh` / `~/.aws` / `~/.gnupg`; deny-write for `.env*` / `*.pem` /
`*.key`. Only `bash` is wrapped — `edit` / `write` / `read` execute
outside the sandbox, so a prompt-injection that prefers `edit` over
`bash sed` walks past it. Sub-agents spawn as separate `pi` child
processes that don't inherit the `-e ./sandbox` flag — no recursion.
(`packages/coding-agent/examples/extensions/sandbox/index.ts`.)

The **heavier isolation story is Gondolin**
(<github.com/earendil-works/gondolin>, separate Apache-2.0 project
from the same org) and the more interesting one as prior art.
**Lightweight Linux micro-VMs** (QEMU by default, experimental
`krun` backend) — explicitly stronger isolation than containers /
namespaces. The PI-side extension *"runs pi tools inside a micro-VM
and mounts your project at `/workspace`"*; the whole toolset runs
inside, not just bash. Three design choices worth recording:

- **Programmable HTTP/TLS egress proxy with allowlists.** Not just
  iptables — a real proxy that inspects what's leaving.
- **JS-configurable VFS mounts.** Host decides what filesystem the
  guest sees.
- **Secret-placeholder pattern.** Guest env vars hold placeholders,
  not real values; the egress proxy substitutes the real secret
  **only on outbound requests to allowlisted hosts**. A
  prompt-injection that does `echo $STRIPE_KEY > attacker.com` fails
  twice: env doesn't contain the real key, and `attacker.com` isn't
  allowlisted. Genuinely novel prior art — Anthropic's MCP / OAuth
  flows don't have an equivalent.

Gondolin is also the substrate for **`pi-chat`** (Discord / Telegram
→ Claude bridge, same org) — one micro-VM per channel for
multi-tenant isolation. Worth noting: pi-chat's docs explicitly say
*"All outbound HTTP/TLS open by default"* — the egress policy is
available but not aggressively configured in that product.

**opencode is the opposite.** A sophisticated three-action
`allow` / `deny` / `ask` permission system keyed on
`(permission-name, glob-pattern)`, last-match-wins, default-`ask`,
persisted to per-project SQLite for `always` approvals
(`packages/opencode/src/permission/evaluate.ts:11`,
`permission/index.ts:140-145`), with a **tree-sitter bash parser**
deriving sticky-approval prefix patterns like `git status *`
(`tool/shell.ts:261-265, 308-333`). But `SECURITY.md` is explicit at
the top: *"OpenCode does not sandbox the agent. The permission system
exists as a UX feature... it is not designed to provide security
isolation."* Workspace is soft — out-of-tree triggers an
`external_directory` prompt, not a denial; no realpath / symlink
resolution (`project/instance-context.ts:18-23`). MCP servers spawn
as raw subprocesses inheriting `process.env`; schemas loaded
eagerly (`mcp/index.ts:412-445, 513-549`). Sub-agent presets
`general` / `explore` / `scout` use `"*": "deny"` with selective
allows; parent denies propagate into the child. Skills load from
arbitrary URLs with no signature / integrity check
(`skill/discovery.ts:54-104`). No egress controls, no provider
warnings.

**Worth borrowing (or considering) for pikuri.**
- **Disk spillover for over-cap output** (both). Per-tool byte caps
  already exist in `Bash` / `Read` / `WebScrape`; the missing piece
  is writing the overflow to a tempfile and returning the path so the
  LLM can `grep` it. (Cross-cutting version tracked in
  `ideas/security-open-questions.md` §"Output-size DoS and cost".)
- **Sub-agent toolset narrowing** — *shipped* via personas; see
  §"Sub-agents" above.
- **opencode's `(permission-name, glob-pattern)` ruleset shape** if
  `Confirmer` ever expands beyond binary approve/deny (C-tier #14 in
  §"Ideas to borrow").
- **PI's credential-dir deny-read defaults** (`~/.ssh`, `~/.aws`,
  `~/.gnupg`) — a `Workspace::Filesystem` default denylist gives some
  real protection even without a sandbox, and it's a one-method
  change. Same for deny-write on `.env*` / `*.pem` / `*.key`.
  (Partially shipped — `Filesystem::AllowAll` already carries a
  credential denylist; see §"Permission / sandboxing" above.)
- **Gondolin's secret-placeholder pattern.** A tool surface where env
  vars are placeholders and real values flow only through a curated
  egress proxy is a structural defense against exfil-via-prompt-
  injection — not "approval prompt the user is no longer reading."
  Heavyweight to implement (needs an HTTP/TLS interceptor); flagged
  as future-thought.
- **opencode's explicit "this is UX, not security" framing** in
  their `SECURITY.md` is the honest baseline pikuri's
  [`SECURITY.md`](SECURITY.md) borrows directly under "Non-goals".

**Mental model worth recording:** PI itself ships no isolation in
core. It offers *two extensions of different weights* — the
bubblewrap `sandbox` (bash-only, lighter) and a Gondolin micro-VM
integration (full Linux VM, full toolset). The user-facing "run pi
in a sandbox" story is real, but user-configured and opt-in, not
default. PI is thus prior art for **"ship the sandbox primitive
separately, let the user opt in at the weight they need"** —
different shape from opencode's explicit "we're not a sandbox, run
it in Docker yourself."

### Prior art deep-dive: grok-build's authorization pipeline and in-process sandbox

grok-build is where the permission axis has clearly been through the
most contact with real users, and it is the strongest prior art in this
document for pikuri's two deferred security threads — glob permission
rules (`ideas/coding-agent.md`) and agentic review of bash commands.

**The authorization pipeline is ordered and documented.** Every tool call
walks five stages: (1) `PreToolUse` hooks, which may deny but whose
*allow* only declines to deny; (2) permission rules from every config
source, merged and evaluated **by severity, not by order or file** —
`deny` > `ask` > `allow`, so a global deny cannot be overridden by a
project allow; (3) remembered per-command grants, scoped to the git
repository root; (4) built-in auto-approvals for read-only tools and a
curated read-only shell-command list; (5) the permission mode's prompt
policy. Six modes span the range from `default` (ask) through
`acceptEdits`, `auto`, `dontAsk` (deny-by-default allowlists for CI) to
`bypassPermissions` (`--yolo`). Rules cover `Bash`, `Read`, `Edit`,
`Grep`, `MCPTool`, `WebFetch`, `WebSearch`, and grok-build reads Claude
Code's `.claude/settings.json` directly — an interoperability move
pikuri already parallels on skills.

**The shell-command analysis is the part worth reading closely.** This is
the concrete content of the "which commands are actually safe to
auto-approve" question pikuri deferred:

- Commands are parsed and **split on `&&`, `||`, `;`, `|`, and newlines**,
  and `deny`/`ask` are checked *per segment*; a command that can't be
  split into simple segments (subshells, `$(…)`, backticks, background
  `&`, control flow) prompts as one unit.
- Segment checks **strip env prefixes** (`RUST_LOG=debug …`) and peel a
  fixed wrapper set (`timeout`, `nice`, `ionice`, `chrt`, `stdbuf`,
  `env`); `sudo`, `xargs`, and `nohup` are deliberately *not* peeled.
  `deny`/`ask` also reach inside inline `bash -c` scripts.
- The read-only allowlist is **word-boundary matched** (`ls` doesn't
  match `lsof`), and its exclusions are the education: `tee` is off the
  list because it writes arbitrary files; `cargo check` is off it because
  it compiles and runs `build.rs`, proc-macros, and any
  `build.rustc-wrapper` from the repo; `rg --pre` is off it because it
  spawns a preprocessor per file; `sort --compress-program=…` likewise.
  Most valuable of all, a *git* command whose local config installs an
  executable hook — `core.fsmonitor`, a `diff.*.command` / `textconv` /
  `external` driver, or an `alias.<safe-subcommand> = !…` — raises a
  prompt floor, because `git log` in a hostile repo is arbitrary code
  execution. That list is a free security review of any future
  auto-approval logic in pikuri.
- A **dangerous-command list** (`rm`, `chmod`, `chown`, `chgrp`,
  `chattr`, `pkill`, `kill`, `killall`, `git push`) never honors a
  remembered *prefix* — only an exact grant for the whole command — and
  when no rememberable grant could stop the prompt recurring, the
  "always allow" row isn't offered at all rather than saving a rule that
  wouldn't work.
- And an honest documented footgun: `allow` rules match the **whole
  command string only**, so `Bash(git *)` auto-approves
  `git status && rm -rf /`. The docs say so in as many words.

**The sandbox inverts pikuri's posture.** `xai-grok-sandbox` applies
**Landlock (Linux) / Seatbelt (macOS)** *once at process startup*, via
the `nono` crate, so it covers the agent's own `tokio::fs` calls as well
as every child. Five profiles — `off` (default), `workspace` (read
everywhere, write CWD + temp + `~/.grok`), `devbox`, `read-only`,
`strict` — with custom profiles in `sandbox.toml`. Network is the mirror
image of pikuri's `FullFsNoNet`: open at the process level (the agent
needs the LLM API) and **blocked per-subprocess via seccomp**, Linux
only, explicitly a no-op on macOS. Two implementation details are worth
recording:

- A custom profile's `deny` list is **kernel-enforced for read *and*
  write/rename**, specifically so the `mv secret x && cat x` bypass is
  closed. On Linux that requires bubblewrap, and if bubblewrap is
  missing or any single deny path can't be bound, grok-build **refuses to
  start** rather than run with denied paths exposed — the same
  fail-closed posture as pikuri's `FullFsNoNet` raising instead of
  degrading.
- Nested user namespaces are disabled inside the bwrap layer so mount
  binds can't be rearranged from within, and the seccomp filter rejects
  `clone`/`clone3` carrying namespace bits — grok-build blocks from
  inside its own sandbox the very primitive pikuri's sandbox is built on.

**Folder trust is the gap it closes that pikuri hasn't.** A cloned
repository can ship `.mcp.json`, a project `.grok/config.toml` carrying
`[permission]` auto-approve rules and `[mcp_servers]` commands, or
`.grok/lsp.json` — all of which the CLI would otherwise honor on
`cd`-and-launch. grok-build's own module comment calls this what it is:
**"a 1-click RCE / policy bypass."** So it resolves a VS-Code-style
trust decision **once per workspace, before any repo-local server is
spawned**, and every loader consults a cheap `project_scope_allowed`
check. Two grants are deliberately provisional and never cached — the
"there were no repo configs" allow (so a config that appears after a
`git pull`, or that the agent itself writes, is re-checked) and the
unrecordable-key case (cwd is `$HOME` or the filesystem root).

**No prompt-injection defense** — same as PI and opencode. Every hit for
"prompt injection" in the tree is the benign sense (injecting text
*into* the prompt). The load-bearing tag in pikuri's SECURITY.md stands:
three of the largest coding agents in the world, including a shipped
commercial one, all decline to claim it. What grok-build does have, and
pikuri independently arrived at, is a *mechanical* Unicode confusable
pre-pass — grok-build's is aimed at edit-matching failures rather than at
hidden instructions, but it is the same instinct as `Mcp::Verifier`'s
confusable check.

**What pikuri should take, and what it shouldn't.** The six-mode
permission system, the persisted grant store, and the managed
`/etc/grok/requirements.toml` admin layer are all enterprise-shaped and
out of scope. Three things are not:

- **The read-only shell-command list, with its exclusions** — the
  `git -c` / `textconv` / `!alias` finding in particular. If pikuri ever
  auto-approves a bash command, this list is the starting point, and
  re-deriving it independently would be negligent.
- **Folder trust.** Pikuri's `Skill::Catalog::Bundled` scans
  `.pikuri/skills`, `.claude/skills` and `.agents/skills` under whatever
  bases the host passes — typically the project root — so a cloned
  repository's skill names and descriptions land in the system prompt
  with no trust decision at all. The `skill` tool already tags a skill
  body `untrusted: :hard`, which is the right classification of the
  *content*; what's missing is a gate on the *source*. `Mcp::Registry`
  is host-supplied today, so skills are the live exposure.
- **Per-segment analysis before any policy decision.** Pikuri's
  `Confirmer` shows the human one command string. Splitting on the shell
  operators and showing the segments — the way grok-build does before
  any rule matches — is a presentation change that costs nothing and
  directly serves the confirmer-fatigue argument in the book's
  [security chapter](book/security.md).

---

## Sub-agents

- **pikuri** (`Pikuri::SubAgent::SubAgentTool < Pikuri::Tool`,
  shipped in the `pikuri-subagents` gem and wired via
  `c.add_extension Pikuri::SubAgent::Extension.new(personas: [...])`
  inside the `Agent.new` block): the LLM-visible `agent` tool
  delegates to a fresh `Agent` by *persona name*. A `Persona` is a
  five-field record (`name`, `description`, `tool_names`,
  `system_prompt`, `max_steps`); spawning runs the persona's
  `system_prompt` verbatim (no inheritance from the parent), with
  the subset of `parent.tools` whose `name` appears in
  `persona.tool_names` (parent tool *instances* are reused so any
  workspace/confirmer wiring travels along), and a fresh
  `StepLimit` at `persona.max_steps`. The parent's `transport`,
  `cancellable`, `context_window_cap`, and `streaming` flag travel
  through unchanged. Listeners propagate via a duck-typed
  `for_sub_agent(id:)` convention — `Terminal` pads with the
  child's id, `TokenLog` tags a fresh per-agent snapshot,
  `RateLimited` splits its bucket. Controls don't use the same
  hook (the propagation policy is inlined in
  `SubAgentTool#execute` — fresh `StepLimit` at the persona's max,
  shared parent `Cancellable` by reference, `nil` `Interloper`).
  Extensions are *not* inherited — if a persona needs MCP or
  skills, the persona ships its own wiring. Recursion is
  structurally impossible: no bundled persona lists `agent` in its
  `tool_names`, so a child has no `agent` tool to call.
- **ruby_llm**: no built-in sub-agent.
- **langchainrb**: no built-in sub-agent. Could be modeled by
  instantiating multiple `Assistant`s but there's no first-class
  delegation / filtered-tool / control-propagation story.
- **pi**: not in core; pushed to extensions.
- **opencode** (`task` tool, `src/tool/task.ts:32–174`):
  - each task creates a **new `Session`** (not just a new chat history) —
    backed by SQLite, so sessions are inspectable and resumable
  - takes an optional `task_id` to resume a prior subagent session
  - permissions are derived from the parent and filtered to what the parent
    is allowed to do
  - tool list can be different (unavailable tools passed as `{name: false}`)
  - return wrapped in `<task_result>...</task_result>` tags
- **grok-build** (`task` tool + a coordinator actor): the most featureful
  of the six. Three built-in types (`general-purpose`, `explore`, `plan`)
  plus user-defined personas; **background by default** (returns a
  subagent id immediately, results retrieved via `get_task_output` /
  `wait_tasks`, cancelled via `kill_task`); **resumable** via
  `resume_from: <subagent_id>`, which keeps the child's full transcript
  and tool state so the parent only describes what changed; an
  `isolation` parameter that can run the child in its own **git
  worktree** (`session/worktree_pool.rs`); a depth counter with a
  configurable maximum instead of pikuri's structural
  no-`agent`-in-the-persona rule; and children that receive a
  *compacted* copy of `AGENTS.md` rather than the full project
  instructions — with the description telling the parent to inline any
  convention the child actually needs. Each type's toolset is a named
  preset, and the read-only guarantee is spelled out in the source as a
  property of that preset: the `explore` toolset omits bash "so
  exploration cannot mutate the workspace — the read-only guarantee is
  enforced by the toolset, not merely by the prompt."

**Takeaway.** Pikuri's `agent` tool is closer in spirit to
opencode's `task` than to a simple "filter the parent's tools"
model: each delegation is identified by a *persona* the host
registers explicitly, so the child's toolset and system prompt
are both declared up front rather than inherited and trimmed.
That's where privilege separation comes from — a `FILE_MINER` persona
spawned from a coding agent with `bash` in scope still doesn't
get `bash`, because `bash` isn't in the persona's `tool_names`.
Opencode's `task` adds session persistence and resumability on
top, backed by SQLite; that's a fair amount of machinery for one
feature, not worth porting until pikuri has another reason to
introduce a session store.

The sentence in grok-build's source — "the read-only guarantee is
enforced by the toolset, not merely by the prompt" — is worth quoting
because it is pikuri's structural-defense argument, arrived at
independently by a team with no stake in pikuri's framing, and written
as a code comment rather than a security claim. Two projects reaching
the same conclusion from opposite directions (pikuri from the lethal
trifecta, grok-build from "what does `explore` need") is the strongest
external validation of the persona model in this document.

Where grok-build goes further and pikuri deliberately doesn't:
**resumability** (`resume_from` keeps a child's transcript, so a
follow-up costs one delta instead of a re-run) and **worktree
isolation** (parallel children editing the same repo without colliding).
Both are the same trade opencode's `task` makes — real capability for a
session store's worth of machinery. Pikuri's `GIT_REPO_RESEARCHER`
already does the throwaway-workspace half for the read-only case; the
worktree variant is what a *writing* sub-agent would need, and pikuri
has none.

### Bundled persona inventory

The mechanism comparison above is about *how* sub-agents work; this is
about *what ships by default*. Each project picks a different mid-line
between "ship nothing, host wires up everything" and "ship the whole
zoo."

| Project | Personas shipped | Source |
| --- | --- | --- |
| pikuri | `RESEARCHER` (web_search/web_scrape/fetch, 20 steps); `FILE_MINER` (file_list/read/grep/glob, 30 steps); `GIT_REPO_RESEARCHER` (git_clone + file_list/read/grep/glob + web reads, 30 steps, per-invocation temp workspace) — queued: `reviewer` | `pikuri-subagents/lib/pikuri/sub_agent/{researcher,file_miner}.rb`; `pikuri-code/lib/pikuri/code/git_repo_researcher.rb` |
| ruby_llm / langchainrb | none — no sub-agent surface | — |
| pi | `planner`, `reviewer`, `scout`, `worker` | `packages/coding-agent/examples/extensions/subagent/agents/` |
| opencode | `build`, `plan` (primary modes); `general`, `explore`, `scout` (subagents); `compaction`, `title`, `summary` (hidden housekeeping) | `packages/opencode/src/agent/agent.ts` |
| Claude Code | `general-purpose`, `Explore`, `Plan`, `statusline-setup`, `claude-code-guide` | <https://code.claude.com/docs/en/sub-agents> |
| grok-build | `general-purpose`, `explore`, `plan` (+ user-defined personas, + an orchestrator mode on the main agent) | `crates/common/xai-tool-types/src/task.rs`; toolsets in `xai-grok-agent/src/config.rs` |

Cross-cutting by role:

| Role | pikuri | pi | opencode | Claude Code |
| --- | --- | --- | --- | --- |
| read-only recon (cheap model) | `RESEARCHER` (web) + `FILE_MINER` (fs) + `GIT_REPO_RESEARCHER` (clone-and-dig) | `scout` (Haiku) | `explore` + `scout` | `Explore` (Haiku) |
| planner (read-only, intent-shaping) | — | `planner` (Sonnet) | `plan` (primary mode, not subagent) | `Plan` |
| reviewer (read-only correctness) | queued | `reviewer` (Sonnet, bash for git) | — | — |
| general-purpose catch-all | — (escape hatch documented in `ideas/subagent-deferrals.md`) | `worker` | `general` | `general-purpose` |
| infra housekeeping | — (synthesizer is hard-coded) | — | `compaction`, `title`, `summary` (tools: none) | — |
| UX helpers (slash-command-driven) | — (no slash commands) | — | — | `statusline-setup`, `claude-code-guide` |

**Takeaway.** Pikuri ships a lean persona set — three
(`RESEARCHER` + `FILE_MINER` + `GIT_REPO_RESEARCHER`) vs. pi's four,
opencode's eight, Claude Code's five — which matches the
read-it-in-an-evening ceiling: ship the personas that demonstrate
the mechanism along each axis, document the rest as queued in
`ideas/subagent-deferrals.md`, let downstream gems publish more if the ecosystem needs
them. The three break down as: `RESEARCHER` (web recon) and `FILE_MINER`
(fs recon) are the direct analogs of pi's `scout` / opencode's
`explore` / Claude Code's `Explore` — the universal "read-only
recon agent on a cheap model" role, split by *what* gets read.
`GIT_REPO_RESEARCHER` is the third axis: clone-and-dig over a
public repo, in its own per-invocation throwaway workspace. None
of the comparison set ships a direct analog — the closest move is
opencode/pi letting `bash` (with `git`) reach inside a sandbox,
but the persona shape collapses that into one privilege-separated
delegation with no `bash` in scope. The
next-strongest signal is "planner = read-only + intent-shaping,"
which pikuri has not committed to either way.

Notable shape differences:

- **grok-build's three built-ins are the same three Claude Code ships**
  (`general-purpose` / `explore` / `plan`), which makes that trio look
  like the settled convergent answer rather than one vendor's taste.
  Pikuri covers `explore` twice over — split by *what* is read
  (`RESEARCHER` web, `FILE_MINER` fs, `GIT_REPO_RESEARCHER` clone-and-dig)
  — and covers neither of the other two. The `planner = read-only +
  intent-shaping` signal noted below is now four-for-four across the
  projects that ship personas at all.
- **grok-build also has an orchestrator mode** — not a subagent but a
  system-prompt body appended to the main agent, telling it to delegate
  coding and exploration and to treat subagents "as expert peers, not
  junior helpers." A prompt-level answer to the same problem opencode
  solves with primary modes.
- **opencode mixes primary modes and subagents in one registry** —
  `build` and `plan` are not delegated children but modes of the main
  agent itself. pi and Claude Code (and pikuri) keep "modes" separate
  from "subagents."
- **opencode's hidden housekeeping agents** (`compaction` / `title` /
  `summary`) dress LLM-driven internal workflows up as personas with
  `tools: none`. Pikuri's equivalent — step-exhaustion synthesis —
  is hard-coded as `Pikuri::Agent::Synthesizer`, an internal recovery
  path the LLM never picks. Different style choice, same underlying
  trick (LLM-drive an internal task without exposing it as a tool).
- **pi ships personas under `examples/`**, leaving the persona
  inventory to be a per-host decision rather than a harness-core fact.
  Same shape as pikuri keeping bundled personas in pikuri-subagents
  rather than pikuri-core.
- **Per-persona model pinning** — only pi does this (haiku for
  `scout`, sonnet for the rest). Pikuri's `ideas/subagent-deferrals.md`
  §"Per-persona `model:`"
  records this as a deferred feature ("requires `ChatTransport`
  variations per sub-agent").

---

## Skills and MCP (pikuri additions since the last writeup)

Two extension surfaces pikuri grew that the comparison set hits unevenly:

### Skills

- **pikuri**: the `pikuri-skills` gem — `Skill::Catalog` (abstract base)
  + `Catalog::Bundled` (on-disk scanner) + `Skill::Renderer` (the XML) +
  `Skill::Extension` (the wiring) — implements the
  [Agent Skills standard](https://agentskills.io/specification).
  Discovery is **host-supplied, not walked**: `Catalog::Bundled.new
  (search_bases: [...])` scans `.pikuri/skills`, `.claude/skills`,
  `.agents/skills` under each base it is given, skipping missing ones.
  Precedence is bases left-to-right then subdirs in that order, first
  name seen winning (later duplicates warn and are dropped) — so
  "project beats global" is the *typical wiring*
  (`search_bases: [project_root, Dir.home]`, what `bin/pikuri-code`
  passes) rather than a rule the catalog enforces. One directory level
  only, each entry needing a `SKILL.md`; frontmatter validation is
  lenient — a missing `description` is the sole hard failure, everything
  else warns and loads, and a file with no frontmatter is skipped
  silently. Wiring is opt-in via `c.add_extension(Skill::Extension.new
  (catalog:, root:))`, which on a non-empty catalog contributes the
  `<available_skills>` block (same shape as PI's) as a system-prompt
  snippet and registers the `skill` tool that loads a named body on
  demand; an empty catalog is a no-op in both. `Catalog#roots` is
  exposed so the host can fold the skill dirs into the workspace's
  readable set, which is what makes a skill's sidecar files reachable
  through `read`. Nothing scans a `commands/` directory — flat `*.md`
  slash commands are not discovered.
- **pi**: implements the same Agent Skills standard; pikuri's
  implementation reuses pi's XML block shape so a skill folder authored
  against any compliant harness renders consistently here.
- **opencode**: ships its own skill mechanism (related but pre-standard).
- **grok-build**: the widest discovery net of anyone — `.grok/skills`,
  `.agents/skills`, `.claude/skills` *and* `.cursor/skills`, at local /
  repo / user tiers, walking every directory between CWD and the repo
  root, deduplicated by name with higher tiers winning. Vendor
  compatibility is a config cell you can switch off per vendor
  (`[compat.claude] skills = false`), and known vendor-shipped defaults
  (Cursor's `shell`, `canvas`, `statusline`) are always filtered out.
  Three details pikuri's catalog doesn't have: discovery deliberately
  **ignores `.gitignore`** (teams gitignore `.claude/**` as local config
  yet still expect project commands to work), a `[skills] disabled` list
  keeps a skill listed but inert (distinct from `ignore`, which hides it),
  and flat `*.md` under a `commands/` directory become user-invocable
  slash commands. It also ships **plugins** — a marketplace-installable
  bundle of skills + commands + agents + hooks + MCP servers, gated by
  the same folder-trust decision. Its catalog is **not** a system-prompt
  block — baseline and updates alike arrive as `<system-reminder>`
  injections, and a `paths:` frontmatter key holds a skill out of the
  listing until a tool reads or edits a matching file; see *How
  grok-build's conditional activation actually works* below.
- **ruby_llm, langchainrb**: no concept of skills.

#### Frontmatter: the six standard fields, and the nine invented ones

Verified 2026-08-16, against the spec and the same grok-build
`SOURCE_REV` as the rest of this document. The
[Agent Skills spec](https://agentskills.io/specification) defines
**exactly six** frontmatter fields:

| field | purpose | pikuri reads |
| --- | --- | --- |
| `name` | skill identifier | yes — falls back to the parent directory name |
| `description` | what it does / when to use it | yes — the only hard requirement |
| `license` | license identifier | no |
| `compatibility` | free text, ≤500 chars, for a human | no |
| `metadata` | arbitrary client key-value map | no |
| `allowed-tools` | tools the skill may use | no |

**None of the six expresses *when* a skill applies** — which is precisely
the field every harness wanting conditional activation has had to invent.
grok-build invents nine, all at top level (`discovery.rs:300–318`):
`short_description`, `author`, `argument_hint`, `model`, `effort`,
`user_invocable`, `disable_model_invocation`, `when_to_use`, `paths`.

Three findings worth carrying:

1. **grok-build uses the sanctioned extension point *and* top-level
   keys.** `metadata` is *"an arbitrary key-value mapping … clients can
   use this to store additional properties not defined by the Agent
   Skills spec"*, with a recommendation to pick "reasonably unique" key
   names. grok-build parses it (`discovery.rs` `parse_metadata`),
   promoting `metadata.author` and `metadata.short-description` to typed
   fields and keeping the rest in a generic string map — and documents
   that in its user guide. The nine extension keys sit at top level
   *alongside* that, which is off-spec for those nine (any could collide
   with a future official field), but the extension point is not
   declined. So a harness adding a key has a real fork with a proven
   precedent on both sides: grok-build's top-level spelling buys
   two-harness agreement and inherits the collision risk, while
   `metadata: {<vendor>-<key>: …}` is spec-clean, agrees with nobody, and
   is nonetheless the shape grok-build itself reads. For a *newly
   invented* predicate there is no agreement to buy, so `metadata:` wins
   by default. (An earlier revision of this finding said grok-build
   declined `metadata:` outright; that was wrong.)
2. **An empty `paths:` marks a skill *unconditional*, not "never".**
   `…/skill_discovery_tracker/conditional.rs:38` gates on
   `s.paths.as_ref().is_some_and(|p| !p.is_empty()) && …`, so `paths: []`
   means always-listed — the opposite of what an author writing "this
   skill matches no paths" would intend. Anyone reaching for `paths: []`
   as a spelling for human-invoked-only is reaching for an inverted one.
   `paths: ["**"]` lands the same way: `normalize_skill_paths`
   (`discovery.rs:243`) drops empties, strips a trailing `/**` (`src/**`
   → `src`), and returns `None` when the result is empty *or* every
   pattern is `**` — and `None` is exactly what "unconditional" is
   spelled as internally.
3. **Unknown keys fail open, everywhere.** pikuri's
   `Catalog::Bundled#parse_skill` reads `name`, `description`, `paths`
   and `when-to-use`, and drops the rest; Claude Code listed a skill
   carrying `argument-hint:`
   (a slash-command key, not a skill one) normally for months. A skill
   tagged with a key the host doesn't implement is simply advertised
   unconditionally — costing nothing and buying nothing until someone
   implements it. Qualified by finding 4: `paths:` is no longer unknown
   everywhere.
4. **`paths:` is not a grok-build invention — Claude Code implements it
   too.** Observed directly on 2026-08-16, on **Claude Code 2.1.233**
   (every observation in this finding is that one version — the behaviour
   is undocumented, so it carries no compatibility promise and a later
   build may move it). Claude Code is closed-source, so this is black-box
   evidence rather than a source citation, but the behaviour is
   unambiguous: five skills under `~/.claude/skills` were
   annotated with `paths:`, and the four whose globs matched nothing read
   that session vanished from the session's skill listing, while
   `ideas-folder` (`ideas/**`) stayed — `ideas/*.md` had been read.
   Reading a single `.rb` file then caused exactly the two
   `**/*.rb`-gated skills (`writing-rdoc`, `tuile`) to be announced
   mid-session **with their full descriptions**, while the `**/*.java`-
   and `src/test`-gated ones stayed hidden. That is grok-build's shape
   precisely: withheld until a touched file matches, then promoted
   description-and-all.

   **The pattern dialect is gitignore's, on both harnesses — measured
   2026-08-17.** grok-build's `skill_matches_any`
   (`skill_discovery_tracker/conditional.rs:96–121`, `main`) hands every
   pattern to an unmodified `ignore::gitignore::GitignoreBuilder` rooted at
   cwd and matches with `matched_path_or_any_parents`; `coerce_path_list`'s
   own doc comment says a `{a,b}` group is left intact *"for the gitignore
   matcher to expand"*. Claude Code 2.1.233 was then probed black-box —
   throwaway gated skills in a scratch project, each body revealing a magic
   word, the model told to *invoke* the skill and report the verbatim result.
   That invoke-or-error signal is the sound one: asking the model whether a
   skill was "available" contradicted itself across identical runs.

   | `paths:` | file read | Claude Code | rule |
   | --- | --- | --- | --- |
   | `probeleaf` | `unrelated/file.txt` | `Unknown skill` | the gate holds |
   | `probeleaf` | `probeleaf/file.txt` | activated | a direct hit fires |
   | `probeleaf` | `nested/probeleaf/file.txt` | activated | **a slash-less pattern floats to any depth** |
   | `/probeleaf` | `nested/probeleaf/file.txt` | `Unknown skill` | a leading slash roots it |
   | `nested/probeleaf` | `deep/nested/probeleaf/x.txt` | `Unknown skill` | a slash *anywhere* roots it |
   | `{alpha,beta}/**` | `beta/x.txt` | activated | a brace group expands |

   Two things that dialect is not. It is not **minimatch**, which is what
   Cursor's `globs:` and GitHub Copilot's `applyTo:` — the same idea under
   two other names — take: there `*` never crosses a `/`, so `foo` covers
   neither `nested/foo/` nor anything beneath the directory, and a pattern
   copied in from either under-matches here. And it is not **git's own**
   gitignore either: git treats `{a,b}` literally (a `.gitignore` of
   `{a,b}/**` hides nothing under `git check-ignore`, while `rg` hides both
   directories), so the brace row above is specifically ripgrep's flavour.

   **"Hidden" means unreachable, not merely unlisted.** Probed the same
   day: `skill(name: "writing-javadoc")` — on disk, valid frontmatter,
   `**/*.java` never touched — returned `Unknown skill: writing-javadoc`,
   *byte-identical* to the reply for a name that exists nowhere. So a
   gated skill is indistinguishable from a nonexistent one, and the
   listing withholds the **whole entry, name included** — Claude Code
   ships grok-build's capability gate, not a visibility filter. A rider
   that matters for anyone copying the shape: that refusal came back as a
   *tool-execution* error, not a schema rejection, so Claude Code's skill
   tool takes a **free-form** `name` rather than an enum of the active
   set. The two choices are a package — an enum of only-active names
   would have to be rebuilt on every promotion, churning the tool schema
   mid-session.

   **The gate binds the human operator too — in both harnesses.** In a
   fresh Claude Code session, `/writing-rdoc` — a skill the operator
   wrote, whose name they typed from memory — returned `Unknown command:
   writing-rdoc`. grok-build does the same by construction: `slash_skills()`
   (`skill_discovery_tracker/mod.rs:475`) combines `discovered_skills`
   with `startup_skills`, and `startup_skills` is what `take_unconditional`
   left behind after partitioning the gated ones into `ConditionalSkills::held`
   (`mod.rs:334-336`). `bridge.rs:411-415` calls that projection *"the
   authoritative source for slash command advertisement"*, and
   `SlashCommandSet::skill_resolvable` (`slash_commands.rs:659-665`)
   searches only it — so a gated name does not resolve when typed, not
   merely fail to autocomplete. The one accessor that reaches held
   skills, `ConditionalSkills::held` — commented *"so registry-wide
   lookups can see skills the listing withholds"* — has exactly one
   consumer, `suggest_skill_path`, a **model-facing** did-you-mean for a
   failed `SKILL.md` read. There is no operator escape hatch in either
   implementation.

   Two riders on that, both cutting against copying it uncritically.
   `paths:` is **absent from grok-build's own user guide**, whose
   optional-frontmatter table documents ten other fields — so this is
   convergence on undocumented behaviour. And that guide documents
   `user-invocable: false` (*"hide it from slash commands"*) and
   `disable-model-invocation: true` (*"only your slash command runs the
   skill"*) as deliberately **orthogonal** axes for the two audiences —
   which `paths:`, undocumented, collapses. The behaviour is what two
   harnesses do; it is not obviously what either designed.

   Three further behaviours, observed in the same session and worth
   having because they are the parts a reimplementation gets wrong:
   **Bash does not count as a touch** — repeated `grep`/`sed` over `.rb`
   files through the shell promoted nothing across four separate turns,
   and a single `Read` of one `.rb` file promoted both `**/*.rb` skills
   at once; **promotion is once per conversation** — `ideas-folder` fired
   on the first `ideas/` read and never re-fired across a later read, a
   write and an edit in the same folder; and the announcement carries the
   description only, never the body.

   Two riders. Claude Code did **not** render `when-to-use:` in those
   announcements, so it implements at least one of grok-build's nine
   extensions and not another — a reminder that "non-standard" is not one
   bucket. And the practical consequence for a shared skill folder is
   that annotating it is *not* inert: `~/.claude/skills` is where most
   pikuri-visible skills actually live, so a `paths:` added for pikuri's
   benefit changes Claude Code sessions today.

   For pikuri the load-bearing part is convergence: **two independent
   harnesses ship this predicate**, which makes it an emerging extension
   rather than one vendor's idea, and turns finding 1's "grok-build's
   spelling buys two-harness agreement" into three. It is also the
   strongest available argument that pikuri is now *behind* on this axis
   rather than declining to follow a fad.

`compatibility` is the nearest existing field in spirit — its own
examples are *"Requires git, docker, jq"* and *"Designed for Claude
Code"* — but it is free text aimed at a human judging "will this work in
my environment". Nothing parses it, and it cannot carry a machine
predicate.

#### How grok-build's conditional activation actually works

Read 2026-08-16 against `main` at `5163763` — a newer monorepo sync than
the `84ae1223` the rest of this document cites, so treat this subsection
as the later reading where the two disagree. Five mechanics; the third
has consequences well beyond skills. grok-build is the only harness whose
*implementation* can be read, but per finding 4 above it is not the only
one shipping the feature, so read this as the documented reference
implementation of a predicate two harnesses now honour.

**1. The trigger is a file the model *touched*, not a project shape.**
`SkillDiscoveryReminder` runs after every tool call, but
`extract_activation_paths` (`reminders/skill_discovery.rs:68`) yields
paths from only four output variants — `ReadFile`, `ListDir`,
`SearchReplace`, and `ApplyPatch` (every file of a multi-file patch,
rename targets included). Its comment is explicit that *"Bash/grep paths
are excluded (unparseable / incidental)"*. So `paths: [build.gradle]`
fires only when the model **reads or edits** that file; a `grep` hit, a
`bash` invocation, or the file merely existing in the project all fail
to activate it. `paths:` cannot express "this is a Gradle project".

**2. Matching is gitignore syntax; activation is sticky and
session-scoped.** `skill_matches_any` (`conditional.rs:96`) builds an
`ignore::GitignoreBuilder` matcher from the patterns relative to cwd and
uses `matched_path_or_any_parents`, so a bare directory pattern matches
files beneath it. Activated skills stay in `held`, gated by an
`activated` set, so a re-seed can re-promote them; `/clear` calls
`rehide()` (`conditional.rs:86`), which clears activations and
re-partitions so a promoted skill drops back to held.

**3. There is no resident skill catalog in the system prompt at all —
the startup baseline is an injection too.** `<available_skills>` occurs
in exactly one file repo-wide (the tracker's listing renderer); no
prompt template renders it. `seed()` marks `pending = BaselineChange`
and the first `take_pending()` emits the whole listing as a
`<system-reminder>`, the same channel a later activation uses. A test is
named for the property: `seed_produces_system_reminder_not_prompt_mutation`
(`skill_discovery_tracker/mod.rs:1047`). Two consequences worth
borrowing independently of `paths:`. Promotion mutates no prefix, so it
costs no prompt-cache invalidation — the cost that would otherwise price
conditional activation out on a provider that hoists system content.
And skill descriptions, which are attacker-influenceable text in a
bundle that travels between harnesses, sit in *conversation* position
rather than the most-trusted slot in the request — which is where
untrusted text belongs, and which pikuri's own `<available_skills>`
system-prompt snippet does not do.

**4. `when-to-use:` is a rendering split, and the renderer retro-fits it
when the field is absent.** Parsed as either `when-to-use` or
`when_to_use`, capped at 1024 chars like `description`. Rendered as
`description — Use when: <trigger>` (XML) or a separate `Use when:` line.
When the field is missing, `build_skill_entry` (`listing.rs:525`) derives
one by splitting the *description* at the first of ten recognized
connectives (`use this skill when`, `use when`, `triggers on`,
`invoke when`, …, case-insensitive) and treating the tail as the trigger;
the leading connective is then stripped so the renderer's own label isn't
doubled, with a word-boundary guard so `Use whenever` doesn't match. A
description that *opens* with a connective is left unsplit (the
before-half would be empty). The split takes everything after the first
match, so trailing non-trigger prose lands in the trigger half — the
practical argument for authoring the field rather than relying on the
extractor.

**5. Names-only listing exists, but only as budget overflow.** Per entry,
`description` + `when_to_use` share a 400-byte cap, split proportionally
to their lengths with a 20-byte floor each; the listing as a whole gets
50 % of the context window. `name_only()` renders when that budget runs
out. A comment at `mod.rs:446` records that a names-only footer for
disabled skills was considered and rejected because it *"wastes tokens
and looks like skills with no description"* — so no surveyed harness
ships a names-only catalog even as a fallback design, let alone a
baseline.

One signal about maturity: **`paths:` is the single extension key absent
from grok-build's own user guide.** The Optional Frontmatter Fields table
documents `when-to-use`, `allowed-tools`, `argument-hint`,
`user-invocable`, `disable-model-invocation`, `model`, `effort`,
`license`, `compatibility` and `metadata` — every extension key except
this one. It is shipped but unadvertised.

### Slash commands (the human-invoked half)

- **Claude Code**: `~/.claude/commands/*.md` (user) and
  `.claude/commands/*.md` (project), subdirectories namespacing as
  `/frontend:foo`. Frontmatter: `description`, `argument-hint`,
  `allowed-tools`, `model`, `disable-model-invocation`. The body
  interpolates `$ARGUMENTS` and `$1`…`$9`, inlines a file with `@path`,
  and — the load-bearing one — runs a shell command with `` !`cmd` ``
  *before the prompt is sent*, gated only by that same file's
  `allowed-tools:`, i.e. by the untrusted file itself.
- **grok-build**: flat `*.md` under a `commands/` directory. No harness
  in this survey defines an `.agents/commands` convention, which is why
  pikuri scans two subdirs and not three.
- **pikuri**: `Command::Registry` + `Command::Renderer` in
  `pikuri-skills`, over the same `Bundle::Base` search bases as the skill
  catalog. Names come from the path (a frontmatter `name:` is ignored —
  for a command the name is the *address the human types*). Frontmatter
  is entirely optional. Neither inlining leg ships:
  `` !`cmd` `` is refused outright and `@path` is simply left as literal
  text (`DECISIONS.md` `D-command-inlining-legs`), and `allowed-tools:`
  is refused too rather than silently widening a toolset its author
  asked to narrow. `disable-model-invocation` is the *default and the
  only* behaviour — pikuri never advertises a command to the model.

**Measured against Claude Code 2.1.233** (headless, throwaway project,
each result reproduced on two models), because three of its behaviours
are documented nowhere:

1. The expansion is **wrapped** in `<command-message>` /
   `<command-name>` / `<command-args>`, the last omitted when no
   arguments were typed. The wrapper carries no *location*, so it does
   not solve sidecar-path resolution; pikuri ships a
   `(this command lives in …)` footer instead.
2. Arguments a body never references are **appended** after two blank
   lines as `ARGUMENTS: <raw>`. pikuri copies that spelling verbatim, so
   a body authored there reads identically here.
3. `$n` is **0-based** — `/probed AAA BBB CCC` against
   `one=[$1] two=[$2] three=[$3]` yields `one=[BBB] two=[CCC]
   three=[$3]` — while being documented as 1-based and written as 1-based
   by every author, including in Claude Code's own shipped command files.
   pikuri implements 1-based (`D-command-substitution`). An out-of-range
   `$n` stays literal there, and pikuri keeps that half.

### MCP (Model Context Protocol)

- **pikuri**: `Mcp::Registry` (pure config) + `Mcp::Servers` (runtime —
  spawns servers, holds clients, registers `at_exit`) + per-client
  `Mcp::ClientWrapper` (restart-on-stdio-death retry) +
  `Mcp::Synthesizer` (LLM-driven summarization of MCP tool surfaces
  whose `instructions`/`serverInfo.title` are unhelpful) +
  `Mcp::Verifier` (pre-flight prompt-injection check: mechanical
  Unicode pre-pass + LLM inspection for instruction-override,
  exfiltration, tool-chain hijacking, authority-impersonation) +
  `Mcp::Cache` (on-disk, keyed on the full server surface so any
  upstream change invalidates). Two transports — stdio (carve-out
  from the `Subprocess.spawn` chokepoint) and HTTP (plain Faraday). MCP
  tools bypass `Pikuri::Tool` and are synthesized as raw `RubyLLM::Tool`
  subclasses with a provenance prefix; the LLM connects on demand via
  the auto-registered `mcp_connect` tool.
- **opencode**: ships MCP support; pikuri's `Mcp::Servers` is informed
  by opencode's shape but uses the `mcp` Ruby gem for the transport
  layer.
- **grok-build**: MCP servers from config, gated by folder trust, plus
  the `search_tool` / `use_tool` deferred-loading pair described under
  §"Available tools" — a BM25 index over the tool catalog instead of
  every schema in the window. Descriptions are truncated to 2 KB with a
  fingerprint `(tool_count, description_hash, names_hash)` used to detect
  when a server's surface changed. No pre-flight injection scan; the
  trust gate is the analogous control, and it fires earlier (before the
  server is spawned) but is coarser (whole workspace, not per-server).
- **ruby_llm, langchainrb, pi (core)**: no MCP. Could be wired
  externally via the `mcp` gem.

### Memory

Only two projects here ship cross-conversation memory, and they picked
opposite substrates.

- **pikuri** (`pikuri-memory`): durable memory backed by **mem0**, run as
  a self-managed sidecar, with a `recall` tool plus per-turn prefetch and
  capture.
- **grok-build**: **Markdown files plus a local SQLite index** —
  `~/.grok/memory/MEMORY.md` global, `<project-slug>-<hash8>/MEMORY.md`
  per workspace (keyed on the `origin` remote in `org/repo` form when
  there is one, so clones and worktrees of a repo share memory), plus
  per-session logs. Search is **FTS5 keyword by default, with `vec0`
  vector search layered on when an embedding model is configured**. Two
  `memory_search` / `memory_get` tools. Experimental, off by default.
  Automatic per-session saves are *metadata only* and use **no LLM call**
  (message counts, up to five substantive prompt topics, timestamp);
  richer capture is an explicit `/flush`, and a `/remember` write shows
  the user a review panel — with an optional rewritten version — before
  anything is written.

The substrate difference matters more than the feature difference.
grok-build's memory is greppable Markdown a human can edit, versioned
by nothing and owned by the user; pikuri's is a service. Given pikuri's
privacy-first positioning and its "small enough to audit" ceiling,
Markdown-plus-SQLite is arguably the more pikuri-shaped answer than the
one pikuri shipped — and the fallback ladder (FTS5 always, vectors only
if an embedder is configured) is exactly the degradation story
`pikuri-vectordb` has to tell anyway. Worth revisiting; not worth
churning a shipped gem over.

Two mechanisms are cheap and orthogonal to the substrate: the
**no-LLM-call automatic save** (metadata summaries cost nothing and
still make a session findable later) and the **confirm-before-write
review panel**, which is the `Confirmer` seam applied to memory writes —
a place pikuri's memory capture currently writes unattended.

**Takeaway.** Both Skills and MCP are extension surfaces pikuri added
deliberately — Skills for "give the agent static text knowledge that
loads on demand" and MCP for "expose third-party tool servers the user
already runs." Both auto-wire when their corresponding registry/catalog
is non-empty, and `EMPTY` singletons let the no-feature path stay zero-
config. The `Mcp::Verifier` is the novel-to-pikuri piece — pre-flight
injection scanning of an MCP server's surface before any tool is
exposed to the LLM, with `InjectionDetected` aborting startup for that
server.

---

## Ideas to borrow

Sorted by fit-for-pikuri, from "do this now" to "out of scope". Items
marked **DONE** have shipped; items marked **FREE NOW** require nothing
more than wiring through ruby_llm's existing primitive.

### A-tier — high fit, low cost

1. **Bring all tool descriptions up to the opencode bar** — **DONE**.
   All bundled tools (calculator, web_search, web_scrape, fetch,
   sub_agent, skill, read, write, edit, grep, glob, file_list, bash,
   mcp_connect)
   use the heredoc summary + `Usage:` bullets shape. The pikuri variant
   of the pattern factors universal `Error: ...` recovery into each
   binary's system prompt rather than restating it per-tool. Convention
   documented in `CLAUDE.md`.
2. **Examples in parameter descriptions** — **DONE**. Every string
   parameter carries an inline `e.g. "..."` example in the ruby_llm
   pattern. Integer parameters describe their default and cap, which
   serves as the anchoring equivalent. Codified in `CLAUDE.md`.
3. **Unicode confusable handling in `Edit`** (grok-build). Smart quotes,
   em-dashes, ellipses and non-breaking spaces pasted in from a chat app
   or a doc render identically to ASCII in `Read`, so the model's ASCII
   `old_string` never matches and the edit fails for a reason the model
   cannot see. Take the *diagnosis*, not grok-build's repair: on a
   zero-match, retry against a confusable-normalized copy and, if it
   matches, name the offending codepoint and line instead of editing.
   Repair would need a byte-offset remap, because `Edit`'s
   whole-file CRLF normalization would otherwise rewrite every smart
   quote in the file behind a "1 occurrence" confirmation. Keep the map
   narrow either way — grok-build excludes `U+2212 MINUS` and `U+00D7
   MULTIPLICATION` because they carry meaning — and keep it separate
   from `Sanitizer`, whose set is about deception, not accident. See
   `ideas/grok-build-cheap-borrows.md`.
4. **Sparse line-number anchors in `Read`** (grok-build) — **REJECTED**,
   listed so it isn't re-proposed. Cheaper per read, but pikuri already
   chose `cat -n` for training-data familiarity and had that confirmed
   by an outside-model review; see §"Edit addressing" for the
   vendor-can-tune-the-model / harness-cannot test that kills it, and
   `ideas/grok-build-cheap-borrows.md`.
5. **Interpolate caps from the constant that enforces them** (grok-build).
   The portable half of grok-build's description-template machinery,
   minus the machinery — and already the in-tree convention for `bash`,
   the three `thunderbird_*` searches, both `fileindex_*` tools and
   `read`. Three tools still type the number by hand: `fetch` and
   `web_scrape` restate constants that already exist and are already
   what `.clamp` enforces, and `web_search` states a cap
   ("most providers cap this at 20") that nothing enforces and pikuri
   cannot verify. See `ideas/grok-build-cheap-borrows.md`.
6. **Tool-emitted `:halt` signal** — **FREE NOW**. ruby_llm's
   `RubyLLM::Tool::Halt` lets a tool short-circuit: returning
   `halt("done")` from `execute` ends the chat without a follow-up
   model call. Pikuri's synthetic-tool factory already passes any
   return value through verbatim, so the only thing missing is a
   `Tool::Halt` helper or convention in pikuri's API and a doc note in
   `pikuri-core/lib/pikuri/tool.rb`. Cheap.

### B-tier — worth it but more invasive

7. **Over-cap tool output: truncate the middle, spill to disk** (all of
   PI, opencode, grok-build). Per-tool byte caps already exist in
   `Bash` / `Read` / `WebScrape`; the missing pieces are writing the
   overflow to a `Paths.new_temp` file and returning the path so the
   model can `grep` it, and keeping the **tail** as well as the head —
   a build's error summary lives at the end, so head-only truncation
   discards the answer. Cross-cutting version tracked in
   `ideas/security-open-questions.md` §"Output-size DoS and cost".
8. **Tool dependency expressions** (grok-build's `requires_expr`). A
   tool declares which other tools it needs — grok-build's `task`
   requires the kinds that retrieve and kill its results — and the
   registry validates it when the toolset is finalized. Pikuri has no
   guard on an incoherent `Persona#tool_names` or `bin/pikuri-*`
   wiring; the failure surfaces as model confusion at runtime instead.
9. **Folder-trust gate before repo-supplied config** (grok-build,
   Claude Code). `Skill::Catalog::Bundled` scans `.pikuri/skills`,
   `.claude/skills` and `.agents/skills` under the project root, so a
   cloned repository's skill names and descriptions reach the system
   prompt with no trust decision. The `skill` tool already classifies a
   skill body as `untrusted: :hard`; the gap is a gate on the *source*,
   resolved once per workspace. grok-build's refinement worth copying:
   a "there were no repo configs" allow is never cached, so a skill
   that appears after a `git pull` is re-checked.
10. **Per-segment display of chained shell commands in `Confirmer`**
    (grok-build). Split the command on `&&`, `||`, `;`, `|` and
    newlines and show the human the segments; refuse to split — and say
    so — on subshells, `$(…)`, backticks, or control flow. Pure
    presentation, lands in the confirmer where presentation belongs,
    and directly serves the anti-fatigue argument in the book's
    [security chapter](book/security.md).
11. **Method-signature introspection as a Parameters fallback** (ruby_llm).
   When a tool's `execute` Proc has typed kwargs, derive the schema
   automatically. Trade-off: descriptions still need to live somewhere — so
   this saves typing only for the dumbest tools. Keep the explicit builder as
   the primary path.
12. **Tool descriptions in separate `.txt` files** (opencode pattern). Easier
   to iterate on a multi-paragraph description without touching Ruby. Wait
   until any single description gets long enough to be awkward in a heredoc.
13. **One-class-many-functions tools** (langchainrb's `define_function`
   pattern, where a `MovieInfoTool` class exposes both `search_movie` and
   `get_movie_details` as separate function entries). Reduces boilerplate
   when a single capability really does have multiple operations. Today
   pikuri's coding tools each have their own class; bundling them into a
   `FileSystem` tool with multiple functions would lose the per-tool
   workspace/confirmer wiring but might be worth revisiting for tightly-
   coupled tool families.

### C-tier — only when scope changes

14. **Permission system with glob rules** (opencode, grok-build). Pikuri
    ships `Workspace` + `Confirmer` as v1; the three-action `allow` /
    `deny` / `ask` glob model is the right next step once friction shows
    up. Tracked in `ideas/coding-agent.md`. grok-build is the richer
    reference of the two — evaluation by severity rather than by source,
    per-segment matching, and a curated read-only command allowlist whose
    *exclusions* (`tee`, `cargo check`, `rg --pre`, and any `git` command
    whose local config installs an executable hook) are the part worth
    reading before writing any auto-approval logic.
15. **Stall detection for `StepLimit`** (grok-build's goal mode). Its
    supervisor fingerprints the remaining gaps after each attempt and
    trips when two consecutive attempts produce an identical
    fingerprint — the model is looping, not converging. The full goal
    subsystem is out of scope; the fingerprint alone is a better
    exhaustion signal than a step count, and would compose with the
    existing `on_exhausted: :synthesize` path.
16. **Content-hash anchors as an edit-addressing arm** (grok-build's
    `hashline_*`). A third answer alongside unique-string matching and
    patch-with-context: `read` returns `LINE:HASH→CONTENT`, `edit`
    addresses by anchor, a stale anchor fails loudly and the error
    carries fresh anchors so the model retries without re-reading.
    Rejected for now as line-range-with-the-staleness-hole-closed
    (`DECISIONS.md` `D-single-hunk-edit`), and the arm to read first if
    payload size ever displaces call count as the problem — but note
    grok-build ships the scheme as a *parameter* with a benchmark
    harness, so the question isn't settled there either.
17. **Deferred MCP tool loading via search** (grok-build's
    `search_tool` / `use_tool`). A keyword index over the MCP catalog
    plus one meta-dispatch tool, instead of every schema in the window.
    Same goal as pikuri's `mcp_connect` with a different lever; scales
    better when one server exposes a hundred tools.
18. **Markdown-plus-SQLite memory substrate** (grok-build). Greppable,
    human-editable files with an FTS5 index and optional vector search
    when an embedder is configured, versus `pikuri-memory`'s mem0
    sidecar. Arguably the more pikuri-shaped answer on privacy and
    auditability grounds; not worth churning a shipped gem over, but
    the no-LLM-call automatic save and the confirm-before-write review
    panel are separable and cheap.
19. **Structured event stream** — **DONE**. The `Agent::Event` sealed
   hierarchy + four bundled listeners covers the surface that was a
   `puts`-only path in the previous writeup. New rendering sinks (web
   UI, JSON log, TUI) plug in by subclassing `Listener::Base`.
20. **Streaming deltas** — **DONE**. Opt-in via `Agent.new(streaming:
    true)`; per-chunk `{Thinking,Assistant}Delta` events flow alongside
    the message-level bookends and propagate to sub-agents and the
    synthesizer consistently. The bundled `Terminal` listener still
    renders on message bookends; a delta-rendering listener is the
    straightforward next step.
21. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to
    SSH/sandbox/cloud. Pikuri's `Subprocess.spawn` chokepoint is the
    seam where this would hook in; today it only spawns local.
22. **Multi-provider abstraction** — **DONE** via the ruby_llm
    migration. Switching pikuri from llama.cpp/OpenAI-shape to
    Anthropic / Gemini / Bedrock / Ollama / etc. is a one-block edit
    in each `bin/pikuri-*`'s `RubyLLM.configure`. No library code change.
23. **Vector search / RAG primitives** (langchainrb). Pikuri is an agent,
    not a RAG framework — out of scope by design. If a future binary
    needs RAG, it can compose `langchainrb`'s vector stores externally
    rather than pulling that scope into pikuri itself.

### Out of scope

24. **Effect-based service architecture** (opencode). Massively too heavy
    for a project this size.
25. **LSP integration** (opencode, grok-build). Deferred under
    "Coding-agent deferrals" until a concrete use case shows up.
    grok-build's variant is worth knowing about — a full LSP client
    manager whose diagnostics ride back to the model as a
    `<system-reminder>` appended to tool output after an edit — but the
    dependency (a running language server per project) is exactly the
    weight pikuri is avoiding.
26. **Steering / follow-up message queues** (pi). Pikuri's
    `Control::Interloper` already covers the mid-loop-injection case
    that motivated this idea in `bin/pikuri-code`'s REPL; a richer
    pi-style queue model is unmotivated today.
27. **Persistent / resumable subagent sessions** (opencode, grok-build).
    Requires a session store. Not worth it for one feature.
    grok-build adds **git-worktree isolation** for a child that writes,
    which is the natural companion; pikuri's `GIT_REPO_RESEARCHER`
    already does the throwaway-workspace half for read-only children,
    and no pikuri persona writes.
28. **Parallel toolsets as an A/B harness** (grok-build). Registering
    several interchangeable implementations of each capability — its
    own, plus ports of codex's and opencode's — and selecting per
    session is the right design *if you are tuning a model against tool
    surfaces*. Pikuri is a harness, not a model vendor: it should ship
    one implementation per capability and spend the complexity budget
    elsewhere. See §"grok-build's registry" for the three mechanisms
    from it that *are* worth having on their own.
29. **In-process kernel sandbox** (grok-build's Landlock / Seatbelt
    applied at startup). It covers the agent's own filesystem calls, not
    just the shell subprocess — strictly stronger than pikuri's
    bubblewrap-around-`Bash`. But pikuri's file tools run in-process as
    the real user *on purpose*, so `File.writable?` is exact and backs
    the confirm-writable-writes posture (`CLAUDE.md` §Workspace seam).
    Adopting this would mean giving that up. A real fork, decided the
    other way.

---

## Sources

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
  skills, memory, subagents). *Skills → How grok-build's conditional
  activation actually works* was read later, against `main` at
  `5163763` — `crates/codegen/xai-grok-tools/src/{types/skill_discovery_tracker/{conditional,listing,mod}.rs,implementations/skills/discovery.rs,reminders/skill_discovery.rs}`
  and `crates/codegen/xai-grok-agent/src/prompt/skills.rs`
