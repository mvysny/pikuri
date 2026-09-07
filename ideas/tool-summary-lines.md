# Tool summary lines: the tool composes its own one-line display form

Status: **ready for implementation** (2026-09-07). Every open question is
settled; the ordered plan is in *§Implementation plan* at the end, and the
rest of this note is the rationale the implementer needs to write the
yardoc, the DECISIONS entry and the CHANGELOG. Implementability was checked
against ruby_llm 1.16 and every shipped tool (*§Survey*, *§Verified against
ruby_llm*): feasible without a ruby_llm patch; the first-required default
covers 25 of 34 tools and the other 9 override a method on `Tool`.
Requested
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

`O_tool_declares` — **chosen.** The tool composes the summary where the
data is; pikuri sends `content` to the model and `summary` to the listeners;
every renderer prints the same string. Two mechanisms below; they are not
exclusive.

## Mechanism for the result summary

### `O_tool_result` — a rich return value (chosen; named `Tool::Result` below)

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

**Decided: both.** `Tool::Result` for result summaries that need structure,
`describe_call` / `describe_result` overridden where a method suffices, and
the defaults in `Tool` covering everything that declares neither.

### Verified against ruby_llm 1.16 (2026-09-07)

- `Chat#execute_tool_with_callbacks` runs `after_tool_result` with the
  **raw** return object; `add_tool_result_message` `to_s`es it afterwards
  (`chat.rb` L374–387). The rich return needs no patch. `Tool::Halt` has the
  identical shape (`attr_reader :content`; `to_s = content.to_s`).
- `content_like?` is `is_a?(Content) || is_a?(Content::Raw)`, so option (a)
  (the *String-only* decision) stands: a `Result` may wrap a `String` only.
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
  event (completions, HTTP) and must pass them through. **Decided (i)**,
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
`summary:`. Both are emitted from `Agent`, so the agent computes once and
renderers only style. `Q_event_shape` — **decided 2026-09-07: strings**, not
a `tool:` reference the renderer queries: events stay plain serializable
`Data` (pikuri-web ships them over SSE; `HistoryReplay` synthesizes them),
and three cases have no `Pikuri::Tool` to reference at all — an MCP tool,
ruby_llm's "Model tried to call unavailable tool" error, and a replayed
history — so a reference would be `nil` there and every renderer would grow
a branch.

**How the agent computes them.** In `before_tool_call` it holds only
ruby_llm's `tc` (`id`, `name`, `arguments`), and it needs the
`Pikuri::Tool` to call `display_name` / `describe_call`. Not from
`Agent#tools`: the `agent` and `mcp_connect` tools register through
`ExtensionContext#add_raw_tool`, which deliberately keeps them out of that
list (sub-agents must not snapshot them), so an index over it would miss
the `agent` override. Instead the synthetic wrapper `Tool#to_ruby_llm_tool`
mints exposes its `Pikuri::Tool` (a `pikuri_tool` reader), and the agent
looks the instance up in `@chat.tools[tc.name.to_sym]` — ruby_llm's own
public name→instance table, which every registration path feeds. A tool
that responds to `pikuri_tool` yields the two strings via the tool; anything
else (an MCP raw tool, an unknown name) gets `Tool.display_name_for(name)`
and the generic `k=v` argument.

```ruby
@chat.before_tool_call do |tc|
  tool = @chat.tools[tc.name.to_sym]
  tool = tool.respond_to?(:pikuri_tool) ? tool.pikuri_tool : nil
  @listeners.emit(Event::ToolCall.new(
    tool_call_id: tc.id, name: tc.name, arguments: tc.arguments,
    display_name: tool ? tool.display_name : Tool.display_name_for(tc.name),
    argument:     tool ? tool.describe_call(tc.arguments) : Tool.describe_arguments(tc.arguments)))
  …
end
```

