# pikuri-todo

In-memory todo list + four LLM-facing tools for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

Provides:
- `Pikuri::Todo::List` — per-Agent in-memory list of
  `(content, status)` items. Status is one of `pending`,
  `in_progress`, `completed`. Nothing is written to disk.
- Four tool classes, all sharing one `List` instance:
  - `Pikuri::Todo::Create` (`todo_create`) — mass-create pending
    items from a newline-separated `items` string. Atomic: if any
    line is a duplicate (within the batch or already on the list),
    nothing is added.
  - `Pikuri::Todo::InProgress` (`todo_in_progress`) — mark an item
    as `in_progress` by content.
  - `Pikuri::Todo::Completed` (`todo_completed`) — mark an item as
    `completed` by content.
  - `Pikuri::Todo::Delete` (`todo_delete`) — remove an item by
    content.
- `Pikuri::Todo::Extension` — wires the four tools + a brief
  `<todo_usage>` workflow snippet into a `Pikuri::Agent` via the
  `c.add_extension(...)` block API.

Two shape choices worth flagging:
- **Status is baked into the tool name** (no `status:` parameter
  with an enum). Removes the `"in-progress"` vs `"in_progress"`
  vs `"inprogress"` typo failure mode on smaller models.
- **Content doubles as identifier** across the three update tools
  (no item IDs to bookkeep). Duplicates are rejected on
  `todo_create` so the identifier stays unique.

## Install

```ruby
# Gemfile
gem 'pikuri-todo'
```

## Usage

```ruby
require 'pikuri-core'
require 'pikuri-todo'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(Pikuri::Todo::Extension.new)
end
```

The extension's `configure` constructs a fresh `Todo::List`,
registers all four todo tools against it (so they mutate the same
instance), and appends a short `<todo_usage>` snippet to the system
prompt explaining the workflow (create at the start, exactly one
`in_progress` at a time, `completed` only after verification).

Every mutation returns the full rendered list as its observation,
so the LLM always sees fresh state without a separate read tool:

```
<todos>
- [pending] Add dark mode toggle
- [in_progress] Write unit tests
- [completed] Update README
</todos>
```

Empty renders as `<todos>(empty)</todos>` so the LLM gets an
unambiguous "the call worked and the list is now empty" signal.

Sub-agents do **not** inherit extensions — a sub-agent spawned by
the `agent` tool gets a fresh persona and no todo list. The
parent's plan stays private to the parent.

## Further reading

- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-todo> (once published), or
  run `bundle exec yard` in this directory for a local copy.
