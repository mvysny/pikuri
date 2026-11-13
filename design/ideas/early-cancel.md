# A cancel sent before `run_loop` starts is lost

Status: **open, proposal below.** Found wiring Puri's popup onto pikuri (its
`design/ideas/real-core.md`, `Q_early_cancel`).

## The race

`Agent#run_loop` calls `@cancellable&.reset!` first thing, so a stale cancel can't poison the
next turn. But whoever starts a turn decides it has started *before* that line runs on the
agent's thread, and allows a cancel from then on:

```
UI thread:    Return → turn = start(...)   Escape → cancellable.cancel!
agent thread:                    Thread.new ……… run_loop → reset! (the cancel is gone) → turn runs
```

`run_loop` cannot tell a stale cancel (left over from the last turn) from an early one (meant
for this turn). Only the code that decides "a turn starts now" knows where that line falls.

Who has the window:

- **pikuri itself, in sub-agents.** `SubAgentTool` hands the child the parent's own
  `Cancellable` and calls `sub.run_loop`, whose `reset!` clears the shared token. A Ctrl+C
  after the `agent` call's `before_tool_call` check, while the child is being built (tool
  rebuilds, `mktmpdir`, prompt), is lost for the whole tree: the child runs its full task, and
  the parent carries on after it. No host can fix this one.
- pikuri-web `Runner`: a cancel while `:queued` already works (`@abandon`). `claim_running`
  sets `:running` under `@lock` on the pool thread; a cancel between that lock's release and
  `run_loop`'s `reset!` is lost. Tiny window.
- pikuri-tui `AgentSession#interrupt`: `cancel!` if `@turn_in_progress`, set on the UI thread
  before the turn's thread starts.
- Puri: Escape reaches the `Turn` the moment Return made it; its thread runs at priority −3,
  which widens the window.
- The `bin/` scripts trap SIGINT just before `run_loop`.

It's narrow, but it is the one cancel a user sends on purpose: Return, then "no, wrong
question". The turn then runs to the end, a cold prefill and all.

## Fixes considered

1. **The host owns the reset.** `run_loop` stops calling `reset!`; a host calls it when it
   *decides* to start a turn, on its own thread, under whatever lock guards its "running"
   state, and before it hands the turn to a thread. Breaking: every host and `bin/` script
   that loops on `run_loop` adds the call, or a cancel left over from the last turn trips the
   next one at its first check. Fixes the sub-agent case for free, because the child no longer
   resets the shared token.
2. **The same, opt-in:** `run_loop(…, reset_cancellable: true)`. Non-breaking, but both a host
   that owns the reset *and* `SubAgentTool` must pass `false`, so the default is wrong for
   pikuri's own internal caller.
3. **A token per turn**, `run_loop(…, cancellable:)`. Invasive: the agent's `Cancellable` is
   captured at construction by the `RequestThrottle` in `build_context` and by `SubAgentTool`
   (`parent.cancellable`), and both would have to follow the per-turn token.

Resetting at the *end* of a turn instead only moves the race: a cancel landing between
`run_loop`'s return and the host marking itself idle would poison the next turn.

## Proposal

**Fix 1, with `reset!` renamed to `arm!`.**

- `Cancellable#reset!` becomes `#arm!`. The call now means "a turn opens" rather than "the
  agent tidies up"; `to_s` already says `armed`. The rename also makes a missed caller fail
  loudly rather than keep the old behaviour silently.
- `run_loop` no longer arms. `clear_conversation` keeps arming, since it is a host-triggered
  boundary anyway.
- **No new `check!` in `run_loop`.** An early cancel already ends the turn before the prefill:
  `ServerPermits#take` checks the flag before it looks at the permit count, and the
  `RequestThrottle` is always wired. The user message is appended and `UserTurn` emitted first,
  so history keeps a user turn with no answer, the same as a cancel during the prefill today.
  The host has already shown that message, so keeping it is consistent.
- Where each caller arms:
  - pikuri-tui `start_turn`: on the UI thread, before `Thread.new`.
  - pikuri-web `claim_running`: where it sets `:running`, under the `@lock` that `cancel`
    checks. The `finish_turn` resume path also goes through it.
  - Puri: where Return makes the `Turn`, before its thread starts.
  - `bin/` scripts that wire a `Cancellable`: just before installing the SIGINT trap.
    pikuri: `pikuri-chat`, `pikuri-secretary`, `pikuri-minions`, `pikuri-briefing`,
    `pikuri-thunderbird`, `pikuri-corpus`. pikuri-workshop: `pikuri-code`, `pikuri-os`,
    `pikuri-computer`, `pikuri-openlibrary`.
  - `SubAgentTool`: nothing. The child shares the parent's token, which the parent's host
    armed.

Left as-is: a cancel that lands after a turn's last `check!` (a non-streaming final answer, or
between `run_loop` returning and the host going idle) is ignored, as today. The next `arm!`
clears it.

## Done when

- `run_loop` no longer arms; `Cancellable#arm!` replaces `reset!`; `Cancellable`'s and
  `Agent`'s docs say the host arms it per turn; a CHANGELOG line names the break.
- A pikuri-subagents spec: a cancel sent while the child is being built ends the tree.
- Each host arms where it starts a turn, and has a spec: a cancel sent before the turn's
  thread runs ends that turn before any request reaches the server
  (`Pikuri::Testing::Gate` holds the turn so the order is certain). Check first that
  `Pikuri::Testing`'s fake goes through `RequestThrottle`; if it stubs underneath, the spec
  asserts on the first streaming chunk instead.
