# Tool summary lines: the tool composes its own one-line display form

Status: **brainstorm — nothing built, hold the implementation.**
Implementability checked 2026-09-07 against ruby_llm 1.16 and every shipped
tool (see *Survey* and *Verified against ruby_llm*): feasible without a
ruby_llm patch; the first-required default covers 25 of 34 tools and the
other 9 need a per-tool override, which is why `describe_call` is a method
on `Tool`. Settled the same day: the nine overrides, `LSP` as the one
display-name override, MCP names as `Server::Tool`. Requested
by pikuri-tui (its `ideas/hide-thinking-and-tool-calls.md`, Part 2), which
wants its transcript to show `Write(lib/foo.rb)` / `Returned 23 search
results` instead of the argument dump and the 200-char result excerpt — and
found that the summary can only be composed *here*, by the tool, at the
moment it still holds the structured data it is about to flatten for the
model.

Related:

- `pikuri-core/lib/pikuri/tool.rb` — `Tool#execute` returns "the
  observation — usually a `String`, or a `RubyLLM::Content`". The vocabulary
  this note has to fit into.
- `pikuri-core/lib/pikuri/agent/event.rb` — `Event::ToolCall(name:,
  arguments:)` / `Event::ToolResult(content:)`; the result event does not
  name its tool.
- `pikuri-core/lib/pikuri/agent/listener/terminal.rb`,
  `pikuri-web/lib/pikuri_web/sse_listener.rb`,
  pikuri-tui's `Shared::ConversationTextView::Listener` — the three renderers
  that all print `→ name(k=v)` / `= <excerpt>` today, each with its own copy.
- `pikuri-core/lib/pikuri/sanitizer.rb` — the display-safety primitive the
  short form must route through (the current line is safe only because it
  goes through `inspect`; see §Safety).
- `agent.rb` ~L945 — the note that call→result pairing by strict ordering
  holds "only while `tool_concurrency` stays off". The summary work is a
  natural moment to stop relying on it.

## The target look

```
  Write(lib/shared/config.rb)
    Added 2 lines, removed 3 lines
  WebSearch(rails 8 credentials)
    Returned 23 search results
  Skill(ideas-folder)
    Loaded 3.1 kB
  Bash(bundle exec rake check)
    exit 0, 41 lines
  Read(lib/code/app.rb)
    Read 214 lines
```

Three parts per call, each a plain `String` a renderer styles but never
composes:

1. **display name** — `snake_case` tool name → `CamelCase` (`web_search` →
   `WebSearch`, `mcp_connect` → `McpConnect`). Leading upper-case on purpose:
   it reads as a *thing that ran*, not as prose.
2. **primary argument** — the one argument worth a glance: `path` for
   read/write/edit, `query` for web_search, `command` for bash, `name` for
   skill. One line, capped.
3. **result summary** — one short line, *structural*: counts, sizes, exit
   codes, never an excerpt. An `Error: …` observation shows its message
   instead (that *is* what the user needs).

## Who composes the summary

`O_llm_narrates` — ask the model to say what it did. **Rejected, and this is
what makes the feature worth doing carefully.** The model is the one
component an attacker can steer through a fetched page, a file, an email. A
narrated `Saved successfully` on a failed write is exactly what an injection
would aim for. Nothing a human reads as *status* may originate in the model.

`O_renderer_parses` — each renderer keeps a per-tool table that reconstructs
the summary from `Event::ToolResult#content`. pikuri-tui already has this
seam (`tool_formatters`, keyed by tool name, used for the `edit`/`write`
diffs). Rejected as the general answer: the summary is derived from
structured data the tool held and the renderer never sees — `web_search` had
23 result structs before it flattened them to a Markdown list, `read` had a
line count, `bash` had an exit status. Re-parsing the flattened `String` is
fragile and breaks the day the Markdown shape changes; and three renderers
would carry three drifting copies.

