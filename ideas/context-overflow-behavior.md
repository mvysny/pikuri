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


## What this note must decide

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


## Candidate strategies (agenda only — argue these later)

1. Fail loudly, lose the conversation. *(today)*
2. Summarize, then exit — hand the human a resumable digest.
3. Summarize in place and continue (auto-compaction).
4. Evict oldest turns; keep the system prompt and the last N.
5. Evict by *kind* — drop bulky tool observations, keep the dialogue.
6. Offload to disk / the vector store and retrieve on demand.
7. Hand off to a fresh agent seeded with a summary + open task list.
8. Ask the human what to do.

These are not mutually exclusive, and the right answer may differ for a
demo script, a TUI, and a sub-agent.


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
