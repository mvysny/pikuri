# Throttling concurrent LLM requests

Status: **proposed, not built.** A working host-side proof exists downstream in
pikuri-web (`ThrottledAdapter`, its `D_throttle_at_the_request`), which is what
makes this concrete rather than speculative — and also what makes it not
urgent. Sequencing note at the bottom.

Brainstormed 2026-09-07 against ruby_llm 1.16.0 and the live llama.cpp
router on `mavi-fw:8080`. The earlier draft's proposed shape (a `Control`
acquired in `run_loop`) turned out to be impossible — see *Where the acquire
goes* — so this is a rewrite, not a refinement.

Related, already in the repo:

- `Agent`'s `== Threading` yardoc — the contract this note extends. It is
  already the right doc; it just stops one question short.
- `Agent#build_context` — the per-transport `RubyLLM::Context` seam. The
  proposed home for the hook.
- `Agent::ContextWindowDetector` — already fetches the `/props` document
  that carries the server's slot count.
- `DECISIONS.md` `D_rate_limiter_scope` — "a limiter is scoped to the
  resource it protects, never to the agent". This note is that rule applied
  to the inference server.

## The gap, in the Agent's own words

`Agent`'s threading section sanctions N concurrent agents outright:

> Several agents in one VM is then the easy case, one thread each:
>
>     agents.map { |a| Thread.new { a.run_loop(user_message: task_for(a)) } }.each(&:join)

True as far as thread-safety goes. But those N agents usually point at **one
llama.cpp**, and nothing in pikuri keeps them from issuing N simultaneous
completions to a server started with `--parallel 1`. The doc answers "will they
corrupt each other?" and never raises "will they stampede the box?".

What the stampede actually costs, since llama.cpp does not fall over — it
queues excess requests server-side:

- ruby_llm's `request_timeout` (300 s) ticks while a request sits in the
  server's queue, not just while it generates. A deep queue turns into
  spurious timeouts.
- ruby_llm's Faraday stack retries `Timeout::Error` on POST. A timed-out
  completion is re-enqueued *behind* the queue while the original may still
  be generating — duplicate work that deepens the queue it timed out in.
- A request parked in the server's queue cannot be cancelled or reprioritized
  from the client. Parked in our queue, it can.
- Other servers differ: Ollama answers 503 above its queue cap, cloud
  endpoints don't care. Permits are per server precisely so the answer can be
  "unlimited" for the ones that don't mind.

A host can only ration this from outside, and the obvious lever is wrong. Cap
concurrency at the *turn* level — a worker pool sized to the server's slots —
and you over-restrict, because a turn is not only inference: it also runs
tools. A turn spending five seconds in `web_search` holds its slot while the
server sits idle, and at one slot nothing else may talk to the server at all.

**pikuri-tui is untouched by this** — one agent, one turn at a time, no
contention. This is a multi-agent-host problem, which is exactly the case the
yardoc above invites people into.

## What downstream proved

pikuri-web holds a permit for the length of one HTTP completion, via a
Faraday adapter injected through `ChatTransport#faraday_adapter`. Four identical
completions against a local llama.cpp:

| permits | total | completions land at |
|---|---|---|
| 1 | 46.6 s | 11.6, 23.2, 34.9, 46.6 s |
| 4 | 26.0 s | 25.9, 26.0, 26.0, 26.0 s |

Evenly staggered at one, simultaneous at four. So the mechanism works and the
granularity is right; the question is only where it belongs.

Two findings from that work that carry over regardless of where it lands:

- **A permit must span the whole streamed response.** If it were released at the
  first byte it would gate nothing. Verified: `ruby_llm` streams through
  Faraday's `on_data`, which net_http drives from inside the request, so the
  adapter's `#call` spans the generation. On a 150-line streamed completion the
  call spanned 33.69 s, `run_loop` totalled 33.69 s, and all 491 delta events
  landed inside the window. Probe: `ideas/llm-request-throttle/stream_probe.rb`.
- **The scope must be exactly one HTTP request.** See the deadlock below.

## Where the acquire goes — three candidates

### 1. A `Control` in `run_loop` around `@chat.complete` — dead

The earlier draft's proposal, and it cannot be built. `Chat#complete` is
ruby_llm's *whole* loop: `complete_once` → `handle_tool_calls` → `complete`,
recursively, tools included. pikuri's two `@chat.complete` call sites in
`run_loop` bracket a turn, not a completion, and the callbacks ruby_llm
exposes (`on_new_message` fires *after* a sync response arrives;
`before_tool_call` / `after_tool_result` bracket tools, not requests) give no
way to bracket one request from outside. A permit held across
`@chat.complete` is a whole-turn permit — exactly the over-restriction of the
turn pool, plus the deadlock:

- `Synthesizer.run_synthesizer` fires from the `StepLimit::Exceeded` rescue,
  building a nested `Agent` that needs a permit of its own.
- A tool that spawns a sub-agent runs inside tool execution, inside
  `@chat.complete`.

A parent holding the only permit waits forever on a child that needs one. Both
are safe *only* because the parent holds nothing while a tool runs — so the
acquire has to live where an HTTP request is the only thing in scope.

### 2. A Faraday adapter — works, but the wrong slot

What downstream ships. It works because an HTTP request *is* one completion,
so there is nowhere to hoist the acquire to. Against it:

- It subclasses `Faraday::Adapter::NetHttp`, so it couples the throttle to
  the adapter choice, and it rests on middleware order (`:json` before the
  adapter) that nothing documents.
- `ChatTransport#faraday_adapter` is a single-occupancy slot, and
  `Pikuri::Testing.fake_transport` already occupies it with the scripted fake.
  A throttled agent cannot be run against the fake, and the throttle cannot be
  tested through the normal harness — you would have to stack two adapters.
- It cannot see `Cancellable`: a request parked on a permit acquires, then
  finds the turn dead.

### 3. ruby_llm's instrumenter — recommended

ruby_llm has a documented public option, `config.instrumenter`
(rubyllm.com/instrumentation), an `ActiveSupport::Notifications`-shaped
object:

```ruby
def instrument(name, payload)   # must yield and return the block's result
  yield if block_given?
end
```

`Connection#post` and `#get` emit `request.ruby_llm` around the *entire*
Faraday call — the retry middleware runs inside it, and so does streaming
(`on_data` is driven from inside the post, the same property the adapter probe
measured, because the adapter sits inside that post). Payload: `provider`
slug, `method`, `url` (path, relative to the base), `status` on the way out.
The option lives on the config, so `RubyLLM.context { |c| c.instrumenter = … }`
makes it per-transport — the `build_context` seam pikuri already owns, with
the process-global `RubyLLM.config` untouched (the Connection seam holds).

Everything the adapter approach needed, from a documented hook, without
occupying the adapter slot. The block is exactly one HTTP request, so the
deadlock above is structurally impossible rather than guarded against.

Honest caveat, to be written into the yardoc: blocking inside an
*instrumentation* hook is a semantic stretch — the name says "observe", and we
"gate". But the contract ruby_llm documents is "yield and return the block's
result", which is all a gate needs, and it is the one before/after hook the
library offers. Every event other than `request.ruby_llm` (`chat.ruby_llm`,
`tool_call.ruby_llm`, …) is yielded through untouched.

Verify before building (a variant of `stream_probe.rb`, instrumenter instead
of adapter): the `request.ruby_llm` block spans every delta event; a forced
retry happens *inside* the block; `chat.ruby_llm` arrives and passes through.

## Where the permits live — per server, process-wide

Two shapes were on the table: a process-wide registry, or a `ServerPermits`
instance a host builds and hands to `Agent.new`. The registry wins, and not on
taste:

- **The resource is the server, not the agent.** `D_rate_limiter_scope` is
  already the house rule — "a limiter's scope must match the resource it
  protects, never the agent" is in CLAUDE.md's Conventions. A ctor-injected
  instance is scoped to an agent *tree*: two independently constructed agents
  (a web host's two sessions, say) each holding their own permits object
  hammer the server exactly as before. It is the same rejected alternative
  as "a limiter per agent" in that entry — not a tuning choice, a defeat of
  the mechanism.
- **Forwarding.** `Synthesizer` and `SubAgentTool` both build
  `Agent.new(transport: parent.transport.with(...))`. A ctor argument is one
  more field every forwarding site can silently drop — the failure mode
  `ChatTransport` was invented to close. A registry has nothing to forward.
- **Not a `ChatTransport` field.** It is per-server *state*, not per-model
  data; and a semaphore inside a `Data` breaks the structural equality hosts
  use to detect a no-op model pick.

So: one module-level registry (working name `Pikuri::Agent::ServerPermits`;
`LlmPermits` is the other candidate), keyed by the normalized server base —
the same normalization `ChatTransport.from_openai_server` applies (strip a
trailing `/` and `/v1`), so `http://x:8080`, `http://x:8080/v1` and
`http://x:8080/v1/` are one server. Value: a counting semaphore, or
`UNLIMITED` for any server nobody has sized (the cloud default). Host API,
roughly:

```ruby
Pikuri::Agent::ServerPermits.limit('http://localhost:8080', 1)  # explicit, wins
Pikuri::Agent::ServerPermits.reset!                             # specs
```

Key resolution at `build_context` time:
`transport.api_base || RubyLLM.config.public_send("#{provider}_api_base")`;
`nil` (a provider with a fixed base, e.g. Anthropic) → unlimited, which is the
right answer for every such provider.

Consequence: `build_chat` always goes through a `Context` — the
`RubyLLM.chat` global-path branch goes away (a no-override transport already
yields a plain config dup). That also lifts the documented caveat that
`faraday_adapter` is honoured only on the override path.

## Default sizing from `/props` `total_slots`

Measured 2026-09-07 on `mavi-fw:8080`: the bare `/props` is a llama.cpp
router (`role: router`, `max_instances: 4`, no slot count);
`/props?model=<id>` for a served model answers `total_slots: 4` beside
`default_generation_settings.n_ctx: 16384`. Those are exactly the two
documents `ContextWindowDetector` already fetches and follows.

So the probe returns the slot count alongside the cap, and
`detect_and_emit_context_cap!` seeds `ServerPermits.default(base, slots)`.
Rules: a host-set `limit` always wins; a default never overrides a default
already seeded (first probe wins). Result: a host that configures nothing gets
the correct throttle against the default local llama.cpp — pikuri's "no config
for a first chat" — and unlimited everywhere the probe finds nothing (cloud).

Known imprecisions, all acceptable for a *default*:

- A router serving two models with different slot counts: first probe wins,
  though the shared resource is really the GPU. A host that cares sets it.
- An explicit `context_window:` on the transport skips the probe, so no
  auto-size. Such a host is configuring anyway; document it next to the
  `context_window` attribute.

## Waiting: cancellable, slice-polled

The acquire closure is built in `build_context`, so it closes over the agent's
`@cancellable`. The semaphore waits on a `Mutex` + `ConditionVariable` with a
`SLICE_SECONDS` timeout and calls `cancellable.check!` on each wake — the same
polling design and the same reason as `Cancellable#sleep`: `cancel!` must stay
a bare flag write callable from a SIGINT trap, so it can signal no CV, and the
waiting side pays. `Cancelled` raised inside the instrumenter block propagates
out of `Chat#complete` before any request left; the batch it strands is the
one `repair_dangling_tool_calls!` already answers. Release uses `broadcast`
(a `signal` could wake a waiter that is about to cancel and leave the permit
stranded); wake-ups are cheap at these rates.

Dependency: hand-rolled, ~30 lines on stdlib. pikuri is `Mutex` throughout
and `concurrent-ruby` stays downstream's.

Fairness: none guaranteed in v1 — a broadcast-and-recheck loop is not FIFO,
and downstream accepted the same from `Concurrent::Semaphore`. Decided rather
than inherited: priority (a user-facing turn jumping background work) needs a
ticket queue anyway, and that is the moment to build ordering, not before.

## What does and does not take a permit

- **Everything through the ruby_llm connection does** — chat completions,
  the `list_models` GET, embeddings. Simpler than path-matching (downstream
  matched `/chat/completions`; drop that), a GET queueing briefly behind a
  generation is harmless, and an embedding on a llama.cpp *does* occupy a slot.
- **The `/props` probe does not**, by construction: `ContextWindowDetector`
  uses its own Faraday, outside ruby_llm and so outside the instrumenter. It
  must not — it is what sizes the permits.
- `bin/pikuri-corpus`'s `RubyLLM.embed` runs outside any `Agent` on the
  global config, so it stays unthrottled, as today. (A `bin/` shortcut, not
  policy.)

## Testing

The instrumenter and the scripted fake adapter coexist, so a spec runs N
agents against a `Testing::Gate`-held `fake_transport` under `limit(base, k)`
and asserts in-flight ≤ k while the gate holds — the test the adapter approach
could not write. Plus the deadlock invariant, because it is precisely what a
later "why not acquire once per turn?" tidy-up would break: under `limit 1`, a
parent whose tool spawns a sub-agent, and a parent that trips `StepLimit` into
`:synthesize`, both complete.

## Still open

- **Name**: `Agent::ServerPermits` vs `Pikuri::LlmPermits`.
- **Priority** — deferred to a real need (downstream's conversation-titler is
  the live candidate). The acquire site is where it would go.
- **Instrumenter chaining** for a host with its own (`ActiveSupport::Notifications`).
  Not until asked; a `next:` field is the obvious shape.
- **Machine-wide** (two pikuri processes on one server) — out, same reasoning
  as `D_rate_limiter_scope`.

## Implementation notes (2026-09-08, pre-hand-off review)

Decided: instrumenter, not adapter. Re-verified against the installed
ruby_llm 1.16.0 source (`connection.rb`, `instrumentation.rb`,
`configuration.rb`): `option :instrumenter, nil` exists; `Connection#post` /
`#get` wrap the *entire* `@connection.post` in `request.ruby_llm` and pass the
connection's own config to `RubyLLM.instrument`, so a `RubyLLM.context`
config's instrumenter is per-transport with the global config untouched. The
Faraday retry middleware runs *inside* the block. Everything §3 claims holds.

Points that are not in the sections above and must not be lost:

- **Chain the inherited instrumenter in v1, not "when asked".**
  `RubyLLM.context` dups the global config, so a Rails host that set
  `ActiveSupport::Notifications` as `RubyLLM.config.instrumenter` has it
  *silently clobbered* the moment `build_context` overwrites the slot. Capture
  `c.instrumenter` before assigning and delegate every event to it (the gate
  wraps `request.ruby_llm`, everything else is a plain pass-through to the
  captured one, or a bare `yield` when there is none). A few lines; turns a
  silent breakage into a non-issue. Strike the *Still open* bullet.
- **Match `request.ruby_llm` only.** `chat.ruby_llm` and `tool_call.ruby_llm`
  arrive through the same object; yield them untouched. `tool_call.ruby_llm`
  is the payload `Agent`'s `@pending_tool_call` comment already names as the
  future fix for `tool_concurrency` — don't foreclose it.
- **A held permit idles the slot during retry backoff.** ruby_llm sleeps
  `retry_interval` × backoff between retries *inside* the block, permit held.
  That is the intended behaviour (the alternative — release across retries —
  re-creates the duplicate-work problem the *gap* section describes). Say so in
  the yardoc so nobody later "optimizes" it.
- **Wait slice: reuse `Cancellable::SLICE_SECONDS` (0.1 s)**, not a new
  constant and not a one-second poll — Ctrl-C responsiveness is why the slice
  exists. Waiting is `Mutex` + `ConditionVariable#wait(mutex, SLICE)` then
  `cancellable.check!`, per the *Waiting* section.
- **`build_chat` always through a Context; `apply_transport!` stays as is.**
  `apply_transport!` already rebuilds the context whenever *either* the old or
  the new transport overrides the connection, so a switch between two servers
  gets the new server's permit key. The only skipped case is
  no-override → no-override, which is the same global server and the same
  key. The one change is `build_chat`'s `RubyLLM.chat` branch, which must go
  so the initial chat carries the instrumenter too.
- **Stale comment to fix:** `Pikuri::Testing.fake_transport` says the override
  path is "the only branch that honours faraday_adapter". With the global-chat
  branch gone that caveat is false; delete it there and in
  `ChatTransport#faraday_adapter`'s attribute doc.
- **`ContextWindowDetector` return shape.** It returns `Integer | nil` today
  (`n_ctx`). It needs to hand back `total_slots` too — a small `Data.define`
  result (`n_ctx:`, `total_slots:`) is the obvious shape; both fields
  optional, since the router's bare `/props` has neither and a non-llama
  server has no `/props` at all. `detect_and_emit_context_cap!` is the one
  call site (called from `initialize` and `apply_transport!`).
- **Verification order.** Before the semaphore: the instrumenter variant of
  `ideas/llm-request-throttle/stream_probe.rb` (block spans every delta;
  forced retry inside the block; `chat.ruby_llm` passes through). Then the
  fake-transport concurrency spec and the two deadlock specs from *Testing*.
- **Docs on landing** (per CLAUDE.md's graduation rules): the *why-not-adapter,
  why-not-Control* forks → a `D_llm_request_throttle` entry in `DECISIONS.md`
  (cite `D_rate_limiter_scope`); the instrumenter-as-gate caveat and the
  retry-backoff note → the new class's yardoc; a one-line Seam entry in
  CLAUDE.md ("every request through a ruby_llm connection takes a permit; the
  `/props` probe never does") with a `T_` tripwire only if something is
  mechanically checkable; the `Agent` `== Threading` yardoc gets the missing
  sentence about the server; one CHANGELOG `Add` line. Then delete this note.

## Sequencing

Not urgent: pikuri-web is unblocked and running on the adapter. When this
lands, downstream retires `ThrottledAdapter`, marks `D_throttle_at_the_request`
superseded, and its `ModelCatalog.from_llms(permits:)` becomes
`ServerPermits.limit` calls — so whoever does this should tell that repo.