Two strings rather than one composed `WebSearch(rails 8)`: `argument:` *is*
the outcome of `tool.describe_call(arguments)`, and it travels beside
`display_name:` because the two are treated differently downstream — the
cap (decided: the renderer's) and any styling apply to the argument alone,
and a bare no-arg call renders `EnterPlanMode`, not `EnterPlanMode()`. The
renderer's one composition is the format string `name(arg)`; the *content*
of either half is never its to compose.

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

**`Q_persist_summary` — decided 2026-09-07: persist all three strings in
`History`.** A summary is derived from structured data that is gone once
the observation is flattened, so *nothing* can recompute it on reload — and
even the call-side strings need the tool, which a later wiring may no
longer have (a removed extension, a renamed MCP server), degrading
`Write(lib/foo.rb)` to `Write(path=…, content=…)`. All three are short by
definition, so they are cheap to keep. Schema: each entry of an assistant
message's `tool_calls` gains `display_name` + `argument`; a `tool` message
gains `summary`. All three are **local-only** like `id` / `kind` — they
never reach a provider, and the loader reads an absent one as `nil`
(additive, old files keep loading; `D_history_local_ids` is the precedent).
The agent collects them in `@message_meta` the way it already carries
`thinking` — see *§Implementation plan*.

Third emit site: pikuri-web's `HistoryReplay` builds `ToolCall` /
`ToolResult` from a saved `History` with no `Tool` in hand; with the strings
persisted it simply reads them, and for a `nil` (a pre-summary history, or a
result repaired at load) falls back to `Tool.display_name_for(name)` /
`Tool.describe_arguments(arguments)` / `Tool.describe_content(content)` —
the same fallbacks the *unavailable tool* case uses.

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

None. Settled 2026-09-07, each recorded in place above: `Tool::Result` over
`Observation`; `String`-only `Result`, no ruby_llm internals touched; both
events carry `name:` + `tool_call_id:`; the argument cap is the renderer's;
strings on the events, computed by the agent via the wrapper's
`pikuri_tool` reader (`Q_event_shape`); all three strings persisted in
`History` (`Q_persist_summary`); the nine `describe_call` overrides; `LSP`
as the one `display_name` override; MCP names as `Server::Tool`.

## Implementation plan

In this order — each step loads and passes `rake check` on its own. Core
first, then the tools, then the renderers. pikuri-web and pikuri-tui are
sibling repos and ship their renderer changes in the same release as the
pikuri bump, since the event constructors change (see step 3).

1. **`Tool` surface** (`pikuri-core/lib/pikuri/tool.rb`, `tool/result.rb`,
   `tool/parameters.rb`).
   - `Tool::Result = Data.define(:content, :summary)` with `to_s = content`;
     `content` must be a `String` (raise `ArgumentError` otherwise — the
     *String-only* decision), `summary` a one-line `String`. Its rdoc carries
     the *structural, never excerpted* rule and the *summaries are code*
     rule from §Safety.
   - `Tool.display_name_for(name)` (module function): split on `__`, join
     with `::`; within a segment any non-alphanumeric run is a word break,
     each word capitalized. `Tool#display_name` defaults to it.
   - `Tool.describe_arguments(arguments)` (module function): supplied args
     as `k=v` joined by space, values `to_s`; `''` for none. Used when no
     `Parameters` are known (MCP, unavailable, replay fallback).
   - `Tool#describe_call(arguments)`: value of the first required parameter
     (`to_s`; an `Array` joins with `, `); no required parameter →
     `Tool.describe_arguments`; no parameters → `''`. Needs a public
     `Parameters#required` reader (declaration-ordered `Array<String>`) and
     `Parameters#names`.
   - `Tool.describe_content(content)` (module function): `Error: …` →
     its first line; `RubyLLM::Content` → `Returned <mime>, N kB`; a `Hash`
     with `:error` (ruby_llm's unavailable-tool result) → the message;
     otherwise `Returned N lines` when multi-line, else `Returned N bytes`.
     `Tool#describe_result(content)` defaults to it.
   - `#to_ruby_llm_tool`: the synthetic class gets `define_method(:pikuri_tool)
     { pikuri_tool }` (instance method — `Chat#with_tool` stores an
     instance). Only strings are sanitized *at the renderer*, so none of
     these methods sanitize.
2. **Events** (`agent/event.rb`): `ToolCall = Data.define(:tool_call_id,
   :name, :arguments, :display_name, :argument)`, `ToolResult =
   Data.define(:tool_call_id, :name, :content, :summary)`. Required
   keywords, no defaults — the four constructors are pikuri's (three in
   `agent.rb`/`history.rb`, one in pikuri-web's `HistoryReplay`), and a
   **Breaking** CHANGELOG entry names the new fields.
3. **Agent emit sites** (`agent.rb`, wiring ~L644–651 and
   `repair_dangling_tool_calls!` ~L976).
   - `before_tool_call`: look up `@chat.tools[tc.name.to_sym]`; if it
     responds to `pikuri_tool`, use `tool.display_name` /
     `tool.describe_call(tc.arguments)`, else the two module fallbacks.
     Stash `{tool_call_id: tc.id, name: tc.name, tool:}` in a single
     `@pending_tool_call` slot — the ordering trick, valid under the
     `tool_concurrency: off` contract `Tool`'s `== Sharing` imposes; say so
     at the slot and name `RubyLLM.instrument('tool_call.ruby_llm')` (the
     `instrumenter` config option, whose payload pairs `tool_call` with
     `result`) as the reopen path if concurrency ever goes on. Record
     `display_name` / `argument` per call id in the *assistant* message's
     `@message_meta` entry (the message with `tool_calls` is already added
     by the time `before_tool_call` fires) — `meta[:tool_calls] = {id =>
     {display_name:, argument:}}`.
   - `after_tool_result`: summary = `result.is_a?(Tool::Result) ?
     result.summary : (tool ? tool.describe_result(result) :
     Tool.describe_content(result))`. Emit `ToolResult` with the stashed id
     and name; hold the summary until `after_message` delivers the `:tool`
     message, then `track_message(msg, summary:)` — the same identity-keyed
     map that already carries `thinking`, so nothing can drift.
   - Dangling-call repair: `summary: 'Interrupted'`, ids and names from the
     calls in hand.
4. **History** (`agent/history.rb`): `History::ToolCall` gains
   `display_name:` / `argument:` (default `nil`), `History::Message` gains
   `summary:` (default `nil`); `message_to_h` writes them when non-nil;
   `load` reads them additively (absent → `nil`); `from_ruby_llm` takes
   them from `meta`; `repair_interrupted_tool_calls` sets `summary:
   'Interrupted'`; `load_history!` re-populates `@message_meta` so a
   re-export round-trips. Extend the `T_history_encapsulated` /
   round-trip specs with all three fields, including a pre-summary fixture
   that loads with `nil`s.
5. **Tool overrides + `Result` returns**, one commit per gem, wording per
   the §Shipped tools table:
   - `describe_call`: `exit_plan_mode` (`''`), `lsp` (`"#{operation}
     #{symbol}"`), `agent` (`"#{name}: #{task}"`), `task_completed` /
     `task_in_progress` / `task_delete` (title via `list`, falling back to
     `"##{id}"` when unknown), `task_create` (`"#{items.size} items"`),
     `file_list` (`path || '.'`). `thunderbird_*_search` need nothing —
     the no-required default already yields `k=v`.
   - `display_name`: `LspTool` → `'LSP'`.
   - `Result` where the summary needs structure the content loses:
     `web_search` (`Returned N search results`), `read` (`Read N lines`;
     the `Content` PNG path stays bare), `write` / `edit` (`Wrote N lines` /
     `Added N lines, removed M lines`), `glob`, `grep`, `bash` (`exit N, M
     lines`), `file_list`, `fetch` / `web_scrape`, `skill` (`Loaded N kB`),
     `agent` (`Answered, N kB`), `task_*` (`N tasks, M done`),
     `mcp_connect` (`Connected, N tools`), `rag_*` / `vectordb_*` /
     `recall` / `fileindex_search` (`Found N hits`), `thunderbird_*`
     searches (`Found N messages/events/contacts`), `thunderbird_mail_compose`
     / `calendar_create` (`Handed to Thunderbird`), `enter_plan_mode` /
     `exit_plan_mode` (`Plan mode on` / `off`), `git_clone` (`Cloned, N
     files`), `lsp` (`N results`). `calculator` overrides
     `describe_result` instead (the value *is* the content). Every `Result`
     is built from counts the tool computed, never from a substring of
     `content` — the specs assert the summary for a fixture and that it
     contains no fetched text.
6. **Renderers.** `Listener::Terminal` (this repo): `→ Name(arg)` /
   `= summary`, both through `Pikuri::Sanitizer`, argument capped to the
   terminal width. pikuri-web `SseListener` and pikuri-tui
   `ConversationTextView::Listener`: same two strings, sanitized then
   escaped/parsed as each already does; pair result to call by
   `tool_call_id`, retiring pikuri-tui's `@pending_formatter`; a renderer
   showing a diff block drops the summary under it. pikuri-web's
   `HistoryReplay` reads the persisted strings with the §Event fallbacks.
7. **Graduate this note** per *When this is done*: DECISIONS entry (roads
   not taken: `O_llm_narrates`, `O_renderer_parses`, `Observation`, content
   options (b)/(c), the `tool:`-reference event shape, not persisting),
   CLAUDE.md seam line, CHANGELOG (one `Add` for `Tool::Result` + the
   describe methods, one **Breaking** for the event fields), yardoc
   everywhere named above, then `git rm` this file.

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
