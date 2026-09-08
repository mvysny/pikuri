# Hosting many agents at once

Every binary in this book so far has run exactly one agent at a
time. You type, it thinks, it prints, you type again. `pikuri-chat`
reads stdin synchronously; even the sub-agents chapter, which
*looks* like the exception, isn't one — a boss that emits three
`agent` tool calls runs them one after another, because ruby_llm
executes a tool batch sequentially and pikuri depends on that.

Real hosts don't work that way. Put pikuri behind a web UI and the
shape inverts: several people (or several browser tabs belonging to
one person) hold live conversations at the same time, and the
process has to serve all of them. On top of that sit small
housekeeping jobs nobody asked for explicitly — summarize this
question so the sidebar has a caption, title that conversation now
that it has three turns. Those fire on their own schedule, mixed in
with the interactive work.

That is [pikuri-web](https://codeberg.org/mvysny/pikuri-web), and
it's the reason several conventions in this book exist. This
chapter is about what changes when N agents share one process. It
ships no demo: the honest version of "here is a multi-agent host"
is a few hundred lines of conversation registry, session
bookkeeping and transport plumbing, and at that size the lesson
drowns. The snippets below are sketches — `# ...` wherever the
detail is a host's business rather than pikuri's. If you want to
see it working, read pikuri-web's sources.

We also assume the concurrency arrives somehow. Threads from a web
server's pool, an actor mailbox, a job queue — doesn't matter. The
question this chapter answers starts one step later: *given* that
two turns want to run right now, what breaks?

## Two shapes, not one

It's tempting to think of a multi-agent host as "the single-agent
case, times N". It isn't, because two quite different kinds of
agent live in it.

**Session agents** are long-lived. One per conversation, created
when someone opens a conversation and kept until they leave it.
Tools wired, extensions bound, listeners streaming events out to
that browser tab, a full message history that grows for as long as
the conversation does. This is the agent you already know from
every previous chapter — just several of them.

**One-off agents** are the opposite: created for one question,
handed one user turn, read once, thrown away. No tools (there's
nothing to call), no listeners (nobody's watching), no history
worth keeping. "Caption this conversation" is one of these.

pikuri already ships that second shape, and you've met it without
noticing — `Pikuri::Mcp::Thinker`, which the MCP chapter's
verifier and synthesizer run their boot passes through:

```ruby
def call(prompt)
  @cancellable&.check!
  agent = Pikuri::Agent.new(transport: @transport, system_prompt: SYSTEM_PROMPT)
  begin
    agent.run_loop(user_message: prompt)
    agent.last_assistant_content.to_s
  ensure
    agent.close
  end
end
```

That's the whole pattern: fresh agent, same transport as its
parent, one turn, `close` in an `ensure`. A caption job is this
with a different prompt. Note what it *doesn't* have — no
`ExtensionContext`, no persona, no `Agent.new` block at all. A
one-off agent with tools is usually a design mistake; if it needs
tools it's a sub-agent, and that's the [sub-agents
chapter](subagents.md)'s subject.

Most of what follows is a consequence of these two coexisting.
Twenty session agents mostly idle (people read slowly) while
caption jobs fire in bursts is a very different load than twenty
agents all thinking at once, and it's the realistic one.

## `Agent` is thread-unsafe, on purpose

Start with the blunt fact, because everything else is downstream of
it. `Pikuri::Agent` is thread-unsafe, and that is the entire
guarantee — deliberately no stronger. The chat object, the
message-identity map, the `on_close` list are plain unguarded
state, and `run_loop` is not re-entrant. A second thread calling
into a mid-turn agent corrupts the conversation rather than raising
something you could catch.

The contract that falls out is *one thread per agent*:

```ruby
agents.map { |a| Thread.new { a.run_loop(user_message: task_for(a)) } }.each(&:join)
```

Two things about that are worth spelling out, because hosts get
them wrong in opposite directions.

**Nothing is thread-*confined*.** An agent may be driven from a
different thread on each turn — a web server's pool hands you
whichever worker is free, and that's fine. What's forbidden is
*two at once*. So never key anything about an agent off
`Thread.current`: the thread that ran turn 4 is very likely gone by
turn 5.

**There are exactly two sanctioned doors in from another thread**,
and they're the ones that carry locks while the agent doesn't:

- `Control::Cancellable` — stop the turn. The browser's stop
  button. Flip the flag from any thread; the agent notices at its
  next checkpoint and unwinds.
- `Control::Interloper` — queue a message for an agent that's
  already running. The user typing again mid-turn. Delivered at the
  end of a tool batch, the only point where conversation state is
  consistent.

Every other method needs the host's own serialization. If you want
to inspect a running conversation, you don't reach into the agent —
you read the event stream it's already emitting, which we get to at
the end of the chapter.

The `bin/` demos wire neither control, and that's exactly the
"simple on purpose" caveat: their stdin is synchronous, so there's
no other thread to inject from. A host running the agent on a
worker wires an `Interloper` in with no other changes.

## One server, N agents

Here's the problem that motivated most of this chapter.

Your twenty session agents point at *one* llama.cpp. Your caption
jobs point at the same one. Nothing in what we've built so far
stops all of them issuing completions simultaneously — and
llama.cpp, started with `--parallel 1`, does not fall over. It
queues.

That queueing is the problem, not the fix. Three things go wrong
once a request is sitting in the server's queue rather than in
yours:

- **ruby_llm's `request_timeout` is ticking.** It doesn't know the
  difference between "the server is slow" and "the server hasn't
  looked at my request yet."
- **A timeout on POST gets retried.** So the client re-enqueues
  work *behind* an original that may still be generating. The
  stampede feeds itself.
- **You can't cancel it.** A request parked inside llama.cpp is
  beyond the reach of your stop button. It will be served, the
  tokens will be generated, and the user who pressed stop thirty
  seconds ago will pay for them.

Parked in *your* queue, all three are fixable. That's
`Pikuri::Agent::ServerPermits`: a permit you must hold to have a
request in flight, and a request waiting for one is waiting
somewhere you control.

```ruby
Permits = Pikuri::Agent::ServerPermits

Permits.limit('http://localhost:8080', 1)       # llama-server --parallel 1
Permits.limit('https://api.openai.com/v1', nil) # nil = unlimited
```

Two things about the scope, both of which are the point rather than
an implementation detail.

**The key is the server, not the agent.** One process-wide
registry, keyed by the normalized base URL. Twenty agents pointing
at the same URL share its permits; there's deliberately no
per-agent pool to construct and thread through your host. This is
the same rule as the web-search rate limiter from the earlier
chapters — what you're protecting is one inference server's slots,
and that is not a property of any agent talking to it. A per-agent
limiter would let twenty agents fire twenty simultaneous requests
and change nothing about how many arrive.

**A permit covers one HTTP request, not one turn.** This one is
load-bearing. A turn is inference *plus* tools, so a turn that
spends five seconds in `web_search` would hold a slot while the
server idles. Worse, a whole-turn permit deadlocks the moment a
parent's tool spawns a sub-agent: the parent holds the only permit
and waits for a child that's waiting for a permit. Per-request
avoids both. The permit is taken around ruby_llm's
`request.ruby_llm` instrumenter event, and it's held for the whole
streamed response — measured, not assumed, because releasing at the
first byte would gate nothing at all.

Mostly you configure none of this. The `/props` probe pikuri
already makes to learn the context window also reports
`total_slots`, and that seeds the permit count, so a default local
llama.cpp throttles correctly with zero configuration. Anything
unprobeable — cloud endpoints, providers with a fixed base — stays
unlimited, which is the right answer there. `limit` is the
override, and it always wins over what the probe found.

Passing an explicit `context_window:` on the transport doesn't
change any of that, and it's worth knowing why, because the
tempting shortcut is a bug. The cap is what the probe was built
for, so stating the cap looks like a reason to skip the probe —
pikuri did skip it, once. But one `/props` document answers *two*
questions, and the second one is `total_slots`, which is a property
of the **server**, not of the model you just sized. Skipping on the
cap meant that stating a number in the model's column silently gave
up the server's.

So the probe is skipped only when both answers are already in hand:
you stated the cap *and* something already sized the server. That
something is this registry, which doubles as the probe's memo. A
`limit` call in your boot code means no probe at all. Four agents
against one llama.cpp probe it once between them rather than four
times. And a sub-agent probes never — it inherits its parent's
resolved cap by construction, and the parent's probe left the
server sized. What's left is the honest cost: a cloud endpoint you
handed a cap to gets one `/props` request per process, which 404s
and degrades to "unlimited". Size it with `limit` and even that
goes away.

Does it matter? Measured against a live llama.cpp router, three
agents running the same prompt:

| Permits | Total | Individual completions |
|---|---|---|
| 1 | 21.3 s | 7.1 / 14.2 / 21.3 s |
| 4 | 9.1 s | all three together |

The server reported `total_slots: 4`, and a zero-configuration
agent auto-sized to it. The staircase in the first row is what
serialization looks like; the second row is what the hardware could
do all along. Neither number is the lesson — the lesson is that
*you* chose which one you got, instead of discovering it inside a
queue you can't see.

And one honest limitation, because a host author will hit it.
Permits are FIFO and undifferentiated: a burst of six caption jobs
will park the next interactive turn behind all six. There is no
priority lane today. If that bites you, the fix is at your layer —
don't dispatch housekeeping work while interactive turns are
pending — not a knob pikuri currently offers.

## Why the connection can't be global

ruby_llm's obvious configuration door is the process-global one:

```ruby
RubyLLM.configure { |c| c.openai_api_base = '...' }   # never, in pikuri
```

In a single-agent CLI you'd never notice the problem. In a host,
it's two users stomping each other. One conversation on a 30B, one
on a 4B, a caption job on whatever's cheapest — a global config has
exactly one `openai_api_base` and one model id, so whichever agent
configured last wins and the others silently talk to the wrong
server with the wrong key.

So a connection rides the agent instead. `ChatTransport` bundles
everything that must travel together for a chat to resolve to the
same model on the same server every time it's built — model id,
provider, base URL, key — and the agent maps it onto its own
per-chat `RubyLLM::Context`:

```ruby
Pikuri::Agent.new(
  transport: Pikuri::Agent::ChatTransport.from_openai_server(
    server: 'http://localhost:8080',
    model:  'qwen3-30b'
  ),
  system_prompt: # ...
) do |c|
  # ... tools, extensions, listeners
end
```

Every chat rides one of these; nothing in pikuri calls
`RubyLLM.chat` bare. That's also where the permit gate gets
installed, which is why the throttle needs no host wiring: the
context that carries your connection carries the instrumenter that
rations it.

The bundle matters for a reason that's easy to miss. `with_model`
swaps only the model against the chat's *existing* connection — so
switching a conversation to a model on a different server, without
the connection travelling along, sends the new model id to the old
server's URL with the old key. In a host where different
conversations legitimately run different models, that's a bug you'd
debug for an afternoon.

## A tool instance two agents can reach

Now the consequence hosts don't see coming.

You build your tools once at boot — one `web_search`, one `fetch`,
one calculator — and hand the same instances to every session
agent. Sensible: they're stateless-looking value objects wrapping a
`Proc`, and building twenty copies of a search cascade would be
silly.

Except some tools *aren't* stateless, and now two agents can be
inside one of them at the same moment. That's the whole reason
every pikuri tool carries a `Sharing:` line in its yardoc naming
one of four postures:

- **`P_stateless`** — no mutable state. Share freely.
- **`P_shared_locked`** — process-wide mutable state under a lock.
  Sharing is *intended*, and for anything pacing a shared external
  resource it's mandatory: a per-agent search rate limiter would
  let twenty agents fire twenty simultaneous requests from one IP
  and earn the ban it exists to avoid.
- **`P_shared_benign`** — unprotected process-wide state whose race
  is harmless, with the race named. The URL cache is the example:
  two callers miss the same cold key and write identical bytes.
- **`P_one_agent`** — agent-scoped state, so exactly one agent. No
  lock needed, because its only caller is an agent whose calls are
  already serialized.

`P_one_agent` is a fine answer, not a defect — most of what a tool
knows is one conversation's business. The task list is the obvious
one: agent A's todos are not agent B's. Wire a `P_one_agent` tool
into two session agents and the first failure isn't even a race,
it's a correctness bug — A reads B's tasks single-threaded too.

So in a host, tool construction splits in two. Build the stateless
and the shared-locked ones once, at boot. Build the per-agent ones
*per agent*, inside that agent's `Agent.new` block, which is where
extensions like `pikuri-tasks` put them anyway:

```ruby
# once, at boot — everything whose posture isn't P_one_agent
SHARED_TOOLS = [
  Pikuri::Tool::CALCULATOR, # P_stateless
  Pikuri::Tool::FETCH,      # P_shared_benign (its URL cache races harmlessly)
  # ...
]

def build_session_agent(conversation)
  Pikuri::Agent.new(transport: TRANSPORT, system_prompt: PROMPT) do |c|
    SHARED_TOOLS.each { |t| c.add_tool t }
    c.add_extension Pikuri::Tasks::Extension.new  # P_one_agent, per agent
    c.add_listener event_pump_for(conversation)
    # ...
  end
end
```

Nothing enforces the split — the doc *is* the contract. Which is
worth knowing in both directions: if you write a tool of your own
for a host like this, the `Sharing:` line is the thing a future
reader has instead of a crash.

The two axes are independent, incidentally. Thread-safe is no
licence to share: a per-agent thing that also happens to hold a
lock is still per-agent.

## A conversation is a thing you store and switch

The last difference is that a host owns conversations as *objects*,
not as a scrollback. Someone closes a tab and comes back tomorrow;
someone switches between two conversations in a sidebar. So a
conversation has to leave the agent and come back.

It leaves as a `Pikuri::Agent::History` — a typed `Data` value that
owns both directions of its own serialization, because an exported
conversation gets written to disk and that makes it a *file
format*, not a return value. No host reads the chat's message list
directly.

What you'll actually run into is that this covers the model-facing
half and only that. Your UI renders the **event stream** —
`Event::ToolCall`, `Event::ToolResult`, and friends — not the
message list, and that rendering is lossy on purpose: tool results
truncated, injected reference blocks collapsed to a one-liner,
token counts rendered as nothing. So the transcript your user sees
cannot be rebuilt from the history, and the history cannot be
rebuilt from the transcript. pikuri-web arrived at this
independently and calls it *the real fork*, which is the right name
for it: they're two artifacts, and the event log is the *shell's*,
because the truncation policy is the shell's.

That's why `Event` is a plain serializable `Data` with no live
`Pikuri::Tool` reference on it — pikuri-web ships events over SSE
to a browser and replays stored ones on reload, and a replayed
conversation has no tool object to point at. Same reason the
display strings a tool composes get *persisted* rather than
recomputed: on reload, the tool that could compose them may not be
wired any more.

The envelope is yours too. Title, timestamps, ordering, which
conversation is open — pikuri has opinions about none of that. It
hands you a history and a stream of events; the product around them
is your design.

## The takeaway

If you're building a host, the short version:

1. **One thread per agent, never two.** Drive it from whatever
   thread you like, one at a time, and don't key anything off
   `Thread.current`.
2. **Two doors in from other threads** — `Cancellable` and
   `Interloper`. Everything else is your serialization problem.
3. **Size your inference server once**, per server, and let the
   `/props` probe do it when it can. Cancellation only works on a
   request queued in *your* process.
4. **Split tool construction** — shared instances at boot,
   `P_one_agent` tools per agent. Read the `Sharing:` line before
   you hoist a tool into a constant.
5. **A connection rides the transport**, never
   `RubyLLM.configure` — different conversations legitimately run
   different models.
6. **Two artifacts, not one** — the history is pikuri's, the
   rendered transcript is yours, and neither reconstructs the
   other.

## What's next

The book closes on [pikuri-assistant](assistant.md), itself still a
stub. Everything in this chapter is also the reading list for
[pikuri-web](https://codeberg.org/mvysny/pikuri-web) itself: it's
the host these conventions were shaped by, and with the vocabulary
you now have — `Agent`, `Tool`, listeners, the Extension protocol,
`ChatTransport`, `History`, the two controls — its sources are a
worked example of every point above.