`O_tool_declares` — **the lean.** The tool composes the summary where the
data is; pikuri sends `content` to the model and `summary` to the listeners;
every renderer prints the same string. Two mechanisms below; they are not
exclusive.

## Mechanism for the result summary

### `O_tool_result` — a rich return value (proposed name; the user's lean)

`Tool#execute` may return, besides a `String` or `RubyLLM::Content`, a small
value object carrying both halves:

```ruby
Pikuri::Tool::Result = Data.define(:content, :summary) do
  def to_s = content.to_s          # what ruby_llm stores as the tool message
end

execute: lambda { |query:, max_results: 10, context:|
  hits = cascade.search(query, max_results:, cancellable: context.cancellable)
  Pikuri::Tool::Result.new(content: render_markdown(hits),
                           summary: "Returned #{hits.size} search results")
}
```

The plumbing is almost free, and that is the strongest argument for it.
ruby_llm 1.16's `Chat#add_tool_result_message` stores
`content_like?(payload) ? payload : payload.to_s`, and its
`after_tool_result` callback receives the *raw* return object before that
`to_s` — so a `Result` whose `to_s` is its content flows to the model
unchanged with **no ruby_llm patch**, and pikuri's existing
`@chat.after_tool_result do |result|` reads `result.summary` off the object
and puts it on the event. ruby_llm's own `Tool::Halt` (a wrapper whose
`.content` ruby_llm unwraps) is precedent for a rich return.

Naming — **decided 2026-09-07: `Pikuri::Tool::Result`**, in the house
nesting (`Tool::Parameters`, `Tool::ExecuteContext`, `Tool::TrifectaLegs`).
Rejected `Tool::Observation`: although it is the word `Tool#execute`'s rdoc
uses, "observation" reads as something the call keeps producing, where
"result" is finite — the call is over. The cost accepted: two things called
"tool result", `Tool::Result` (what `execute` returns) and
`Agent::Event::ToolResult` (what listeners see). They are the same thing at
two stages and the event carries the return's fields; rdoc and specs say
which they mean.

Content — **decided 2026-09-07: a `Result` holds a `String` only** (option
(a) below). A tool returning `RubyLLM::Content` (the PNG a `read` returns)
keeps returning it bare and gets the generic default summary; multimodal
observations are rare and `Returned image/png, 40 kB` is fine. The
governing rule: **touch no ruby_llm internal** — no `content_like?` patch,
no unwrap-and-stash in the wrapper. The only ruby_llm behaviour relied on
is the public one `Tool::Halt` also rides: a non-`Content` payload is
stored via `to_s`. If a richer return is ever needed, `Result` grows a
field (say `attachments:`) and pikuri's own wrapper unwraps it — never a
patch. The roads not taken, for the DECISIONS entry:

- (b) pikuri's `to_ruby_llm_tool` wrapper unwraps the `Result` *before*
  ruby_llm sees it, returning `.content` and stashing `.summary` in a
  per-call slot the `after_tool_result` callback reads. Works for `Content`
  too, but the stash is a second single-slot pairing trick and it breaks the
  moment `tool_concurrency` goes on.
- (c) extend `content_like?` via `ruby_llm_patches.rb`. Smallest code,
  another monkey-patch to carry across ruby_llm bumps.

### `O_describe_hook` — an overridable method on the `Tool`

```ruby
class Bash < Pikuri::Tool
  def describe_result(content) = "exit #{content[/^exit (\d+)/, 1]}, #{content.lines.size} lines"
end
```

Purely additive, no return-type change, no `Content` question. But the hook
sees only the flattened `content`, so it is `O_renderer_parses` moved one
layer down: less duplication, same fragility. Still the right tool for two
jobs: (1) a tool whose summary genuinely *is* a function of the content
(`calculator`: the value); (2) the **call side**, where there is nothing to
return yet — `describe_call(arguments)` for a tool whose primary argument is
not its first required parameter (see the survey below for the nine that
need it).

