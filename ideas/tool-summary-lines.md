# Tool summary lines: the tool composes its own one-line display form

Status: **brainstorm — nothing built, hold the implementation.** Requested
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

Naming. The proposal is the `ToolResult` family — `Pikuri::Tool::Result`
in the house nesting (`Tool::Parameters`, `Tool::ExecuteContext`,
`Tool::TrifectaLegs`). The one cost: pikuri would then have two things
called "tool result" — `Tool::Result` (what `execute` returns) and
`Agent::Event::ToolResult` (what listeners see). They are adjacent in the
data flow and the event carries the return's fields, so the shared name may
read as *the same thing at two stages*, which is roughly true — but rdoc
and specs will need to say which they mean. Kept as an alternative:
**`Pikuri::Tool::Observation`**, which is the word `Tool#execute`'s rdoc
already uses for the return value and collides with nothing. Pick one at
implementation time; `Q_result_name`.

Caveat — multimodal observations. `content_like?` is `is_a?(Content)`, so a
`Result` wrapping a `RubyLLM::Content` (the PNG a `read` returns) would be
`to_s`'d into garbage. Options, `Q_content_wrapping`:

- (a) a `Result` may only hold a `String`; a tool returning `Content` keeps
  returning it bare and gets the generic default summary. Multimodal
  observations are rare (image reads); `Returned image/png, 40 kB` is fine.
- (b) pikuri's `to_ruby_llm_tool` wrapper unwraps the `Result` *before*
  ruby_llm sees it, returning `.content` and stashing `.summary` in a
  per-call slot the `after_tool_result` callback reads. Works for `Content`
  too, but the stash is a second single-slot pairing trick and it breaks the
  moment `tool_concurrency` goes on.
- (c) extend `content_like?` via `ruby_llm_patches.rb`. Smallest code,
  another monkey-patch to carry across ruby_llm bumps.

Lean (a).

### `O_describe_hook` — a callable on the `Tool`

```ruby
Pikuri::Tool.new(name: 'bash', …,
  describe_result: ->(content) { "exit #{content[/^exit (\d+)/, 1]}, #{content.lines.size} lines" })
```

Purely additive, no return-type change, no `Content` question. But the hook
sees only the flattened `content`, so it is `O_renderer_parses` moved one
layer down: less duplication, same fragility. Still the right tool for two
jobs: (1) a tool whose summary genuinely *is* a function of the content
(`calculator`: the value); (2) the **call side**, where there is nothing to
return yet — `describe_call: ->(arguments) { arguments[:path] }` for a tool
whose primary argument is not its first required parameter.

**Lean: both.** `Tool::Result` (or `Observation`) for result summaries that
need structure, `describe_call:` as an override on the call side, and the
generic defaults below covering everything that declares neither.

## The call side: display name + primary argument

Computable from what `Tool` already knows, so no per-tool work in the common
case:

- `Tool#display_name` — CamelCase of `name`. MCP tool names arrive from a
  server and may carry `-` / `.` (ruby_llm sanitizes to `_`); treat any
  non-alphanumeric run as a word break. Lives in core so the three renderers
  agree.
- `Tool#primary_argument(arguments)` — the value of the **first required
  parameter**. `Parameters` keeps declaration order (`@properties` is an
  insertion-ordered Hash) and a `@required` list, so this needs only a reader
  on `Parameters` (`#required` is private today). Falls back to the first
  optional parameter, then `nil` (a no-arg tool renders `EnterPlanMode`).
  Overridable with `describe_call:`.

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

`ToolResult` should also gain **`name:`** (or `tool_call_id:`). Today every
renderer pairs a result with its call by strict call→result ordering — the
single-slot trick pikuri-tui's `@pending_formatter` and `agent.rb` L945 both
document as holding only while `tool_concurrency` is off. The summary work
touches every emit site anyway; naming the result on the event removes the
assumption for free. The second emit site — the dangling-call repair in
`Agent` (~L976, `INTERRUPTED_RESULT`) — gets a fixed summary
(`Interrupted`).

`History` does not store summaries (`Q_persist_summary`). A reloaded
conversation's `ToolResult`s are synthesized from `tool` messages and would
carry the generic default. Lean: **don't persist** for v1; the loss is one
line of nicety on old conversations, and adding a field to the message
schema is a migration.

## Defaults for tools that declare nothing

Every MCP tool and every third-party `Pikuri::Tool` gets a tolerable line for
free:

| part | default |
|---|---|
| display name | CamelCase(`name`) |
| argument | first required parameter's value, one line, capped |
| result summary | `Returned N bytes` (`N lines` when multi-line); `Returned <mime>, N kB` for a `RubyLLM::Content`; an `Error: …` content passes through as its first line |

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
| `task_*` | title | `3 tasks, 1 done` |
| `mcp_connect` | server id | `Connected, 14 tools` |
| `rag_search` / `vectordb_search` / `recall` | query | `Found 8 hits` |
| `thunderbird_mail_search` | query | `Found 8 messages` |
| `thunderbird_mail_compose` / `calendar_create` | recipient / title | `Handed to Thunderbird` |
| `enter_plan_mode` / `exit_plan_mode` | — | `Plan mode on` / `off` |
| `git_clone` | url | `Cloned, 412 files` |
| `lsp` | the operation | `N results` |

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
- **Cap the argument.** A `command` can be a 4 kB script and a `content` a
  whole file. One line, ~60 columns, `…`. The full text is in the confirmer
  block when confirm is on.
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

- `Q_result_name` — `Tool::Result` (proposed) vs `Tool::Observation`
  (matches existing rdoc vocabulary, no collision with `Event::ToolResult`).
- `Q_content_wrapping` — (a) `String`-only `Result`, `Content` stays bare;
  (b) unwrap in the wrapper with a slot; (c) patch `content_like?`. Lean (a).
- `Q_event_shape` — precomputed strings on the events vs a `tool:` reference.
  Lean strings.
- `Q_persist_summary` — store `summary` on the `tool` history message? Lean
  no for v1.
- Should `ToolResult` carry `name:` or `tool_call_id:`? Either kills the
  ordering assumption; `name:` is what a renderer wants, `tool_call_id:` is
  what concurrency needs. Possibly both.
- Argument cap width, and whether the cap is the agent's (one truth) or the
  renderer's (knows its width). Lean renderer.

## When this is done

Delete this note. Graduation homes (per `CLAUDE.md`):

- **DECISIONS.md** — `D_tool_summary_by_tool`: the tool composes its summary
  in code, never the model (prompt injection) and never the renderer
  (structure is gone after flattening); rejected `O_llm_narrates` and
  `O_renderer_parses`; the `Result`-vs-`Observation` naming call and the
  `Content` decision as consequences.
- **yardoc** — `Tool::Result` (or `Observation`) rdoc carrying the
  structural-never-excerpted rule and the "summaries are code" rule;
  `Tool#display_name` / `#primary_argument`; the new event fields.
- **CLAUDE.md** — a Seam entry: renderers style the three strings and
  sanitize them; they do not compose them.
- **book** — the rendering chapter, if it shows the transcript lines.
- pikuri-tui: its `ideas/hide-thinking-and-tool-calls.md` Part 2 graduates
  when the events carry the strings and its formatter prototype is deleted.
