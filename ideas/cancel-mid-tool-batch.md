# An unwind mid-tool-batch leaves the live chat unsendable

Status: **decided, not implemented** — repair on unwind (sketch B), broadened
from cancellation to *any* exception. Split out of
`ideas/concurrent-tool-use.md` (deleted 2026-08-28) when every other item
there had graduated; the pointer in `DECISIONS.md` `D_tool_cancellation` now
lands here. On implementation this graduates to a `D_` entry (there is a real
fork — see *Roads not taken*) plus yardoc on `Agent#run_loop`.

## The hazard

`ruby_llm`'s `complete_once` does `add_message response` **before**
`handle_tool_calls`, so the assistant message carrying `tool_calls` is in
`@chat.messages` before any tool runs. If anything unwinds out of the batch
before every call has a `:tool` message answering it, the conversation keeps an
assistant turn with unanswered calls.

Providers reject an assistant `tool_use` with no matching result. So the next
`complete` on that same agent — another `run_loop`, an interloper turn — posts
a malformed batch and fails.

**It is not a cancellation problem.** Cancellation is just the source we
noticed. A tool raises for plenty of reasons pikuri deliberately does not
catch: a programming error in tool code, unexpected corruption, a library
blowing up. "Errors are loud" means those propagate — and every one of them
dangles the batch exactly the same way.

The full source list:

- **Any exception out of a tool.** The common case, and the one that makes
  every prevent-the-damage scheme insufficient.
