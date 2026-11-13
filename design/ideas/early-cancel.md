# A cancel sent before `run_loop` starts is lost

Status: **fix 1 implemented (uncommitted); looking for an API that a host can't get wrong.**
Found wiring Puri's popup onto pikuri (its `design/ideas/real-core.md`, `Q_early_cancel`).

## The race

`Agent#run_loop` called `@cancellable&.reset!` first thing, so a stale cancel couldn't poison
the next turn. But whoever starts a turn decides it has started *before* that line runs on the
agent's thread, and allows a cancel from then on:

```
UI thread:    Return → running = true → Thread.new/executor.post ……… Escape → cancel!
agent thread:                                   …scheduling, queue wait…   run_loop → reset! (the cancel is gone)
```

`run_loop` cannot tell a stale cancel (left over from the last turn) from an early one (meant
for this turn). The reset has to happen where the host starts accepting cancels for the turn —
on the host's thread, under the lock guarding its "running" flag — not merely "just before
`run_loop`" on the worker, which is the same moment as before.

Who had the window:

- **pikuri itself, in sub-agents.** `SubAgentTool` hands the child the parent's own
  `Cancellable` and calls `sub.run_loop`, whose `reset!` cleared the shared token. A Ctrl+C
  after the `agent` call's `before_tool_call` check — while the delegation confirm prompt
  waits on the human, or while the child is built — was lost for the whole tree.
- pikuri-web `Runner`: `claim_running` sets `:running` under `@lock` on the pool thread; a
  cancel between that lock's release and `run_loop`'s `reset!` was lost. (`:queued` was
  already covered by `@abandon`.)
- pikuri-tui `AgentSession`: `@turn_in_progress` is set on the UI thread before the turn's
  thread starts.
- Puri: Escape reaches the `Turn` the moment Return made it; its thread runs at priority −3.
  Puri's new spec fails against the old pikuri every time.
- The `bin/` scripts trap SIGINT just before `run_loop`.

## What is implemented: fix 1, the host owns the reset

- `run_loop` no longer calls `reset!`. `clear_conversation` still does.
- `run_loop` calls `check!` once the user turn is recorded (after the cap probe, before the
  extension dispatch and the first request). The permit can't serve as that check: an unsized
  server has unlimited permits, and `Semaphore#acquire` then skips the check, so a plain
  non-streaming turn had no cancellation point at all. The user message stays in the history,
  unanswered, as after a cancel during the prefill.
- Each caller resets where it starts a turn:
  - pikuri-tui `start_turn`, on the UI thread before `Thread.new`;
  - pikuri-web `claim_running`, under `@lock`, when it goes `:running` (the `finish_turn`
    resume path goes through it too);
  - Puri `AgentSession#call`, under the conversation's lock, before the `Turn` exists;
  - every `bin/` script that wires a `Cancellable`, before installing its SIGINT trap: pikuri's
    `pikuri-chat`, `pikuri-secretary`, `pikuri-minions`, `pikuri-briefing`,
    `pikuri-thunderbird`, `pikuri-corpus`, `pikuri-files`; pikuri-workshop's `pikuri-code`,
    `pikuri-os`, `pikuri-computer`, `pikuri-openlibrary` (the last two lost their post-boot
    reset, now redundant);
  - `SubAgentTool`: nothing — the child shares the parent's token, which the parent's host
    reset.
- Specs: core (unit, and end to end through `Pikuri::Testing` with no request served),
  pikuri-subagents (a cancel during the confirm prompt survives the child), and one per host.

Left as-is: a cancel that lands after a turn's last `check!` (a non-streaming final answer, or
between `run_loop` returning and the host going idle) is ignored, and the next reset clears it.

## Alternatives turned down

- **`reset!` at the end of a turn** only moves the race: a cancel landing between `run_loop`'s
  return and the host marking itself idle would poison the next turn.
- **`run_loop(…, reset_cancellable: true)`, opt-in.** Non-breaking, but both a host that owns
  the reset *and* `SubAgentTool` must pass `false`: the default is wrong for pikuri's own
  caller, and for every host that runs the turn on another thread.
- **`run_loop` creates a fresh `Cancellable`.** Doesn't fix the race: the host needs the token
  before the worker reaches `run_loop`, and one born inside `run_loop` is born after the early
  cancel.
- **A token per turn, `run_loop(…, cancellable:)`**, one-shot like .NET's `CancellationToken`.
  The cleanest model — no reset at all — but six places capture the agent's token at
  construction and would have to read the current turn's instead: `Tool::ExecuteContext`
  (once per agent in `run_configure`), the `RequestThrottle` in `build_context`,
  `SubAgentTool` (`parent.cancellable`), and in pikuri-workshop `pikuri-lsp`'s extension and
  `pikuri-mcp`'s `Synthesizer`/`Verifier` (`c.cancellable`). Forgetting a fresh token is no
  louder than forgetting the reset: both make every turn after a cancel end at once.
- **A single-use `Looper`/`Turn` object** — the per-turn token plus a wrapper around
  `run_loop`'s arguments; hosts would wrap it in their own turn (Puri's `Turn`, pikuri-web's
  `Runner` states).
- **A per-turn context holding `cancel`, agent state and the interloper.** The interloper
  outlives a turn: a UI-loaded skill injected while idle lands at the next turn's start, and
  pikuri-web's `finish_turn` starts a turn for injections that arrived after the last tool
  batch. Agent state is the listener stream's job, and each host keeps its own running flag.
- **Renaming `reset!` to `arm!`** — "arm" next to "cancel" reads as setting it off.

## Open: an API a host can't get wrong

Fix 1's weak spot is that a host has to remember the reset, and in the right place. To
brainstorm next.

## Done when

- The open question is settled (or dropped) and the implementation committed in pikuri,
  pikuri-workshop, pikuri-tui, pikuri-web and Puri.
- The lasting nuggets move out: the "only the host knows the turn boundary" rule and the
  turned-down alternatives into a `D_` entry, then this file is deleted.
