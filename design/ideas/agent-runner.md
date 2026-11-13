# `Agent::Runner`: the agent owns its turn queue

Status: **open, direction agreed, not started.** Grew out of `early-cancel.md`: every fix there
moved a burden onto the caller (reset before `run_loop`, hold a turn number, hold a `Turn`).
This one moves the burden into pikuri.

## The problem: `run_loop` is a blocking call with rules attached

`Agent#run_loop` looks simple, but a host must:

- serialize every call — `Agent` is thread-unsafe, "the caller serializes";
- reset the `Cancellable` where *it* decides a turn starts, on its own thread, under the lock
  guarding its "running" flag (`early-cancel.md`);
- route a message sent mid-turn to the `Interloper` instead of a second `run_loop`, and start a
  turn for injections still pending when a turn ends;
- guard `cancel!` with its own "running" flag;
- apply a pending model switch at the top of the next turn, and never mid-turn;
- not call `clear_conversation` / `load_history!` while a turn runs.

Three hosts implement this state machine, each a little differently:

- pikuri-tui `AgentSession`: `@turn_in_progress`, `queue_mid_turn`,
  `deliver_pending_injections`, `interrupt`, the picker's `take_pending`.
- pikuri-web `Runner`: `:idle`/`:queued`/`:running`, `claim_running`, `finish_turn`'s restart
  on pending injections, `@abandon`, `take_pending`, an executor for slots.
- Puri `Conversation`: `@turn` + `@waiting`, `finish` starts the next waiting message, `cancel`
  clears the queue. Queues a second message as its own turn instead of injecting.

Each needed its own early-cancel fix. A well-defined command queue is a simpler abstraction
than an object that places many rules on how it must be called.

## Direction

- **`Agent` becomes a template**: the definition of an agent — system prompt, tools,
  extensions, listeners (?) — ideally immutable.
- **`Agent::Runner` owns everything mutable**: the conversation, the current transport (a model
  switch), the context cap and modalities, the cancel token, the injection queue.
- **The runner is the scheduler.** `submit` returns a future at once; turns of one runner run
  strictly one at a time.

```ruby
turn = runner.submit('how do I keep an avocado?')  # returns at once
turn.cancel     # still queued: withdrawn; running: stops at the next cancellation point
turn.value      # blocks; raises Cancelled / EmptyTurnError / a transport error
runner.submit('also, ripe?')   # while a turn runs: rides it, via the injection queue
runner.run_loop('hi')          # kept: submit, then wait — bin/ scripts, specs
```

- **`submit` while a turn runs injects into it.** A flag for "always queue as a new turn" can
  come later; Puri probably wants injecting too, it just doesn't know it yet.
- **Early cancel is solved by construction.** `cancel` and "a turn leaves the queue" both take
  the runner's lock: a queued turn is withdrawn, a running one trips the token, and the runner
  resets the token itself when it takes the next turn off the queue. No caller resets anything.
- **One shared executor for all runners**, per-runner serialization on top:
  `Concurrent::SerializedExecution#post(executor, &task)` (concurrent-ruby) runs one key's tasks
  in order, never two at once, on any executor. `SerializedExecutionDelegator` wraps a whole
  executor the same way.
- **concurrent-ruby** becomes a pikuri-core runtime dependency: well known, well tested (Rails
  depends on it), preferred over a hand-rolled future we'd own.

What the hosts lose: their turn state machines, `reset!`, the `Interloper` wiring, the
leftover delivery, `take_pending`, the running-flag guard on cancel. What they keep: rendering,
and where a Future's completion is persisted.

## Open questions

- `Q_template_boundary` — what stays on the immutable `Agent` and what moves to the `Runner`.
  Transport/cap/modalities and the conversation move; tools and the system prompt stay.
  Unclear: extensions (`Extension#bind` today binds to an agent and some hold
  conversation-scoped state, reset by `on_conversation_reset`), listeners (pikuri-web attaches
  a per-conversation SSE listener), the `ExtensionContext` capability seam. Can one `Agent`
  back many runners (pikuri-web: one per conversation; sub-agents: a persona as the template)?
  The one to settle first; most of the rest follows from it.