- **`Cancelled`** — from `before_tool_call`, from `Cancellable#sleep` inside a
  tool (`D_tool_cancellation`), or propagated out of a **sub-agent** child (the
  `agent` tool shares the parent's token by reference, so the child's raise
  damages the *parent's* batch).
- **`StepLimit::Exceeded`** — raised from `tick!` in the same
  `before_tool_call` callback, so it dangles the opener identically.
- **`Interrupt` / `SignalException`**, in a host that doesn't trap SIGINT.
  Not a `StandardError`, which matters for where the repair goes.

## It is a shipped bug, reproducible in-repo

An earlier draft of this note claimed no `bin/` script hits it because "they
exit, or they `clear_conversation`". That is wrong.

- **`bin/pikuri-chat:73`** (`run_turn`) rescues `Cancelled` and returns to the
  `> ` prompt with the agent intact. Ctrl+C during a tool batch, then any next
  message → malformed batch.
- **Seven `bin/` scripts run `StepLimit` with `:synthesize`** (chat, memory,
  assistant, openlibrary, thunderbird, minions, corpus). The budget trips, the
  synth produces an answer, `run_loop` returns *normally*, and the damaged chat
  is still there for the next turn.

The synthesizer itself is safe: `Synthesizer.format_evidence` renders the
parent's messages into a prompt *string* on a fresh nested agent, and
deliberately drops tool calls with no matching result. It never re-posts them.
That matters for where the repair goes — see below.

## How it fails, per provider

OpenAI and Anthropic reject the malformed batch with a 400. A local llama.cpp
does not validate — it renders whatever the chat template makes of an
unanswered tool call, and the model improvises. Same silent-on-local /
loud-on-cloud split as `D_reference_text_as_user_turn`, and the same reason not
to lean on the provider as the backstop.

## Why it isn't already fixed

`Agent::History#repair_interrupted_tool_calls` solves exactly this shape — it
synthesizes `INTERRUPTED_RESULT` (`'[Tool execution was interrupted]'`) for
every dangling call. But it runs on the **load** path only, deliberately: the
file stays a faithful record and the repair happens on the way in. The *live*
chat has no equivalent, so the repair exists for a killed process and not for
an unwound turn in a surviving one.

Note what that implies: `export_history` → `load_history!` of a damaged
conversation already works. The only broken path is *continuing in the same
process*.

## The decision: repair on unwind

Append a `:tool` result for every dangling call before the exception leaves
`run_loop`, then let it propagate. The conversation stays usable; nothing is
swallowed.

### Where: an `ensure` on `run_loop`

Not in the rescues. Three reasons:

- **It covers every source**, including `Interrupt` and whatever nobody thought
  of, without enumerating exception classes.
- **Ordering.** `ensure` runs *after* the `rescue StepLimit::Exceeded` body, so
  the synthesizer still sees the unrepaired history and `format_evidence`'s
  documented drop-unmatched-calls behaviour is untouched. Repairing first would
  quietly change what the synth reads.
- **It answers the objection to B**, which was "mutates the live conversation
  from a rescue". `ensure` is the idiomatic place for *leave this object
  usable however we left it*, and it is a no-op on the success path (nothing
  dangles by construction).

`$!` supplies the in-flight exception inside `ensure`. Slightly magic; the
alternative is a `rescue Exception => e; repair(e); raise` clause ordered after
the two specific ones, which is more code and gets the synth ordering wrong.

The scan is tail-only: after the opener, only `:tool` messages are appended, so
the damage is always "last assistant opener + a prefix of its results", never
an interior hole. `Agent#tool_batch_complete?` already computes the same
predicate for the interloper drain. `History#repair_interrupted_tool_calls`'
interleaving logic (holding `pending` until the real results have gone by) is
for stored files and is not needed here — appending the missing results at the
end is the whole job. Sharing code with `History` is possible but awkward:
`History::Message#role` is a `String`, `RubyLLM::Message#role` a `Symbol`, so a
duck-typed helper has a trap in it. Duplicating the tail scan is the smaller
evil.

### What: the raiser and the never-ran are different messages

Under sequential execution the **first** dangling call is the one that raised
or was about to; every later one never started. Both facts are worth telling
the model, and it is the only explanation it will ever get for why its calls
went unanswered — it reads them on the next turn, alongside whatever the user
then typed.

| cause | first dangling | the rest |
|---|---|---|
| tool exception | `Error: <class>: <message>` | `[Not executed — a previous tool call in this batch failed]` |
| `Cancelled` | `[Cancelled by the user]` | `[Not executed — the user cancelled this turn]` |
| `StepLimit::Exceeded` | `[Not executed — step budget exhausted]` | same |

`Error: …` deliberately matches the shape `Tool#run` already returns for
validation failures, so the model is not being taught a second error dialect.

The first-dangling-is-the-raiser rule holds **only sequentially** — ruby_llm's
`tool_concurrency` (default off, and `Tool`'s yardoc already says leave it off)
would land results out of order. Worth restating at the repair site, since this
is now a second thing that breaks if someone turns it on.

`INTERRUPTED_RESULT` is not reused. It is right for the load path — a killed
process, where a retry is sensible and pikuri genuinely cannot tell which of
these happened. Here the cause is known, and a user cancel wants the model to
stop and ask rather than try again.

### What it does not change

- **The History seam.** The live chat genuinely contains those results now, so
  exporting them is faithful rather than an invention — the "file is a faithful
  record, repair on the way in" rule is intact, and the load-path repair stays
  for killed processes.
- **Errors are loud.** The exception still propagates. The repair only means
  that a host which *chooses* to continue gets a conversation it can send.

### Three details, settled

- **Listeners see each synthesized result**, as an `Event::ToolResult`
  (`Data.define(:content)` — one field, so nothing to extend). A host must be
  able to *display* what got appended, and the event stream stays consistent
  with `@chat.messages`. The cost accepted here is that it renders identically
  to a result the tool actually returned; the content strings are written to
  read as pikuri's voice (`[Not executed — …]`) rather than a tool's.
- **Same `kind:` as a normal tool result** — i.e. `track_message`'s default
  `'user'`, since that is what ruby_llm's own `add_tool_result_message` gets
  through the `after_message` hook. No new `kind`: the History seam's `kind`
  separates a user turn from an injected reference block, and a repaired tool
  result is neither, it is just a tool result.
- **The exception message goes in verbatim** (class + message, never a
  backtrace). It can carry untrusted bytes — a filename off a scraped page, an
  HTTP body — but this is not a new leg: `Tool#run`'s `"Error: #{e.message}"`
  and tools' own HTTP error strings already put exactly those bytes in the
  conversation, and the diagnostic is worth more than the marginal exposure.

### The spec that pins it

Now writable in-repo, which it wasn't when this note assumed no host cancels
and continues: cancel (or raise) mid-batch, run a second `run_loop`, and assert
over `Pikuri::Testing`'s recorded request body that every `tool_call` id in the
last assistant message has a matching `:tool` message. Same technique the
wire-format specs in `pikuri-core/spec/pikuri/testing_spec.rb` use for
`D_reference_text_as_user_turn`.

## Roads not taken

- **Prevent instead of repair: raise only at well-formed points.** Have
  `before_tool_call` observe the flag rather than raise, have the per-agent
  wrapper in `to_ruby_llm_tool` turn a `Cancelled` into a `'[Cancelled]'`
  observation and short-circuit the batch's remaining calls, and raise from
  `after_message` when `tool_batch_complete?`. Nothing is ever synthesized:
  every call gets a real result. Attractive, and it collapses to one sentence
  ("`Cancelled` is raised only where `@chat.messages` is well-formed").
  Rejected on two counts. It only handles cancellation — a `NoMethodError` in
  tool code still dangles the batch, so the repair path has to exist anyway and
  this is a second mechanism on top. And it makes cancellation *less*
  responsive: cancel latency becomes "when the current tool returns", which
  forecloses the direction we want, where a long-running tool blocked in IO
  polls the flag and aborts itself. (`RubyLLM::Tool::Halt` is the same idea
  wearing ruby_llm's API and loses for the same reasons.)
- **Repair at turn start instead of at unwind.** Symmetric with the load path
  and catches damage from sources the unwind doesn't know about. Rejected as
  strictly later: the damaged chat is observable to the host in between
  (`export_history`, a listener, a UI redraw), and the cause — which is what
  makes the message useful — is no longer in hand by then.
- **Drop the damaged tail.** Delete the opener and its partial results, ending
  at the last clean boundary. Cheap, no invention. Rejected for the reason
  `repair_interrupted_tool_calls`' yardoc already gives: it erases that the
  model ever decided to call the tool, and "you tried this and it failed" is
  the single most useful thing to carry into the next turn.
- **Refuse loudly** — a named error on the next `run_loop` telling the host to
  reset. Hands the host a conversation it cannot use and no way to fix it.
- **Nothing, and document that a damaged agent must be reset.** Puts the burden
  on every host and fails at the provider rather than at the mistake — and per
  *How it fails, per provider*, on a local model it does not fail at all, it
  just goes strange.
