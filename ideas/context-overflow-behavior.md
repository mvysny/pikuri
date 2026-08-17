# What should happen when the context window fills up?

Status: **draft, deliberately unbrainstormed.** Placeholder for a session
of its own. This file frames the question and records the grounded
starting state; the strategies below are a bare agenda, not yet arguments.

[`context-budget.md`](context-budget.md) — whether to tell the *model*
how much context it has spent — is **blocked on this note**, because how
gracefully a host recovers from overflow sets the entire value of warning
the model in advance.


## Current state (grounded, 2026-08-15)

`RubyLLM::ContextLengthExceededError` is rescued in **10** `bin/` scripts
(chat, code, os, computer, memory, assistant, minions, corpus,
thunderbird, openlibrary) with a byte-identical four-line block:

```ruby
rescue RubyLLM::ContextLengthExceededError => e
  warn "\nContext window exhausted: #{e.message}"
  warn 'The conversation has grown too large for the model. Start a fresh question.'
  exit 1
```

Two things worth knowing before designing anything:

- **Nothing is summarized.** The conversation is lost as-is. (Easy to
  misremember otherwise — see the next point.)
- **A summarizer already exists**, for the *neighbouring* case:
  {Pikuri::Agent::Synthesizer}, a nested tools-free `Agent` used by
  `Control::StepLimit`'s `on_exhausted: :synthesize` policy. So
  "summarize, then exit" is closer to shipping than it looks, and may
  reduce to reusing that machinery on a second trigger.
- Nothing in `lib/` handles overflow at all — it propagates out of
  `run_loop` to whoever called it.

Per CLAUDE.md (Layout), the `exit 1` is a *demo script's* deliberate
simplicity and must not be read as pikuri's policy. But 10 identical
copies of it means the moment there is a policy, there's a question of
whether it belongs in a shared place.


## The operator-discipline counter-thesis (2026-08-15)

Raised by the author, and it reframes the whole note: **a sensible
operator watches the context size and ends the session before it matters,
and may therefore never need compaction at all.** Reported practice — in
years of daily agent use, context compression has never once been needed;
the session ends and the idea file gets updated instead.

The conclusion largely survives scrutiny. The stated *mechanism* does
not, and the difference changes what pikuri should build.

### There is no 60% knee — the curve is in absolute tokens

A percentage of the window is the wrong unit. 60% of a 32k window is 19k
tokens; 60% of a 1M window is 600k. Those are not the same machine state,
and nothing in the model knows its own percentage. Everything that
degrades tracks the *absolute* count:

- **Cost.** Every step resends the whole conversation, so per-step input
  tokens equal the context size — linear from the first token, no knee. A
  20-step tool loop at 100k is 2M input tokens. Prompt caching cuts the
  *price* (~10% for a cache read) but not the count, and a cache miss
  after a TTL lapse re-prefills the lot. So "uses way more tokens" is
  right, and it is already true at 30%; it is merely twice as bad at 60%.
- **Latency.** TTFT is prefill-bound: ~400–800ms at 10k input tokens,
  several seconds at 100k. Smooth and roughly linear, again no knee.
- **Local decode (this matters most for pikuri, being llama.cpp-first).**
  Token generation is bottlenecked on KV-cache memory bandwidth, so
  tok/s falls steadily as the cache grows. Here a genuine *cliff* does
  exist — but it is a hardware artifact, not a model property: it hits
  when the KV cache stops fitting in VRAM and spills. Its location is set
  by `n_ctx`, quantization and card, not by a percentage.

The one source arguing for a percentage — an unreplicated preprint
(arXiv 2601.15300) claiming a 45.5% collapse at ~50% of max window over a
narrow 10% band — is exactly the shape the 60% intuition predicts, and is
noted here precisely so nobody leans on it: Chroma's 18-model *Context
Rot* study finds degradation **gradual and task-dependent, with no
universal threshold**, which is the better-supported picture.

### The number the operator actually wants is ~30k, and it's about quality

The strongest argument for the discipline isn't speed or cost — it's that
the answers get worse, far earlier than the window fills:

- **NoLiMa**: 11 of 12 models fell below *half* their short-context score
  at 32k tokens.
- **Aider's Paul Gauthier**: models "get confused when you feed them more
  than ~25–30k tokens."
- **Lost-in-the-middle** (Stanford): 20 retrieved docs (~4k tokens) drops
  accuracy from 70–75% to 55–60%, U-shaped by position.

So the practical yardstick is **absolute, around 30k tokens**, and on a
modern window that is nowhere near 60% — it's 3% of 1M. The 60% figure
only looks right on a *small* window, where percentage and absolute
converge; on llama.cpp at 32k, 60% ≈ 19k, which lands in the right
ballpark by coincidence. For calibration, Claude Code's own auto-compact
default sits at ~95%, with operators tuning anywhere from 20–40%
(aggressive) to 80%+ (late) — the spread itself says there is no physical
constant to find.

### Where the thesis holds, and where it can't

It holds completely for the **interactive main agent**: a human at every
turn, watching `TokenLog`, is a better context manager than any
summarizer, and the honest read is that compaction is a *convenience*
there, not a correctness requirement.

