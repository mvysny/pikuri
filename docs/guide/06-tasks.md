# Chapter 6 — Task tracking (the agent's working memory)

A light chapter between two heavyweights. By the end you'll know
why pikuri ships a task list, why it has exactly the shape it
does, and how to wire it onto any agent. Along the way, the gem
turns out to be a small but honest window into *how* LLMs actually
maintain (and lose) state across a long conversation.

## Why a task list at all

LLMs don't have memory. Each turn, the model sees the same flat
text blob — system prompt + every previous message + every tool
observation — and produces the next message. "Remembering" is just
"that text is still in the context window." Once a piece of text
falls off the end of the window, or gets buried 50 messages back,
it might as well not exist for next-turn purposes.

Try this thought experiment. You ask the agent to do a 30-step
refactor. By step 25, the original plan it laid out in step 1 is
thousands of tokens upstream. The model is now reasoning over the
last few tool observations, not over the plan. So it drifts: it
finishes step 23, mistakes step 24 for step 26, declares the task
done. You can *watch* this happen on a long enough task with no
externalized state.

A task list is the model's escape from this: a structured slot
that's *included in every turn's context* until the model
explicitly removes it. Three distinct effects fall out:

1. **Forced upfront decomposition.** Writing the plan as a tool
   call makes the model commit to a structure before it acts.
   Without that, models tend to do step 1, see new information,
   do step 2, get distracted, and never come back to step 4.
2. **Persistent working memory across turns.** The list is in
   context on *every* subsequent turn. Even at step 25 of 30, the
   plan is right there — not buried behind 4000 tokens of tool
   output.
3. **Self-correction checkpoint.** "Mark `in_progress` before
   starting, `completed` only when verified" forces an explicit
   state transition. The model has to *type* "completed" — which
   means it has to evaluate whether the step actually finished.
   Catches premature-victory bugs ("I wrote the function, done!"
   — but no tests ran).

That's the whole game. The gem is small; the lesson it embodies
is large.

## The four tools

`pikuri-tasks` ships exactly four LLM-facing tools, one per verb:

- **`task_create`** — pass a newline-separated string of one or
  more items. All start as `pending`. Use this once at the start
  of a multi-step task to capture the plan in one call.
- **`task_in_progress`** — pass the `content` of an existing item.
  Marks it as in-progress. Use immediately before starting work
  on the item.
- **`task_completed`** — pass `content`. Marks the item as done.
  Use only after the work (and any verification) is actually
  finished.
- **`task_delete`** — pass `content`. Removes the item entirely.
  Use for items that turn out not to be needed; reserve
  `task_completed` for work actually done.

Every mutation returns the full current list as its observation,
so the model always sees fresh state without a separate read tool:

```
<tasks>
- [pending] Add dark mode toggle
- [in_progress] Write unit tests
- [completed] Update README
</tasks>
```

Empty renders as `<tasks>(empty)</tasks>` — an unambiguous "the
call worked and the list is now empty" signal.

## Three design choices worth a moment

The shape above looks obvious once you see it, but each piece was
a decision with an alternative — and each alternative is worth
understanding because it surfaces a real LLM-ergonomics tradeoff.

### Status is in the verb name, not a parameter

The obvious shape is one `task_set_status(content:, status:)` tool
with `status` being an enum: `pending` / `in_progress` /
`completed`. Pikuri instead has three separate verbs.

The reason is small-model failure modes. Enum values are
*strings* the model emits — and a smaller local model will
cheerfully produce `"in-progress"` or `"inprogress"` or
`"InProgress"`. The validator catches it and replies with an
`Error: ...` string, the model retries, sometimes lands the same
wrong value again. Tool names, by contrast, are picked from a
finite list the API enforces structurally — the model literally
cannot misspell `task_in_progress`. Trading one parameter for
three tool classes eliminates a whole category of failure.