A *method*, not a `describe_call:` kwarg lambda: 33 of the 34 shipped tools
are already `Pikuri::Tool` subclasses, `for_sub_agent` / `with_workspace`
are the precedent for per-subclass methods, and two of the overrides need
the tool's own state (`task_*` looks a title up in its `list:`).

**Lean: both.** `Tool::Result` (or `Observation`) for result summaries that
need structure, `describe_call` overridden on the call side, and the
defaults in `Tool` covering everything that declares neither.

### Verified against ruby_llm 1.16 (2026-09-07)

- `Chat#execute_tool_with_callbacks` runs `after_tool_result` with the
  **raw** return object; `add_tool_result_message` `to_s`es it afterwards
  (`chat.rb` L374–387). The rich return needs no patch. `Tool::Halt` has the
  identical shape (`attr_reader :content`; `to_s = content.to_s`).
- `content_like?` is `is_a?(Content) || is_a?(Content::Raw)`, so option (a)
  under `Q_content_wrapping` stands: a `Result` may wrap a `String` only.
- **`after_tool_result` receives the result alone — no `tool_call`.** So
  putting `name:` / `tool_call_id:` on `Event::ToolResult` needs a pairing
  mechanism after all. Two: (i) `before_tool_call` stashes the call and
  `after_tool_result` reads it — the same single-slot trick, valid under the
  `tool_concurrency: off` contract `Tool`'s `== Sharing` already imposes;
  (ii) set `instrumenter` on pikuri's per-chat `RubyLLM::Context` config —
  ruby_llm wraps every tool run in
  `instrument('tool_call.ruby_llm', payload)` whose payload carries
  `tool_call`, `tool` and `result` together, so ruby_llm does the pairing
  and it survives concurrency; but the instrumenter sees *every* ruby_llm
  event (completions, HTTP) and must pass them through. Lean **(i)**,
  documented at the stash; (ii) is the reopen path if concurrency ever goes
  on. Either way the event gets `name:` — the assumption moves from three
  renderers into one place in `Agent`.
- An unavailable tool makes `execute_tool` return a **`Hash`**
  (`{error: "Model tried to call unavailable tool …"}`), which reaches
  `after_tool_result` as-is. The default summary must handle a `Hash` with
  `:error` (pass the message through), not only `String` / `Content`.
- `Tool#run` already turns a validation failure into an `"Error: …"`
  `String` before `execute` runs, so a tool's `describe_result` never sees
  its own validation error; the default `Error:` pass-through covers it.

## The call side: display name + primary argument

Computable from what `Tool` already knows, so no per-tool work in the common
case:

