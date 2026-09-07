# Throttling concurrent LLM requests

Status: **proposed, not built.** A working host-side proof exists downstream in
pikuri-web (`ThrottledAdapter`, its `D_throttle_at_the_request`), which is what
makes this concrete rather than speculative — and also what makes it not
urgent. Sequencing note at the bottom.

Related, already in the repo:

- `Agent`'s `== Threading` yardoc — the contract this note extends. It is
  already the right doc; it just stops one question short.
- `Agent::Control` — `StepLimit`, `Cancellable`, `Interloper`. The proposed
  home.

## The gap, in the Agent's own words

`Agent`'s threading section sanctions N concurrent agents outright:

> Several agents in one VM is then the easy case, one thread each:
>
>     agents.map { |a| Thread.new { a.run_loop(user_message: task_for(a)) } }.each(&:join)

True as far as thread-safety goes. But those N agents usually point at **one
llama.cpp**, and nothing in pikuri keeps them from issuing N simultaneous
completions to a server started with `--parallel 1`. The doc answers "will they
corrupt each other?" and never raises "will they stampede the box?".

A host can only ration this from outside, and the obvious lever is wrong. Cap
concurrency at the *turn* level — a worker pool sized to the server's slots —
and you over-restrict, because a turn is not only inference: it also runs
tools. A turn spending five seconds in `web_search` holds its slot while the
server sits idle, and at one slot nothing else may talk to the server at all.

**pikuri-tui is untouched by this** — one agent, one turn at a time, no
contention. This is a multi-agent-host problem, which is exactly the case the
yardoc above invites people into.

## What downstream proved

pikuri-web now holds a permit for the length of one HTTP completion, via a
Faraday adapter injected through `ChatTransport#faraday_adapter`. Four identical
completions against a local llama.cpp:

| permits | total | completions land at |
|---|---|---|
| 1 | 46.6 s | 11.6, 23.2, 34.9, 46.6 s |
| 4 | 26.0 s | 25.9, 26.0, 26.0, 26.0 s |

Evenly staggered at one, simultaneous at four. So the mechanism works and the
granularity is right; the question is only whether it belongs in a host.

Two findings from that work that carry over regardless of where it lands:

- **A permit must span the whole streamed response.** If it were released at the
  first byte it would gate nothing. Verified: `ruby_llm` streams through
  Faraday's `on_data`, which net_http drives from inside the request, so the
  adapter's `#call` spans the generation. On a 150-line streamed completion the
  call spanned 33.69 s, `run_loop` totalled 33.69 s, and all 491 delta events
  landed inside the window. Probe: `ideas/llm-request-throttle/stream_probe.rb`.
- **The scope must be exactly one completion.** See the deadlock below.

## Proposed shape

A `Control::Throttle`, shared by reference, acquired around the two completion
call sites in `run_loop` and nowhere wider.

The family already fits it better than I expected. `Control`'s own yardoc says
the controls are "the sanctioned doors *in* from another thread, **which is why
they carry locks and the agent does not**", and `Cancellable` is already
documented as shared by reference across parent, sub-agents and synthesizer. So
a deliberately-shared, lock-carrying control is the established pattern, not a
new shape.

One way it does break the family's mould, and the doc would have to say so:
every existing control is *read* at a fixed point — a flag, a counter, a queue.
This one **blocks**, potentially for minutes.

### The deadlock this must not acquire its way into

A permit has to cover one completion and nothing larger. Widen it to a step, or
to a whole `run_loop`, and a parent holding the only permit waits forever on a
child that needs one:

- `Synthesizer.run_synthesizer` fires from the `StepLimit::Exceeded` rescue —
  outside the parent's completion.
- A tool that spawns a sub-agent runs during tool execution — also outside.

Both are safe *only* because the parent is not holding a permit at that moment.
This wants a test, because it is precisely the invariant a later "why acquire in
a loop?" tidy-up would break. Note the downstream adapter gets it for free —
an HTTP request *is* one completion, so there is nowhere to hoist the acquire
to — and an in-loop control gives that safety up in exchange for everything
below.

## Why bother, given the host-side version works

- **It rests on `ruby_llm` internals.** Middleware order (`:json` before the
  adapter) and net_http driving `on_data` from inside the request. Both verified,
  neither documented as a contract.
- **Interruptible waiting.** An adapter cannot see `Cancellable`, so a request
  parked on a permit cannot be cancelled — it acquires, then finds the turn
  dead. Small today, because cancellation is a tool-boundary stop that does not
  interrupt a completion either. It stops being small if cancellation ever gets
  finer, and a control sits exactly where both signals are already in scope.
- **Priority.** No way to let a user-facing turn jump a queue of background
  work. Wanted the moment a host issues many small requests beside real ones
  (downstream's conversation-titler idea is the live example).
- **Every host reimplements it otherwise**, and each one has to rediscover the
  streaming property and the scope invariant above.

## Open questions

- **Where the throttle rides, given a mid-life model switch.** `run_loop`'s
  `transport:` can move an agent to another server, and permits belong to the
  *server*. A throttle injected at construction is then silently wrong. Either
  it rides on `ChatTransport` (which already carries `faraday_adapter`, so a
  non-data field is not unprecedented) or the agent resolves one per call. The
  transport option has a snag: it is a `Data`, and hosts compare two of them to
  decide whether a model pick is a no-op, so a semaphore identity inside it
  changes equality.
- **The dependency.** pikuri is stdlib `Mutex` throughout; `concurrent-ruby` is
  downstream's dependency, not ours. A counting semaphore is ~20 lines on
  `Mutex` + `ConditionVariable` — almost certainly hand-roll rather than take
  the gem for this.
- **Fairness.** `Concurrent::Semaphore` guarantees none, and downstream accepted
  that. Worth deciding deliberately here rather than inheriting it.
- **Does anything else deserve a permit?** `ContextWindowDetector`'s `/props`
  probe hits the same server; it is trivial and not inference, so presumably
  not, but the answer should be written down rather than implied.
- **Is a `Control` even right, or is this a transport concern?** The throttle is
  per *server*, and `Control`s are per *agent*. That tension is the real design
  question and the two bullets above are both symptoms of it.

## Sequencing

Not urgent: pikuri-web is unblocked and running on the adapter. The reasons to
build it are the four above, none of which is on fire. When it lands, downstream
retires `ThrottledAdapter` and marks `D_throttle_at_the_request` superseded — so
whoever does this should tell that repo.