It cannot hold for the **autonomous legs**, and pikuri ships several —
`max_steps` of 40, sub-agents, `bin/pikuri-minions`, corpus RAG. One tool
observation (a large file read, `rg` across a monorepo, a scraped page)
can add tens of thousands of tokens between two consecutive human
glances. The operator cannot watch what they are not watching. Note that
sub-agents already encode the same insight from the other side: they are
always `on_exhausted: :synthesize`, i.e. the leg that no human is
watching is the one that must summarize itself.

### The sharp bit: the idea file *is* the compaction

The reported practice works because **the state lives in files, not in
the conversation.** "End the session, update the idea file" is not the
absence of compaction — it is compaction, done by hand, into a durable
artifact. And it's a strictly better artifact than an in-context summary:
reviewable, editable, versioned in git, readable by a human, and
re-loadable by the *next* session (and by a different model).

That reorders the agenda below. If the durable-artifact handoff is what
actually works in practice, pikuri's job is not to build a compactor but
to **make ending a session cheap and resuming it exact** — which is
strategies 2 and 7, not 3. It also argues the eventual `pikuri-tui`
should treat a session boundary as a first-class, *visible* event rather
than something to paper over.


## What this note must decide

- **Is recovery wanted at all for the interactive agent?** Per the
  counter-thesis above, a watching human may make it moot there, leaving
  only the autonomous legs to serve. "Ship nothing for the main agent" is
  a live answer, not a placeholder.
- **Who owns recovery — `lib/` or the host?** A `Control` in core that
  every host inherits, versus a seam core exposes and `pikuri-tui`
  implements. (Compare `StepLimit`, which chose a policy enum in core.)
- **Does a `bin/` script get a choice?** A `on_context_overflow:` knob
  mirroring `on_exhausted: :raise | :synthesize` would keep demos honest
  while letting one demonstrate the real behaviour — at the cost of a
  config knob CLAUDE.md's "no knobs not needed for the next concrete
  step" rule would want justified.
- **Recover before or after the raise?** Reacting to
  `ContextLengthExceededError` is simple but late (the request already
  failed and the turn is half-built); acting on a threshold *before* it
  needs a trustworthy cap, which per `D-context-window-sources` most
  wirings don't have.
- **Is a compacted conversation still the same conversation?** Bears on
  `clear_conversation`, `Event::Reset`, extension `on_conversation_reset`
  (does the workspace's read-record survive a compaction?), and what
  `TokenLog` should show afterwards.
- **What must never be pruned?** The Agent Skills spec's own
  client-implementation guide (Step 5) says to exempt skill content from
  pruning: losing a loaded skill mid-conversation degrades the agent
  *silently*, with no error — the model simply stops following guidance it
  can no longer see, which is the one failure mode CLAUDE.md's "errors are
  loud" rule exists to prevent. Nothing to fix today (nothing prunes), but
  it constrains strategies 3–5, and the enabling half is already in place:
  {Pikuri::Skill::Renderer.format_skill}'s `<skill name="…">` envelope is
  exactly the tag a compactor would key on, so don't lose it if the
  envelope is ever restyled. The same guide recommends tracking
  activations and skipping re-injection of an already-loaded skill —
  {Pikuri::Skill::SkillTool} re-renders the full body per call, so loading
  `cop` three times pays ~2 800 tokens three times. Cheap to fix, and
  whether it's worth fixing depends on whether anything here ever
  summarizes.


## Candidate strategies (agenda only — argue these later)

1. Fail loudly, lose the conversation. *(today)*
2. Summarize, then exit — hand the human a resumable digest.
3. Summarize in place and continue (auto-compaction).
4. Evict oldest turns; keep the system prompt and the last N.
5. Evict by *kind* — drop bulky tool observations, keep the dialogue.
6. Offload to disk / the vector store and retrieve on demand.
7. Hand off to a fresh agent seeded with a summary + open task list.
8. Ask the human what to do.

0. Don't reach the wall — the operator ends the session first, and the
   handoff is a file in the repo. *(today, for a disciplined human; see
   the counter-thesis. Not available to an autonomous leg.)*

These are not mutually exclusive, and the right answer may differ for a
demo script, a TUI, and a sub-agent. Given (0), 2 and 7 look stronger
than 3.


## Pointers

- {Pikuri::Agent::Synthesizer}, {Pikuri::Agent::Control::StepLimit} — the
  existing summarize-on-exhaustion machinery and its policy-enum shape.
- {Pikuri::Agent::Listener::TokenLog} — where the live usage number
  already lives.
- {Pikuri::Agent#clear_conversation} — the existing "start over" path any
  compaction has to stay coherent with.
- `D-context-window-sources` — why a cap is often `nil`, which constrains
  every threshold-based option.
- `book/tasks.md` mentions the overflow raise in passing; if behaviour
  changes, that line needs a look.

Sources for the numbers above (checked 2026-08-15):

- Chroma, *Context Rot* — <https://www.trychroma.com/research/context-rot>
  (18 frontier models; gradual, task-dependent, no universal threshold)
- NoLiMa + Gauthier's ~25–30k figure, via
  <https://www.albertsikkema.com/ai/development/tools/2026/04/23/smaller-context-window-better-claude-code.html>
- Claude Code's ~95% auto-compact default and the operator spread —
  <https://code.claude.com/docs/en/context-window>
- The lone percentage-threshold claim, treated as unreplicated —
  <https://arxiv.org/abs/2601.15300>