(This is a recurring small-model design move: convert "string
the model emits" into "tool the model selects" wherever you can,
because the second is API-enforced and the first isn't.)

### Content doubles as identifier — no IDs

Claude Code's task tools assign each task an integer ID and
update tasks by ID: `TaskUpdate(taskId: "3", status:
"completed")`. Cleaner database-wise, but it forces the model to
maintain an ID-to-content mapping across turns. Models hallucinate
IDs — they confidently produce `taskId: "7"` when the highest ID
is 4.

Pikuri uses the content string itself as the identifier:
`task_completed(content: "Add dark mode toggle")`. The model is
*very* good at echoing back strings it just emitted — they're
sitting in its own context as the rendered task list. No mapping
to track, no IDs to hallucinate.

The price: duplicate contents are rejected on creation
(`Error: task already exists: 'foo'`), and editing an item's text
means deleting and re-creating it. For short task descriptions in
a session-scoped list, that's a fine trade.

### Mass-create takes a newline-separated string — not a JSON array

opencode's equivalent tool takes a JSON array of objects:
`{ todos: [{content: ..., status: ...}, ...] }`. Pikuri's
`task_create` takes a single string: `"first\nsecond\nthird"`.

The difference is failure surface. A nested-array tool argument is
JSON the model has to balance: brackets, quotes, escapes. A small
model fails on this more often than you'd hope, and when it fails
the whole call dies — the JSON parser doesn't recover anything.
A newline-separated string has no brackets, no quotes to escape,
no balancing — just text the model already knows how to produce.

(Worth flagging: with grammar-constrained sampling enabled
server-side — which `llama.cpp` supports — JSON failures
practically disappear. But constrained sampling isn't on
everywhere by default, and the string form needs no opt-in.)

## What state lives where

The list is an `Array<Item>` inside one `Pikuri::Tasks::List`
instance, held by the `Pikuri::Tasks::Extension` that wired it.
Three properties matter:

- **Per-Agent.** Each agent that adds the extension gets its own
  fresh list. Two agents in the same process don't share.
- **In-memory.** Nothing is written to disk. When the agent is
  garbage-collected, the list goes with it. Re-running the binary
  starts you fresh — by design; persistence is a feature the gem
  deliberately doesn't have.
- **Not inherited by sub-agents.** This follows pikuri's
  established rule from chapter 2: sub-agents don't inherit
  extensions. A `RESEARCHER` or `FILE_MINER` spawned via the
  `agent` tool gets no task list. The parent's plan stays private
  to the parent, and sub-agents focus on their narrow remit
  rather than the parent's overall workflow.

If you want a sub-agent to also have its own list, add the
extension to its configurator at construction — explicit opt-in,
no implicit sharing.

## Wiring it onto an agent

Adding tasks to any pikuri agent is one line in the `Agent.new`
block:

```ruby
require 'pikuri-core'
require 'pikuri-tasks'

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension Pikuri::Tasks::Extension.new
end
```

That's the whole setup. `Pikuri::Tasks::Extension#configure`
constructs a fresh `Tasks::List`, registers the four tool classes
(each capturing the same list by closure), and appends a brief
`<tasks_usage>` workflow snippet to the system prompt — the
LLM-facing nudge that explains the workflow.

For your own host: pick a system prompt that gives the model
something multi-step to do, drop the extension into the block,
and watch the model decompose its work in the first tool call.
That's the entire feedback loop.

`pikuri-code` is a likely future home for the extension by
default — coding agents do multi-step work and benefit from the
self-correction property — but at the time of writing it wires
the extension manually if at all, so the chapter-3 walkthrough
doesn't assume it.

## What's next

[Chapter 7 — Skills (stub)](07-skills.md) covers the last
extension `pikuri-code` discovers: [Agent
Skills](https://agentskills.io/specification), portable folders of
"when you see *X*, do *Y*" instructions. Skills are text the model
loads into the conversation on demand — closely related to the
task list in that both are about giving the model *more useful
context* than it could maintain by itself.
