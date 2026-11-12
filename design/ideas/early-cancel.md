# A cancel sent before `run_loop` starts is lost

Status: **open, a recommendation below.** Found wiring Puri's popup onto pikuri (its
`design/ideas/real-core.md`, `Q_early_cancel`).

## The race

`Agent#run_loop` calls `@cancellable&.reset!` first thing, so a stale cancel can't poison the
next turn. But a host decides a turn has started *before* that line runs on the agent's thread,
and lets the user cancel from then on:

```
UI thread:    Return → turn = start(...)   Escape → cancellable.cancel!
agent thread:                    Thread.new ……… run_loop → reset! (the cancel is gone) → turn runs
```

Every host has the window:

- pikuri-web `Runner#cancel`: `@cancellable.cancel! if @state == :running`; `:running` is set
  when the job is posted, before the pool thread reaches `run_loop`.
- pikuri-tui `AgentSession#interrupt`: `cancel!` if `@turn_in_progress`, set before the turn's
  thread starts.
- Puri: Escape reaches the `Turn` the moment Return made it; its thread runs at priority −3,
  which widens the window.

It's narrow, but it is the one cancel a user sends on purpose: Return, then "no, wrong
question". The turn then runs to the end, a cold prefill and all.

## Fixes

1. **The host owns the reset.** `run_loop` stops calling `reset!`; a host calls it when it
   *decides* to start a turn, on its own thread, under whatever lock guards its "running"
   state, and before it hands the turn to a thread. Only the host knows when a turn begins, so
   the flag's lifecycle belongs there. Breaking: every host and `bin/` script that loops on
   `run_loop` has to add the call, or a cancel left over from the last turn trips the next one
   at its first check. `clear_conversation` keeps its reset.
2. **The same, opt-in:** `run_loop(…, reset_cancellable: true)`; a host that owns the reset
   passes `false`. Non-breaking, but a flag parameter that only one kind of caller ever sets.
3. **A token per turn**, `run_loop(…, cancellable:)`, a fresh `Cancellable` each turn, so no
   reset is ever needed. Invasive: the agent's `Cancellable` is captured at construction by the
   `RequestThrottle` in `build_context` and by `SubAgentTool` (`parent.cancellable`), and both
   would have to follow the per-turn token.

Resetting at the *end* of a turn instead only moves the race: a cancel landing between
`run_loop`'s return and the host marking itself idle would poison the next turn.

**Recommended: 1.** It is a one-line change in pikuri, and the hosts are few and in reach
(pikuri-tui, pikuri-web, Puri, the `bin/` scripts). Each host's reset sits where it already
flips its "running" flag. Take 2 only if an outside host turns up that a break would hurt.

## Done when

- `run_loop` no longer resets; `Cancellable`'s and `Agent`'s docs say the host arms it per turn.
- Each host resets where it starts a turn, and has a spec: a cancel sent before the turn's
  thread runs ends that turn (`Pikuri::Testing::Gate` holds the turn so the order is certain).