- `Tool.display_name_for(name)` — a module-level function, CamelCase of a
  raw tool name, and `Tool#display_name`, an **overridable method**
  defaulting to it. The function is what the agent falls back to when it has
  no `Tool` in hand (an MCP tool, which bypasses `Pikuri::Tool`; ruby_llm's
  unavailable-tool error; pikuri-web's `HistoryReplay`), so every naming
  rule lives in the function, never on an instance:
  - split on `__` first — that is `Mcp::Servers`' server separator — and
    join the CamelCased halves with `::`: `openlibrary__search_books` →
    `Openlibrary::SearchBooks`. Decided 2026-09-07: the boundary is worth
    keeping and `::` reads natively to the Ruby-dev audience;
  - within a segment, any non-alphanumeric run is a word break (MCP names
    may carry `-` / `.`; ruby_llm sanitizes to `_`).

  The one override: `LspTool#display_name` returns `LSP` (decided
  2026-09-07 — `Lsp` reads as a word, `LSP` as the acronym it is). It rides
  the same per-subclass-method mechanism as `describe_call`, so it costs a
  line; a replayed or unavailable `lsp` still renders `Lsp`, which is
  acceptable. `VectordbSearch` / `FileindexRead` / `RagSearch` stay as the
  function produces them.
- `Tool#describe_call(arguments)` — a **method on `Tool`**, default
  implementation = the value of the **first required parameter**.
  `Parameters` keeps declaration order (`@properties` is an insertion-ordered
  Hash) and a `@required` list, so this needs only a reader on `Parameters`
  (`#required` is private today). A tool with no required parameter renders
  the *supplied* arguments as `k=v` (capped); a no-arg tool renders bare
  (`EnterPlanMode`). A tool that wants something else **overrides the
  method** — the survey below is why it is a method and not a
  `describe_call:` kwarg.

### Survey: the first-required rule against every shipped tool (2026-09-07)

34 shipped tools (`grep -rn "name: '" pikuri-*/lib`, minus personas and LSP
operations). 33 are `Pikuri::Tool` *subclasses* calling `super(name: …)`;
the lone `Tool.new` is `WebSearch.build`, which needs no override. So an
overridable method reaches every tool that needs one, and `for_sub_agent` /
`with_workspace` are already the precedent for per-subclass methods on a
tool.

**Works as-is (25):** `bash` (command), `git_clone` (url), `mcp_connect`
(id), `recall` (topic), `fileindex_read` (path), `fileindex_search` /
`rag_search` / `vectordb_search` / `thunderbird_contact_search` (query),
`rag_find` (terms), `skill` (name), `thunderbird_calendar_create` (title),
`thunderbird_calendar_read` (event_id) and `thunderbird_mail_read`
(message_id) — opaque ids, but nothing better exists before execution;
`thunderbird_mail_compose` (to), `calculator` (expression), `fetch` /
`web_scrape` (url), `web_search` (query), `vectordb_read` (source), `read` /
`write` / `edit` (path), `glob` / `grep` (pattern), `enter_plan_mode` /
`vectordb_reindex` (no params).

**Needs an override (9)** — a quarter of the fleet, so the override ships
in the same release as the default, not later:

| tool | first required | problem | override |
|---|---|---|---|
| `exit_plan_mode` | `plan` | the whole Markdown plan | render bare `ExitPlanMode` (the plan is shown by the confirmer) |
| `lsp` | `operation` (enum) | `Lsp(references)` says nothing | `"#{operation} #{symbol}"` — two args |
| `agent` | `name` (enum) | `Agent(researcher)` is thin | `"#{name}: #{task}"`, task capped |
| `task_completed` / `task_in_progress` / `task_delete` | `id` (integer) | `TaskCompleted(3)` | look the title up in the `list:` the tool holds — **needs tool state**, which a kwarg lambda could only reach by closing over it |
| `task_create` | `items` (array) | an `Array#to_s` dump | `"#{items.size} items"` or the first item |
| `thunderbird_mail_search` / `thunderbird_calendar_search` | *none* — every parameter optional | the note's "first optional" is `query`, which the model may not have passed | the no-required default: supplied args as `k=v` (`from=bob after=2026-09`) |
| `file_list` | *none* | `FileList()` when `path` is omitted | the tool knows its default is the root: render `.` |

Nice-to-have, not needed: `read` with `offset`/`limit` as `path:100-200`;
`glob` / `grep` appending ` in <path>` when supplied.

**CamelCase warts**, for the record: `vectordb_search` → `VectordbSearch`,
`fileindex_read` → `FileindexRead`, `rag_search` → `RagSearch` — accepted;
deterministic beats pretty (this is the Zeitwerk-inflector problem again).
`lsp` → `Lsp` was the one wart judged worth the override (`LSP`), and the
MCP `__` separator the one worth a rule (`::`); both decided above.

## Event changes

`Event::ToolCall(name:, arguments:)` gains the two precomputed strings —
`display_name:` and `argument:` — and `Event::ToolResult(content:)` gains
`summary:`. Both are emitted from `Agent`, which has the tool by name, so the
agent computes once and renderers only style. `Q_event_shape`: strings on
the event versus a `tool:` reference the renderer queries. Lean **strings**:
events stay plain serializable `Data` (pikuri-web ships them over SSE;
`HistoryReplay` synthesizes them), and the *unavailable tool* case (ruby_llm's
"Model tried to call unavailable tool" error) has no `Tool` to reference —
the agent falls back to CamelCasing the raw name.

**Decided 2026-09-07: both `ToolCall` and `ToolResult` carry `name:` and
`tool_call_id:`.** Today every renderer pairs a result with its call by
strict call→result ordering — the single-slot trick pikuri-tui's
`@pending_formatter` and `agent.rb` L945 both document as holding only while
`tool_concurrency` is off. With the id on both events a renderer pairs by
key and the ordering assumption leaves the renderers; inside `Agent` it
survives only at the one stash that pairs ruby_llm's call-less
`after_tool_result` with its `before_tool_call` (see *Verified against
ruby_llm*). `tc.id` is available in `before_tool_call`; the stash supplies
it to the result event. The second emit site — the dangling-call repair in
`Agent` (~L976, `INTERRUPTED_RESULT`) — has the call in hand and gets a
fixed summary (`Interrupted`).

`History` does not store summaries (`Q_persist_summary`). A reloaded
conversation's `ToolResult`s are synthesized from `tool` messages and would
carry the generic default. Lean: **don't persist** for v1; the loss is one
line of nicety on old conversations, and adding a field to the message
schema is a migration.

Third emit site: pikuri-web's `HistoryReplay` builds `ToolCall` /
`ToolResult` from a saved `History` with no `Tool` in hand. The new fields
therefore need `Data.define` defaults (a keyword-defaulting `initialize`),
and a replayed line shows the CamelCased name plus the generic defaults —
or the replay is handed the agent's toolset so it can call `describe_call`.
Same fallback the *unavailable tool* case uses, so it costs nothing extra.

## Defaults for tools that declare nothing

Every MCP tool and every third-party `Pikuri::Tool` gets a tolerable line for
free:

| part | default |
|---|---|
| display name | CamelCase(`name`); an MCP `server__tool` renders `Server::Tool` |
| argument | first required parameter's value, one line, capped; no required parameter → supplied args as `k=v`; no parameters → bare name |
| result summary | `Returned N bytes` (`N lines` when multi-line); `Returned <mime>, N kB` for a `RubyLLM::Content`; an `Error: …` content passes through as its first line; ruby_llm's unavailable-tool `Hash` passes its `:error` through |

## Shipped tools — first cut of summaries

One line each; the point is to check the *shape* is expressible for every
tool we ship, not to fix wording.

| tool | argument | summary |
|---|---|---|
| `read` | path | `Read 214 lines` / `Returned image/png, 40 kB` |
| `write` | path | `Wrote 88 lines` (new) / `Added 2 lines, removed 3 lines` |
| `edit` | path | `Added 2 lines, removed 3 lines` |
| `glob` | pattern | `Matched 12 files` |
| `grep` | pattern | `Matched 7 lines in 3 files` |
| `bash` | command | `exit 0, 41 lines` |
| `file_list` | path | `Listed 31 entries` |
| `web_search` | query | `Returned 23 search results` |
| `web_scrape` / `fetch` | url | `Fetched 41 kB (text/html)` |
| `calculator` | expression | the value — computed by code, so it *is* structural |
| `skill` | name | `Loaded 3.1 kB` |
| `agent` | agent name (not the task) | `Answered, 1.2 kB` |
| `task_*` | title (looked up from the `id` the model passes) | `3 tasks, 1 done` |
| `mcp_connect` | server id | `Connected, 14 tools` |
| `rag_search` / `vectordb_search` / `recall` | query | `Found 8 hits` |
| `thunderbird_mail_search` | query | `Found 8 messages` |
| `thunderbird_mail_compose` / `calendar_create` | recipient / title | `Handed to Thunderbird` |
| `enter_plan_mode` / `exit_plan_mode` | — | `Plan mode on` / `off` |
| `git_clone` | url | `Cloned, 412 files` |
| `lsp` | operation + symbol (`references Foo`) | `N results` |

Note `edit` / `write` **do** return a summary rather than `nil`: the
Terminal listener has no diff view, so the count is its whole result line. A
renderer that shows a diff block (pikuri-tui's formatters, pikuri-web) drops
the summary under it as redundant — suppression is the renderer's call, not
the tool's.

## Safety

- **Structural, never excerpted.** A summary echoes counts, sizes, statuses.
  The first line of a fetched page or a file is attacker-authorable text,
  and printing it where the user reads *status* reopens the hole
  `O_llm_narrates` closed.
- **The argument is model-chosen, and showing it is the point.**
  `Write(/tmp/evil)` is what the model decided to do; the confirmer already
  shows the same argument for approval.
- **Sanitize at the renderer.** The current `→ name(k=v)` line passes every
  value through `inspect`, which escapes control bytes — the only reason a
  filename carrying `ESC[` or a CR has never recolored or overwritten a
  transcript line. The short form drops `inspect` and must route
  `display_name` / `argument` / `summary` through `Pikuri::Sanitizer` instead
  (`Listener::Terminal` already uses it for other lines; pikuri-web adds
  `html_escape` on top; pikuri-tui parses ANSI via `StyledString.parse`, so it
  is the most exposed of the three).
- **Cap the argument — the renderer's job** (decided 2026-09-07). A
  `command` can be a 4 kB script and a `content` a whole file; the event
  carries the full one-line string and each renderer truncates to its own
  width with `…`, since only it knows that width. The full text is in the
  confirmer block when confirm is on.
- **Summaries are code.** A `describe_*` hook or a `Result` is authored by
  the tool's programmer, never assembled from model output. A tool that
  wanted to put an LLM-written sentence in `summary:` would be violating
  this note; say so in the `Result` rdoc.

## Renderers to update (all three, same release)

- `Listener::Terminal` — the demos get the short form too; this is not a
  tui-only feature.
- pikuri-web `SseListener` — `:tool_call` / `:tool_result` blocks; drop the
  summary under a diff block.
- pikuri-tui `Shared::ConversationTextView::Listener` — replaces
  `render_tool_call` / `render_tool_result`; the `edit`/`write` formatters
  stay for the diff, and stop being the place a short form is composed.

## Open questions

Settled 2026-09-07 (recorded in place above): `Tool::Result` over
`Observation`; `String`-only `Result`, no ruby_llm internals touched; both
events carry `name:` + `tool_call_id:`; the argument cap is the renderer's.
Still open:

- `Q_event_shape` — precomputed strings on the events vs a `tool:` reference.
  Lean strings.
- `Q_persist_summary` — store `summary` on the `tool` history message? Lean
  no for v1.

## When this is done

Delete this note. Graduation homes (per `CLAUDE.md`):

- **DECISIONS.md** — a "tool summary by tool" entry: the tool composes its summary
  in code, never the model (prompt injection) and never the renderer
  (structure is gone after flattening); rejected `O_llm_narrates` and
  `O_renderer_parses`; the `Result`-vs-`Observation` naming call and the
  `Content` decision as consequences.
- **yardoc** — `Tool::Result` (or `Observation`) rdoc carrying the
  structural-never-excerpted rule and the "summaries are code" rule;
  `Tool.display_name_for` (the `__` → `::` rule) / `Tool#display_name` /
  `Tool#describe_call` / `#describe_result` with the per-tool overrides; the
  new event fields.
- **CLAUDE.md** — a Seam entry: renderers style the three strings and
  sanitize them; they do not compose them.
- **book** — the rendering chapter, if it shows the transcript lines.
- pikuri-tui: its `ideas/hide-thinking-and-tool-calls.md` Part 2 graduates
  when the events carry the strings and its formatter prototype is deleted.
