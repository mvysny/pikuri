# COMPARISON.md

A side-by-side look at how three OSS agent-or-agent-adjacent projects solve the
same problems pikuri solves, and a ranked list of ideas worth porting.

## Projects in this comparison

| Project | Language | Scope | Loop size | Key abstraction |
| --- | --- | --- | --- | --- |
| **pikuri** (this repo) | Ruby | small general-purpose CLI agent | ~50 lines (`Agent#run_loop`) | `Tool` value object + `ChatLog` |
| **ruby_llm** ([crmne/ruby_llm](https://github.com/crmne/ruby_llm)) | Ruby | multi-provider SDK + Rails integration | ~37 lines across `Chat#complete` + `Chat#handle_tool_calls` | `RubyLLM::Tool` subclass + provider adapters |
| **pi** ([earendil-works/pi](https://github.com/earendil-works/pi)) | TypeScript | extensible coding-agent harness | ~700 lines (`agent-loop.ts`) | Typebox-typed tools + extensions/skills |
| **opencode** ([sst/opencode](https://github.com/sst/opencode)) | TypeScript | full terminal coding agent (Claude-Code-shaped) | effect-based, split across `processor.ts`/`session.ts` | Effect services + `.txt` prompt files |

The three are at very different scopes:

- **ruby_llm** is the only direct apples-to-apples comparison: a Ruby library
  whose `Chat`/`Tool` map cleanly to pikuri's `Agent`/`ChatLog`/`Tool`.
- **pi** is a coding-agent harness: same shape as a Claude-Code-style CLI but
  designed as a thin core with everything (sub-agents, plan mode, MCP, perms)
  pushed to extensions.
- **opencode** is much bigger than pikuri — closer to Claude Code itself. The
  value here is mining ideas, not comparing line counts.

Pikuri sits between ruby_llm (just a library) and pi/opencode (full agents):
it's a small *general-purpose* assistant with a usable loop and a fixed,
deliberate set of tools.

---

## Agent loop

| | Loop shape | Streaming | Termination | Step budget |
| --- | --- | --- | --- | --- |
| pikuri | imperative `times` over `chat → run tool calls → log` (`lib/agent.rb:55`) | no — single non-streaming call | `:stop` from `finish_reason` or `max_steps` exceeded | yes (`max_steps`) |
| ruby_llm | recursive: `Chat#complete` calls itself after running tool calls (`lib/ruby_llm/chat.rb:156–293`) | yes, optional via block | LLM returns no tool calls, OR `Tool::Halt` short-circuits | no — bounded only by `Halt` |
| pi | nested loops: outer for follow-up queue, inner for steering+tools (`packages/agent/src/agent-loop.ts:155–269`) | yes — `EventStream<AgentEvent>` | `shouldStopAfterTurn()` hook, `stopReason`, abort | implicit via context-window compaction |
| opencode | one-shot processor returning `"compact" \| "stop" \| "continue"` per turn (`src/session/processor.ts:115–425`) | yes — Vercel AI SDK chunk events | model emits no tool calls → `"stop"` | no — context overflow → `"compact"` |

**Takeaway.** Pikuri's loop is the smallest by a wide margin and is the easiest
to read. The cost is that it has no streaming, no events, no hooks, and the
host's only observability channel is the `puts` calls inside `run_loop`.
Whether that's a bug depends on whether pikuri ever wants a TUI / JSON output /
test hooks. Today: no, and the simplicity is worth keeping.

---

## Provider / transport abstraction

- **pikuri**: hand-rolled `OpenAIClient` (Faraday) + `ChatParser`. Targets
  OpenAI-compatible only by deliberate scope decision (CLAUDE.md). Wire
  format owned in `lib/openai_client.rb`.
- **ruby_llm**: provider-per-class (`lib/ruby_llm/providers/{openai,anthropic,gemini,bedrock,ollama,...}/`).
  Tool schema stays canonical; per-provider adapters wrap it.
- **pi**: own multi-provider layer in `@earendil-works/pi-ai` covering OpenAI,
  Anthropic, Google, Bedrock, etc.
- **opencode**: built on Vercel AI SDK. Adding a provider is one entry in
  `BUNDLED_PROVIDERS` (`src/provider/provider.ts:93–118`).

**Takeaway.** The other three pay the multi-provider tax up front; pikuri
explicitly doesn't, and that's fine for its scope. If pikuri ever wants a
non-OpenAI backend, ruby_llm's "canonical schema + thin adapter per provider"
is the right shape to copy — not opencode's SDK-of-SDKs approach.

---

## Tool abstraction

| | Definition style | Schema | Validation strictness |
| --- | --- | --- | --- |
| pikuri | `Tool.new(...)` constants, stateless | fluent `Tool::Parameters` builder → JSON Schema | strict: unknown keys rejected with DidYouMean, type coercion, all errors collected |
| ruby_llm | subclass `RubyLLM::Tool`, class-level DSL | three options: `params { ... }` block, `param :name` declarative, OR auto-inferred from `execute` keyword args | strict but **no DidYouMean** |
| pi | `AgentTool<TParameters>` interface, factory functions | Typebox `Type.Object()` (compile-time + runtime) | Typebox-strict; optional `prepareArguments()` shim for LLM quirks |
| opencode | Effect Schema decoders (Zod-shaped) + `.txt` description files | Effect `Schema.decodeUnknownEffect()` | strict; failure produces "rewrite the input so it satisfies..." message |

**Takeaway.** Pikuri's strict-with-DidYouMean validator is genuinely good and
ruby_llm's lacks it. The interesting idea from ruby_llm is **method-signature
introspection** as a fallback: if no `param` is declared, reflect on the
`execute` Proc's keyword args and auto-fill the schema. Cheap to add; cuts
boilerplate for trivial tools. Trade-off: pikuri's explicit builder keeps
descriptions next to the schema, which is hard to give up entirely.

---

## Available tools

| | calc | shell/bash | read | write | edit | grep | glob | search | scrape/fetch | sub-agent | todo/plan | LSP |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pikuri | ✅ | — | — | — | — | — | — | ✅ web_search | ✅ web_scrape + fetch | ✅ | — | — |
| ruby_llm | — (SDK only — no bundled tools) | | | | | | | | | | | |
| pi | — | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ find | — | — | — (extension) | — (extension) | — |
| opencode | — | ✅ shell | ✅ read | ✅ write | ✅ edit + patch | ✅ grep | ✅ glob | ✅ search (Exa) | ✅ fetch | ✅ task | ✅ todo + plan | ✅ |

ruby_llm ships **no tools at all** — it's an SDK; the developer subclasses
`RubyLLM::Tool` and wires their own. pi ships only file/shell ops; web search,
sub-agents, etc. are pushed to extensions. opencode is the most batteries-
included.

**Takeaway.** Pikuri's tool set (calc, web_search, web_scrape, fetch,
sub_agent) is well-scoped for a *general-purpose* assistant — the pi/opencode
file/shell stack is what you want for a *coding* agent. They don't overlap.

---

## Tool description quality

This is the section most worth reading. The LLM only gets to see the
`description` and per-parameter strings; their quality directly affects how
often the model picks the right tool with the right arguments.

### pikuri (verbatim)

```
calculator:
  Evaluates a basic arithmetic expression and returns the numeric result.
  Use this for any arithmetic beyond simple mental math. Supports +, -, *,
  /, ** (exponentiation), %, parentheses, and decimal numbers. No variables
  or functions — pass concrete numbers only.

web_search:
  Searches the web for a query and returns the top results as a Markdown
  list of titles, links, and short snippets. This tool is often
  rate-limited/bot-blocked.

web_scrape:
  Scrapes the rendered webpage, PDF or text file at the given URL and
  returns its main content as Markdown.

fetch:
  Downloads the given URL and returns its body verbatim. Accepts text/* and
  a fixed allowlist of textual application/* types (JSON, XML, JavaScript,
  XHTML, RSS, Atom); refuses PDFs, images, and other binary content. Prefer
  web_scrape for rendered HTML pages or PDFs — web_scrape extracts the
  readable content, while fetch returns the raw bytes.
```

Pikuri's are inconsistent: `fetch` and `sub_agent` have explicit "use this for
X, not Y" guidance baked in; `web_scrape` is one line; `web_search` doesn't
say anything about caching or what `max_results` actually does at the high
end.

### ruby_llm (from spec fixture — there are no shipped tools)

```ruby
class Weather < RubyLLM::Tool
  description 'Gets current weather for a location'
  param :latitude, desc: 'Latitude (e.g., 52.5200)'
  param :longitude, desc: 'Longitude (e.g., 13.4050)'
end
```

The standout is **example values inside parameter descriptions**
(`'Latitude (e.g., 52.5200)'`). Pikuri's calculator does this for `expression`
("e.g. \"155 / (58 * 1000.0 / 3600)\"") but most other params don't. Free
upgrade.

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
constraints, including failure modes the LLM can hit_ — is the gold standard.
Pikuri's `sub_agent` description already does most of this; the other tools
should be brought up to that bar (see the "Ideas to borrow" section).

---

## Conversation / message types

- **pikuri**: `ChatLog` with `Data.define`'d `Message`. Strict role validation:
  bad role/field combinations raise in the constructor. Protocol-agnostic.
- **ruby_llm**: plain Array of `Message` objects (no log wrapper). Roles
  validated per-instance against a frozen list. Same four roles plus
  `tool_call_id`, `tokens`, `model_id`, `thinking`, `raw`.
- **pi**: TypeScript discriminated union; custom message types extensible via
  declaration merging. Coder-supplied `convertToLlm()` filters them before the
  LLM call.
- **opencode**: `MessageV2` with `ErrorPart` / `ToolPart` / `TextPart` etc.;
  parts are typed and persisted in SQLite per session.

**Takeaway.** Pikuri's `ChatLog::Message` validation (illegal-state-impossible
constructor) is roughly equivalent to ruby_llm's and stricter than pi's
runtime story. No change needed.

---

## Error handling

| | Tool argv malformed | Tool execute failure (recoverable) | Tool execute failure (bug) |
| --- | --- | --- | --- |
| pikuri | `"Error: <msg>"` string fed back to model (with full schema reprinted) | `"Error: <msg>"` string by tool convention | raises, kills the loop |
| ruby_llm | `{ error: "..." }` hash sent to model | tool returns whatever; exceptions **bubble up** to host (not caught) | bubbles up to host |
| pi | caught and wrapped as `ToolResultMessage` with `isError: true` | caught and wrapped as text `"Error: <msg>"` | caught and wrapped (same path) |
| opencode | tool catches Effect Schema decode failure and returns "rewrite the input..." text | text observation | caught and converted to `MessageV2.ErrorPart`; loop continues |

Pikuri's split — _recoverable failures become observations, bugs raise_ — is
explicit and well-documented in `lib/tool.rb`. ruby_llm has the same
philosophy. pi and opencode trap everything; the LLM never sees the host
crash.

**Takeaway.** Pikuri's split is defensible. The opencode/pi "trap-everything"
posture is what you want when the agent is long-running and unattended; the
"raise on bugs" posture is what you want during development. Pikuri's choice
is fine for its scope.

---

## Permission / sandboxing

- **pikuri**: nothing. Tools are read-mostly (no shell, no write); the
  question hasn't come up.
- **ruby_llm**: nothing — out of scope for an SDK.
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

**Takeaway.** Today pikuri doesn't need this — read-mostly tools can't do
much harm. The day pikuri gets a `bash` or `write_file` tool, opencode's
shape is the right one to copy.

---

## Sub-agents

- **pikuri** (`Tool.sub_agent`): factory; spawns a fresh `Agent` on a clean
  `ChatLog`, returns the final assistant message. The sub-agent reuses the
  parent's transport, system prompt, and a filtered tool list (parent's
  tools minus `sub_agent` itself, so it can't recurse).
- **ruby_llm**: no built-in sub-agent.
- **pi**: not in core; pushed to extensions.
- **opencode** (`task` tool, `src/tool/task.ts:32–174`):
  - each task creates a **new `Session`** (not just a new ChatLog) — backed
    by SQLite, so sessions are inspectable and resumable
  - takes an optional `task_id` to resume a prior subagent session
  - permissions are derived from the parent and filtered to what the parent
    is allowed to do
  - tool list can be different (unavailable tools passed as `{name: false}`)
  - return wrapped in `<task_result>...</task_result>` tags

**Takeaway.** Pikuri's `sub_agent` is conceptually identical to opencode's
`task` minus the persistence and resumability. Persistence is a fair amount of
machinery for one feature; not worth porting until pikuri has another reason
to introduce a session store.

---

## Ideas to borrow

Sorted by fit-for-pikuri, from "do this now" to "out of scope".

### A-tier — high fit, low cost

1. **Bring all tool descriptions up to the opencode bar.** One-line summary,
   blank line, `Usage:` bullet list with explicit constraints and failure
   modes the LLM can hit. Pikuri's `sub_agent` already does this; `web_scrape`
   and `web_search` don't. Files: `lib/tool/websearch.rb`, `lib/tool/web_scrape.rb`,
   `lib/tool/calculator.rb`. No code change — just descriptions.
2. **Examples in parameter descriptions.** ruby_llm's `Latitude (e.g.,
   52.5200)` pattern is free quality. Pikuri's calculator does this; nothing
   else does. Audit every `p.required_*` / `p.optional_*` call site.
3. **Tool-emitted `:halt` signal** (ruby_llm's `Tool::Halt`). Today only
   `finish_reason == :stop` ends a `run_loop`; tools have no way to short-
   circuit. Cheap to add: let `execute` return a sentinel like
   `Tool::Halt.new("text")`, and have `Agent#run_loop` treat that the same as
   a `:stop` finish reason. Useful for tools like "I found the answer, no
   point continuing."

### B-tier — worth it but more invasive

4. **Method-signature introspection as a Parameters fallback** (ruby_llm).
   When a tool's `execute` Proc has typed kwargs, derive the schema
   automatically. Trade-off: descriptions still need to live somewhere — so
   this saves typing only for the dumbest tools. Keep the explicit builder as
   the primary path.
5. **Tool descriptions in separate `.txt` files** (opencode pattern). Easier
   to iterate on a multi-paragraph description without touching Ruby. Wait
   until any single description gets long enough to be awkward in a heredoc
   — today only `sub_agent` is close to that line.

### C-tier — only when scope changes

6. **Permission system with glob rules** (opencode). Port the three-action
   `allow` / `deny` / `ask` model the day pikuri grows a `shell` or
   `write_file` tool. Until then, no need.
7. **Event-stream loop** (pi). Replace `puts` with typed events
   (`agent_start`, `turn_start`, `tool_execution_start`, …). Worth it the
   day pikuri grows a TUI, JSON-output mode, or wants test hooks. Today the
   inline `puts` is more readable.
8. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to
   SSH/sandbox/cloud. Only relevant once pikuri has shell-style tools.
9. **Multi-provider abstraction** (ruby_llm). If pikuri ever needs to talk to
   a non-OpenAI backend, copy ruby_llm's "canonical tool schema + thin
   per-provider adapter" shape — not opencode's SDK-of-SDKs.

### Out of scope

10. **Effect-based service architecture** (opencode). Massively too heavy for
    a project this size.
11. **LSP integration** (opencode). Pikuri isn't a coding agent.
12. **Steering / follow-up message queues** (pi). Useful for an interactive
    REPL; `bin/pikuri` is one-shot.
13. **Persistent / resumable subagent sessions** (opencode). Requires a
    session store. Not worth it for one feature.

---

## Sources

- ruby_llm: `/tmp/agent-comparison/ruby_llm` — `lib/ruby_llm/chat.rb`,
  `lib/ruby_llm/tool.rb`, `lib/ruby_llm/message.rb`
- pi: `/tmp/agent-comparison/pi` — `packages/agent/src/agent-loop.ts`,
  `packages/agent/src/types.ts`, `packages/coding-agent/src/core/tools/`
- opencode: `/tmp/agent-comparison/opencode` — `packages/opencode/src/session/processor.ts`,
  `packages/opencode/src/tool/`, `packages/opencode/src/permission/index.ts`,
  `packages/opencode/src/provider/provider.ts`
