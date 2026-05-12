# COMPARISON.md

A side-by-side look at how three OSS agent-or-agent-adjacent projects solve the
same problems pikuri solves, and a ranked list of ideas worth porting.
*Pikuri-on-ruby_llm state* — the pikuri rows describe the codebase as it is
post-ruby_llm migration; ruby_llm itself is now infrastructure under us, not
a peer to compare against.

## Projects in this comparison

| Project | Language | Scope | Loop size | Key abstraction |
| --- | --- | --- | --- | --- |
| **pikuri** (this repo) | Ruby on top of ruby_llm | small general-purpose CLI agent | listeners on top of `RubyLLM::Chat#complete` | `Tool` factory (synthetic `RubyLLM::Tool` subclass) + `Tool::Parameters` strict validator |
| **ruby_llm** ([crmne/ruby_llm](https://github.com/crmne/ruby_llm)) | Ruby | multi-provider SDK + Rails integration | ~37 lines across `Chat#complete` + `Chat#handle_tool_calls` | `RubyLLM::Tool` subclass + provider adapters |
| **pi** ([earendil-works/pi](https://github.com/earendil-works/pi)) | TypeScript | extensible coding-agent harness | ~700 lines (`agent-loop.ts`) | Typebox-typed tools + extensions/skills |
| **opencode** ([sst/opencode](https://github.com/sst/opencode)) | TypeScript | full terminal coding agent (Claude-Code-shaped) | effect-based, split across `processor.ts`/`session.ts` | Effect services + `.txt` prompt files |

The four are at very different scopes:

- **ruby_llm** is now pikuri's runtime, not a peer. It still appears in the
  comparison because some design choices (tool DSL, message shape, error-
  return convention) live in ruby_llm now and pikuri inherits them.
- **pi** is a coding-agent harness: same shape as a Claude-Code-style CLI but
  designed as a thin core with everything (sub-agents, plan mode, MCP, perms)
  pushed to extensions.
- **opencode** is much bigger than pikuri — closer to Claude Code itself. The
  value here is mining ideas, not comparing line counts.

Pikuri sits between ruby_llm (the SDK we delegate transport+loop to) and
pi/opencode (full agents): a small *general-purpose* assistant whose entire
job is the *extension surface* on top of ruby_llm — strict validation,
listener-based rendering, sub-agents, and a fixed deliberate set of tools.

---

## Agent loop

| | Loop shape | Streaming | Termination | Step budget |
| --- | --- | --- | --- | --- |
| pikuri | listeners (`after_message`, `before_tool_call`, `after_tool_result`) attached to a `RubyLLM::Chat`; `run_loop` is `chat.ask(message)` (`lib/agent.rb`) | available via ruby_llm but not exposed today | inherits ruby_llm's: LLM emits no tool calls (or `Tool::Halt`); pikuri's `before_tool_call` listener also raises past `max_steps` | yes (`max_steps`, counted in the listener) |
| ruby_llm | recursive: `Chat#complete` calls itself after running tool calls (`lib/ruby_llm/chat.rb:156–293`) | yes, optional via block | LLM returns no tool calls, OR `Tool::Halt` short-circuits | no — bounded only by `Halt` |
| pi | nested loops: outer for follow-up queue, inner for steering+tools (`packages/agent/src/agent-loop.ts:155–269`) | yes — `EventStream<AgentEvent>` | `shouldStopAfterTurn()` hook, `stopReason`, abort | implicit via context-window compaction |
| opencode | one-shot processor returning `"compact" \| "stop" \| "continue"` per turn (`src/session/processor.ts:115–425`) | yes — Vercel AI SDK chunk events | model emits no tool calls → `"stop"` | no — context overflow → `"compact"` |

**Takeaway.** Pikuri now has events for free (ruby_llm's listener API);
the question is whether to surface them. Today the rendering listeners
just `puts`, which keeps `run_loop` legible at a glance. The day pikuri
wants a TUI / JSON output / test hooks, the listener set is already where
the wiring happens — just emit a structured event instead of (or in
addition to) printing.

---

## Provider / transport abstraction

- **pikuri**: delegates to ruby_llm. `bin/pikuri-chat` configures the OpenAI
  provider for the local llama.cpp server (`openai_api_base` +
  `assume_model_exists: true`); switching to Anthropic / Gemini /
  Bedrock / Ollama / etc. is a one-block edit in `RubyLLM.configure` —
  no pikuri-side code change.
- **ruby_llm**: provider-per-class (`lib/ruby_llm/providers/{openai,anthropic,gemini,bedrock,ollama,...}/`).
  Tool schema stays canonical; per-provider adapters wrap it.
- **pi**: own multi-provider layer in `@earendil-works/pi-ai` covering OpenAI,
  Anthropic, Google, Bedrock, etc.
- **opencode**: built on Vercel AI SDK. Adding a provider is one entry in
  `BUNDLED_PROVIDERS` (`src/provider/provider.ts:93–118`).

**Takeaway.** Pikuri inherits ruby_llm's "canonical schema + thin
per-provider adapter" shape — chosen over opencode's SDK-of-SDKs
approach because we already wrote tools against the OpenAI tool-call
shape and ruby_llm preserves that as the canonical form. Today bin/pikuri-chat
is hard-coded for the local llama.cpp setup; multi-provider wiring would
be a small `bin/`-level change rather than a library-level rewrite.

---

## Tool abstraction

| | Definition style | Schema | Validation strictness |
| --- | --- | --- | --- |
| pikuri | `Tool.new(...)` factory returns a synthetic `RubyLLM::Tool` subclass; `Tool::Parameters` builder lives on top of ruby_llm's tool layer | fluent `Tool::Parameters` builder → JSON Schema, fed to ruby_llm's `params(hash)` | strict: unknown keys rejected with DidYouMean, type coercion, all errors collected. The keyrest signature on `execute(**args)` makes ruby_llm's keyword-presence checker no-op so pikuri's validator runs first |
| ruby_llm | subclass `RubyLLM::Tool`, class-level DSL | three options: `params { ... }` block, `param :name` declarative, OR auto-inferred from `execute` keyword args | strict but **no DidYouMean** |
| pi | `AgentTool<TParameters>` interface, factory functions | Typebox `Type.Object()` (compile-time + runtime) | Typebox-strict; optional `prepareArguments()` shim for LLM quirks |
| opencode | Effect Schema decoders (Zod-shaped) + `.txt` description files | Effect `Schema.decodeUnknownEffect()` | strict; failure produces "rewrite the input so it satisfies..." message |

**Takeaway.** Pikuri's strict-with-DidYouMean validator is the single most
load-bearing piece of code we *kept* through the migration — it's why the
factory exists. Ruby_llm's tool runtime would otherwise produce a thinner
"missing keyword: x" message; the factory layers DidYouMean / coercion /
all-errors-collected on top. Method-signature introspection (ruby_llm's
auto-infer-from-`execute`) remains an option pikuri could borrow for
trivial tools — but the explicit `Parameters` builder keeps descriptions
next to the schema, which is hard to give up entirely.

---

## Available tools

| | calc | shell/bash | read | write | edit | grep | glob | search | scrape/fetch | sub-agent | todo/plan | LSP |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| pikuri | ✅ | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ glob | ✅ web_search | ✅ web_scrape + fetch | ✅ | — | — |
| ruby_llm | — (SDK only — no bundled tools) | | | | | | | | | | | |
| pi | — | ✅ bash | ✅ read | ✅ write | ✅ edit | ✅ grep | ✅ find | — | — | — (extension) | — (extension) | — |
| opencode | — | ✅ shell | ✅ read | ✅ write | ✅ edit + patch | ✅ grep | ✅ glob | ✅ search (Exa) | ✅ fetch | ✅ task | ✅ todo + plan | ✅ |

ruby_llm ships **no tools at all** — it's an SDK; the developer subclasses
`RubyLLM::Tool` and wires their own. pi ships only file/shell ops; web search,
sub-agents, etc. are pushed to extensions. opencode is the most batteries-
included.

The pikuri row reflects the union of both bundled binaries:
`bin/pikuri-chat` wires calc + web_search + web_scrape + fetch +
sub_agent; `bin/pikuri-code` wires the file/shell stack (read, write,
edit, grep, glob, bash) plus the same web/calc/sub_agent set as
auxiliaries. Two binaries on a shared `Agent` + `Tool` core.

**Takeaway.** Pikuri now covers both the *general-purpose* and the
*coding* tool surfaces from one codebase. The remaining gaps versus
opencode are todo/plan tools and LSP — both deliberately deferred (see
`PLAN_CODING.md` "Out of scope for v1").

---

## Tool description quality

This is the section most worth reading. The LLM only gets to see the
`description` and per-parameter strings; their quality directly affects how
often the model picks the right tool with the right arguments.

### pikuri (verbatim — post-cleanup)

All five tools follow a single heredoc shape: one-line summary, blank
line, `Usage:` bullet list. Showing `web_scrape` as the exemplar — this
tool had the biggest jump, its old description was a single line:

```
Scrapes the rendered webpage, PDF, or text file at the given URL and returns its main content as Markdown.

Usage:
- Use for HTML pages or PDFs where you want readable content — readability extraction strips nav, sidebars, and boilerplate.
- For raw textual payloads (JSON, CSV, robots.txt, source files), use fetch instead — it returns bytes verbatim, while web_scrape would corrupt them with a Markdown pass.
```

Two cross-cutting decisions fell out of the pass:

- **Universal `Error: ...` recovery lives in
  `prompts/pikuri-chat.txt`** as one rule, not per-tool. The same
  guidance (use what you have, or tell the user; do not retry the same
  call) covers search rate-limits, scrape 404s, fetch refusals, and
  calculator parse errors — writing it once avoids per-tool drift.
- **Per-argument constraints stay in the parameter description**, never
  duplicated in the tool description. String parameters use inline
  `e.g. "..."` examples in the ruby_llm pattern below; integer
  parameters (`max_results`, `max_chars`) state default and cap as the
  anchoring equivalent.

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
constraints_ — is the gold standard, and pikuri now applies it uniformly
across all five tools. The one place pikuri diverges: opencode bakes
failure-mode hints inline ("If the path does not exist, an error is
returned"), pikuri factors them into a single universal rule in the
system prompt. Cheaper to maintain, loses some tool-specific specificity.

---

## Conversation / message types

- **pikuri**: inherits ruby_llm's. `RubyLLM::Chat#messages` is the
  history; `RubyLLM::Message` is the entry; `Agent#last_assistant_content`
  walks the messages list to grab the sub-agent's final reply. The old
  hand-rolled `ChatLog::Message` (with a `Data.define` strict-role
  constructor) was deleted with the migration — ruby_llm's role
  validation in `Message.new` covers the same ground.
- **ruby_llm**: plain Array of `Message` objects (no log wrapper). Roles
  validated per-instance against a frozen list. Same four roles plus
  `tool_call_id`, `tokens`, `model_id`, `thinking`, `raw`.
- **pi**: TypeScript discriminated union; custom message types extensible via
  declaration merging. Coder-supplied `convertToLlm()` filters them before the
  LLM call.
- **opencode**: `MessageV2` with `ErrorPart` / `ToolPart` / `TextPart` etc.;
  parts are typed and persisted in SQLite per session.

**Takeaway.** No change needed in pikuri — ruby_llm's message types are
strictly richer than what we had (token bookkeeping, thinking, raw
provider payload). pi's discriminated union and opencode's `MessageV2`
are the right shapes to envy *if* pikuri ever wants to persist
sessions, attach error parts, or carry custom fields through the
pipeline. Today: not warranted.

---

## Error handling

| | Tool argv malformed | Tool execute failure (recoverable) | Tool execute failure (bug) |
| --- | --- | --- | --- |
| pikuri | `"Error: <msg>"` string fed back to model (with full schema reprinted by `Tool::Parameters`) — pikuri's validator runs *before* ruby_llm's would | `"Error: <msg>"` string by tool convention; ruby_llm passes it through verbatim to the next observation | raises through ruby_llm; kills the loop |
| ruby_llm | `{ error: "..." }` hash sent to model | tool returns whatever; exceptions **bubble up** to host (not caught) | bubbles up to host |
| pi | caught and wrapped as `ToolResultMessage` with `isError: true` | caught and wrapped as text `"Error: <msg>"` | caught and wrapped (same path) |
| opencode | tool catches Effect Schema decode failure and returns "rewrite the input..." text | text observation | caught and converted to `MessageV2.ErrorPart`; loop continues |

Pikuri's split — _recoverable failures become observations, bugs raise_ — is
explicit and well-documented in `lib/tool.rb`. ruby_llm shares the
philosophy; pikuri's String convention is what flows through to the model
(ruby_llm's `Chat#handle_tool_calls` calls `.to_s` on whatever the tool
returns and writes it as the tool message's content). pi and opencode trap
everything; the LLM never sees the host crash.

**Takeaway.** Pikuri's split survives unchanged from the migration —
ruby_llm passes it through. The opencode/pi "trap-everything" posture is
what you want when the agent is long-running and unattended; the "raise
on bugs" posture is what you want during development. Pikuri's choice is
fine for its scope.

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

- **pikuri** (`Tool::SubAgent < Tool`, constructed by `Agent#allow_sub_agent`):
  each invocation spawns a fresh `Agent` and therefore a fresh
  `RubyLLM::Chat` (its own `messages`/`tools`/listeners), runs the
  requested task, and returns only the sub-agent's final assistant
  message. The sub-agent reuses the parent's model, system prompt, and
  a filtered tool list (parent's tools minus `sub_agent` itself, so it
  can't recurse). Isolation is verified at the ruby_llm level —
  `RubyLLM::Chat` initializes every state-bearing field per-instance.
- **ruby_llm**: no built-in sub-agent.
- **pi**: not in core; pushed to extensions.
- **opencode** (`task` tool, `src/tool/task.ts:32–174`):
  - each task creates a **new `Session`** (not just a new chat history) —
    backed by SQLite, so sessions are inspectable and resumable
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

Sorted by fit-for-pikuri, from "do this now" to "out of scope". Items
marked **DONE** landed during the ruby_llm migration; items marked
**FREE NOW** require nothing more than wiring through ruby_llm's
existing primitive.

### A-tier — high fit, low cost

1. **Bring all tool descriptions up to the opencode bar** — **DONE**.
   All five tools (calculator, web_search, web_scrape, fetch, sub_agent)
   now use the heredoc summary + `Usage:` bullets shape. The pikuri
   variant of the pattern factors universal `Error: ...` recovery into
   the system prompt rather than restating it per-tool. Convention
   documented in `CLAUDE.md`. The pass also bumped `web_scrape`'s
   default `max_chars` from 5K → 20K so the LLM doesn't double-request
   the same prefix on common-length articles.
2. **Examples in parameter descriptions** — **DONE**. Every string
   parameter now carries an inline `e.g. "..."` example in the ruby_llm
   pattern. Integer parameters (`max_results`, `max_chars`) describe
   their default and cap, which serves as the anchoring equivalent.
   Codified in `CLAUDE.md`.
3. **Tool-emitted `:halt` signal** — **FREE NOW**. ruby_llm's
   `RubyLLM::Tool::Halt` lets a tool short-circuit: returning
   `halt("done")` from `execute` ends the chat without a follow-up
   model call. Pikuri's synthetic-tool factory already passes any
   return value through verbatim, so the only thing missing is a
   `Tool::Halt` helper or convention in pikuri's API and a doc note in
   `lib/tool.rb`. Cheap.

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
7. **Structured event stream** — **FREE NOW** (foundation). pi and
   opencode emit typed events; pikuri's `Agent#install_listeners`
   already taps `before_message`/`after_message`/`before_tool_call`/
   `after_tool_result`, but the listeners just `puts`. Day pikuri
   wants a TUI / JSON output / test hooks, replace the puts with
   structured event emission and the wiring is already in place.
8. **Pluggable Operations interfaces** (pi). Lets a `bash` tool delegate to
   SSH/sandbox/cloud. Only relevant once pikuri has shell-style tools.
9. **Multi-provider abstraction** — **DONE** via the ruby_llm
   migration. Switching pikuri from llama.cpp/OpenAI-shape to
   Anthropic / Gemini / Bedrock / Ollama / etc. is a one-block edit
   in `bin/pikuri-chat`'s `RubyLLM.configure`. No library code change.

### Out of scope

10. **Effect-based service architecture** (opencode). Massively too heavy for
    a project this size.
11. **LSP integration** (opencode). Pikuri isn't a coding agent.
12. **Steering / follow-up message queues** (pi). Useful for an interactive
    REPL; `bin/pikuri-chat` is one-shot.
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
