# Cancel mid-tool-batch leaves the live chat unsendable

Status: **open**, no decision. Split out of `ideas/concurrent-tool-use.md`
(deleted 2026-08-28) when every other item there had graduated; the pointer in
`DECISIONS.md` `D_tool_cancellation` now lands here.

## The hazard

A cancel unwinds `run_loop` by raising `Control::Cancellable::Cancelled`
(`agent.rb`, the `rescue` that emits `Event::Cancelled` and re-raises). If it
lands *between* an assistant message carrying `tool_calls` and the `:tool`
messages answering it, `@chat.messages` keeps the assistant turn with one or
more calls unanswered.

Providers reject an assistant `tool_use` with no matching result. So the next
`complete` on that same agent — another `run_loop`, an interloper turn — posts
a malformed batch and fails.

`check!` fires before each call in a batch (`execute_tool`) and, when
streaming, before each chunk's emit, so the window is not narrow: any batch of
two or more tools has an interior cancellation point by design.

## Why it isn't already fixed

`Agent::History#repair_interrupted_tool_calls` solves exactly this shape — it
synthesizes `INTERRUPTED_RESULT` (`'[Tool execution was interrupted]'`) for
every dangling call. But it runs on the **load** path only, deliberately: the
file stays a faithful record and the repair happens on the way in. The *live*
chat has no equivalent, so the repair exists for a killed process and not for a
cancelled turn in a surviving one.

The hazard is also **pre-existing** rather than introduced by
`D_tool_cancellation` — making cancellation reachable from more places (a
tool's pacing wait, via `Cancellable#sleep`) only makes it likelier.

## Why no `bin/` script hits it

They exit, or they `clear_conversation`. This is a real-host problem — a TUI
that cancels a turn and keeps the conversation — which is the usual reason
nothing in-repo exercises it, and the usual reason not to trust a demo's
silence as evidence it doesn't exist.

## Sketches, none chosen

- **Repair on unwind.** Apply the `repair_interrupted_tool_calls` logic to
  `@chat.messages` in the `rescue Cancelled` before re-raising. Cheapest, and
  it reuses logic already written and specced — but it mutates the live
  conversation from a rescue, and the synthetic result then appears in a
  subsequent `export_history` as though the model had seen it. (Arguably
  correct: it *will* have seen it on the next turn.)
- **Repair on the way in, at turn start.** Symmetric with the load path — a
  turn begins by making the history sendable, wherever the damage came from.
  Costs a scan per turn, catches damage from sources the rescue doesn't know
  about.
- **Refuse instead of repairing.** Have the next `run_loop` raise a loud,
  named error telling the host to `clear_conversation` or reload. Honest, no
  silent invention, but it hands the host a conversation it cannot use and no
  way to fix it in place.
- **Nothing, and say so.** Document that a cancelled agent must be reset
  before reuse. Free; puts the burden on every host, and fails at the provider
  rather than at the mistake.

## What would settle it

A host that cancels and continues. Until then the fork is between "repair
silently" and "refuse loudly", and that is a question about what a cancelled
conversation *means* — which is worth deciding with the real caller in front of
us, not from the `bin/` scripts, none of which have the problem.