- `Q_idle_commands` — `clear_conversation`, `load_history!`, `export_history`, a model switch:
  queued commands on the same serial queue (each a future), or raise unless idle. A queued
  `export_history` gets a consistent snapshot for free; a per-turn `transport:` fits as a
  `submit` argument.
- `Q_future_type` — `Concurrent::Promises` futures can't be cancelled; the handle `submit`
  returns is likely ours (cancel + state) wrapping a `Promises::ResolvableFuture` for
  `value` / `then` / `on_resolution`.
- `Q_injected_future` — what `submit` returns for a message that rides a running turn. Lean:
  the riding turn's future, so `cancel` always means "stop that turn". A per-message future
  that withdraws an undelivered injection is a new capability.
- `Q_boot_cancel` — the workshop's `pikuri-code` / `pikuri-openlibrary` cancel MCP synthesis
  during `Agent.new`, before any runner exists, via the `Configurator`'s cancellable.
- `Q_bare_turns` — host-scheduled injections while idle (a UI-loaded skill,
  `Interloper#inject_system_message`) and the bare turn that delivers them: a `submit` variant,
  or a command.
- `Q_thread_hopping` — a runner's turns now run on whichever pool thread is free. pikuri already
  forbids keying state off `Thread.current`; check `Subprocess`, `Finalizers`, the LSP client
  and pikuri-web's thread names (`D_puma_thread_dump`) for any thread affinity.

## Settled

- **A sub-agent runs inline on the parent's thread**, as a synchronous call to what is
  `Agent#run_loop` today — never submitted to the executor and waited on. A parent turn that
  waited on a child's future would hold its pool thread while waiting, and enough of them
  deadlock a bounded pool (the turn-scoped-permit lesson again). The child shares the parent's
  cancel token, as today.
- **The executor is unbounded**, a `Concurrent::CachedThreadPool`, as pikuri-web already
  decided (`pikuri-webui:D_serial_turn_executor`): a turn holds its thread for its whole
  length, including waits that aren't load — a `Confirmer` waiting on a human, a long `bash` —
  so any bound strands conversations behind turns using no server slot. The bound on model load
  stays per request, `ServerPermits` (`D_llm_request_throttle`). What each runner needs is
  serialization, not a slot. Likely one process-wide default executor, overridable.
- **`cancel` is a bare field write on the handle**, safe in a SIGINT trap, which can't take a
  `Mutex`. That also retires `reset!`: the runner's cancel token stops being a flag and asks
  the *current* handle instead, `check!` → `raise Cancelled if @current&.cancelled?`. The
  runner sets `@current` as it takes a turn off the queue (skipping one already cancelled) and
  clears it after. An early cancel is on the handle before it runs; a late or stale one sits on
  a handle that is no longer current. Every site that captures the token at construction
  (`RequestThrottle`, `Tool::ExecuteContext`, `SubAgentTool`, the workshop's MCP / LSP) keeps
  calling `check!` on the same object; a child sharing the parent's token sees the parent's
  current handle.

## Constraints already learned downstream

- **The runner never calls out while holding its own lock** — no listener, no completion
  callback, no host code. pikuri-web serializes its state under one global monitor
  (`pikuri-webui:D_global_monitor`) and its listeners take it; calling them under the runner's
  lock invites a lock-order inversion. pikuri-web's `Agents::Runner` already states the rule
  for pikuri's own locks.

## Relation to `early-cancel.md`

What's committed there (each host resets the token where it starts a turn; `run_loop` checks
before its first request) is the interim. The runner replaces the host resets; the `run_loop`
check stays. `early-cancel.md` graduates when the runner lands.

## Done when

- `Agent::Runner` exists, the open questions above are answered, and pikuri-tui, pikuri-web,
  Puri and the `bin/` scripts drive their agents through it, their own turn state machines gone.
- The nuggets land: the template/runner split and the threading model in
  `design/architecture.md`; why a command queue and why the pool is shaped as it is as `D_`
  entries; the "Agent is thread-unsafe, the caller serializes" convention in `AGENTS.md`
  rewritten for the runner. Then this file and `early-cancel.md` are deleted.
