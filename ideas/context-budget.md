# Telling the *model* how much context it has spent

Status: **idea, not built.** Origin: `feedback.txt` item 1 ("no 'where am
I in context?' signal"), which asked for a budget line on *every* turn.
That framing is rejected below; what survives is much smaller.

The human-facing half of this already ships. The only open question is
whether to add a model-facing half, and — after arguing it out — the
answer is at most **one late warning**, never a per-turn readout.


## What already ships (grounded)

The number exists; it just points at the human.

- {Pikuri::Agent#context_window_cap} (`pikuri-core/lib/pikuri/agent.rb:214`),
  resolved once at construction, emitted as `Event::ContextCap`.
- `Event::Tokens` per assistant message (`agent.rb:653`) — input, cached,
  cache_creation, output.
- {Pikuri::Agent::Listener::TokenLog} computes exactly the wanted number:
  `input + cached + cache_creation + output` (`token_log.rb:164`),
  rendered `ctx=8.4k/32.0k` with a cap, bare `8.4k` without
  (`token_log.rb:180`). It already degrades honestly when the cap is
  `nil`, which is the same rule a model-facing line would need.
- `TokenLog#status_line` + `#on_status_line` exist *specifically* so a
  host can put the readout in a TUI footer.

So "the user should watch the context size" is already implemented.
Nit found while grounding this: `bin/pikuri-code` is the one binary that
doesn't wire `TokenLog` (chat / os / memory all do). Worth fixing
regardless of whether the rest of this note ever lands.


## What happens at the wall — and why that's not settled

Every binary rescues `RubyLLM::ContextLengthExceededError`; `pikuri-code`
does `warn` + `exit 1` (`pikuri-code/bin/pikuri-code:366`).

**Do not read that as pikuri's overflow policy.** `bin/pikuri-*` are dev
/ demo entry points (CLAUDE.md, Layout), and dying on overflow is that
deliberate simplicity in action — the right move for a script whose job
is to be readable end-to-end. A real host (`pikuri-tui`) can and should
do something better; *what* is
[`context-overflow-behavior.md`](context-overflow-behavior.md)'s
question, not this note's.

That matters here because it changes the size of the prize. Against
`exit 1`, a pre-wall handoff written by the model saves a session that
would otherwise be lost outright. Against a host that compacts, or
auto-clears with a summary, or lets the human rewind, most of that value
evaporates — such a host can summarize the history *after* the fact and
doesn't need the model to have volunteered anything in advance.

**So this note is downstream of `context-overflow-behavior.md`, and
should not land before it.** If the host handles overflow well, the honest
outcome may be "tell the model nothing" (see the steelman below).

With that caveat, the test for the feature is: **what can the model do
with the number that the host can't?** Exactly two things:

1. Stop pulling bytes in — delegate broad recon rather than reading files
   inline, don't re-read what's already read. Real, but marginal; a
   well-prompted agent should do this anyway.
2. **Write a handoff before the wall.** The model is the only party that
   knows which state matters *while it still has the full picture*. At
   the very top of the window, "here's what's done, what's next, clear
   and paste this" is an artifact no post-hoc summarizer can match — but
   only by a margin, and only if the host doesn't already summarize.

(2) is the entire case for the feature, and its strength scales inversely
with how good the host's overflow handling is. (1) alone would not be
worth a token.


## Why the per-turn line is wrong

Three independent reasons, any one sufficient:

- **Inert in the middle band.** Between ~20% and ~60% the number changes
  no behaviour. It is pure cost, plus a standing invitation to optimize
  against a constraint that isn't binding.
- **It accumulates, permanently.** `Extension#on_user_message` is
  append-only by design (its own yardoc: the Agent "only ever appends…
  never rewrites or removes an earlier one, which would bust the provider
  prefix cache"). A long conversation therefore carries a growing pile of
  stale percentages, each a small nudge toward shortcutting. Ironic for a
  feature about context frugality.
- **Panic.** Showing a model a budget makes it rush — truncate work, skip
  verification, "let me wrap up given limited context". Claude Code's own
  standing prompt carries an explicit counter-instruction ("you don't need
  to wrap up early or hand off mid-task"). That sentence exists *because*
  the failure mode is real; they shipped a leash rather than removing the
  number.

The steelman for telling it nothing at all is strong and worth writing
down: **without the number the model acts as if context were unbounded,
which is correct on the overwhelming majority of turns and produces its
best work.** Knowledge of a constraint only pays when the constraint
binds. The late-warning shape is an attempt to keep that property for
~90% of turns while making the last 10% non-fatal.


## Proposed shape

One `:system` append when crossing ~85%, optionally a second at ~95%.
Fired once per band, with hysteresis (never twice for a band, never on
the way down). Bare:

```
Context: 109k / 128k used.
```

No percentage — a percentage reads as a progress bar toward death, a raw
count reads as an instrument. No adjective, no advice, no anti-panic
paragraph: if the model draws the wrong conclusion from one late
mechanical reading, more words won't fix it, and the words are exactly
what makes the per-turn version intolerable.

Home: a `Control` next to {Pikuri::Agent::Control::StepLimit} — controls
are already the family for loop-level budgets, and the natural firing
point is the `after_tool_result` boundary where the interloper drains
(the only place mid-turn where conversation state is consistent).
`Extension#on_user_message` is the wrong hook for this: it fires once per
*user* turn, so a 40-step autonomous run — precisely the case that blows
the window — would get one reading, taken before the run started.

**Off by default**, wired by `pikuri-code` only.

### Unknown cap ⇒ no line at all

Per `D-context-window-sources`, the cap is `nil` for anything but
llama.cpp or an explicit `ChatTransport#context_window`. A threshold
feature needs a denominator, so with no cap there is no band to cross and
nothing to emit. Never invent a denominator, and never emit a bare "56k
used so far" as a consolation prize — that's the inert middle-band line
wearing a different hat.


## Considered and rejected

- **A budget line on every turn** (the original feedback ask) — the three
  reasons above.
- **`Extension#system_prompt_snippets`** — assembled at construction and
  on `clear_conversation` only (`agent.rb:490`), so it would be frozen at
  0%. And a prompt that changes per turn invalidates the provider prefix
  cache for the whole conversation: the most expensive possible home for
  a number that changes constantly.
- **Appending to every tool result** — that's the tool's contract, and
  you'd pay it on all 40 steps.
- **A `context_status` tool** — the model has to know to ask, which is
  the one thing it can't know.
- **`<total_tokens>` as a design precedent.** Claude Code emits a
  `<total_tokens>N tokens left</total_tokens>` counter on every turn, and
  it briefly looked like evidence that "remaining" beats "used" as a
  framing. It isn't: the figure (15M) far exceeds that model's context
  window, so it's a spend budget, not a context readout. Recorded here so
  nobody re-derives the false lead.


## Coupling to compaction (orthogonal, but not independent)

Automatic context compaction is a separate feature and should stay one.
But the *absence* of graceful overflow handling is what gives this note
its value: where the host recovers, the wall is a hiccup and no warning
is needed; where it doesn't, the model's pre-wall note is the only
salvage. This warning is best understood as the cheap stand-in for a
host that handles overflow properly. **If compaction ships — or if
`pikuri-tui` handles overflow well on its own — delete the warning
rather than keeping both.**


## How to settle it

Not testable with `Testing.fake_transport` — this is a claim about model
behaviour, not wiring. The experiment is running `pikuri-code` on one
real, long task twice, warning on and off, and watching whether the
warned run degrades *before* the wall or hands off cleanly *at* it.

Until that's run, "off by default" is the honest posture, and shipping it
as a flag is what makes the experiment cheap.

**Sequence, though: settle `pikuri-tui`'s overflow behaviour first.** It
sets the value of the prize, and could well settle this note by making it
unnecessary. Running the A/B before that risks measuring a feature
against a `bin/` script's deliberate simplicity rather than against the
host anyone will actually use.


## Graduation plan

Blocked on [`context-overflow-behavior.md`](context-overflow-behavior.md)
— see above. Once that's settled, the fork here is real (per-turn vs. late-only vs. nothing), so
this earns a `DECISIONS.md` entry whenever it lands — including the "tell
it nothing" branch, which is a legitimate outcome and would otherwise get
re-proposed every time someone rereads the feedback file.

- Decision + rejected alternatives → `DECISIONS.md`.
- The `nil`-cap ⇒ no-line rule, and the once-per-band hysteresis → yardoc
  on the new `Control`.
- The compaction coupling → that entry's *Consequences*.
- Then cut item 1 from `feedback.txt`, renumber the remainder, and add
  the settled line to its header note.
- The `bin/pikuri-code` missing-`TokenLog` nit is independent — land it
  separately, don't hold it hostage to this decision.
