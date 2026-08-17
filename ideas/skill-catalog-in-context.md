# What the skill catalog advertises — the book remainder

Status: **every mechanism question on this axis is closed** (2026-08-17).
`paths:` gating shipped, plus two trims that came cheap — `<location>` left
the catalog and promotion renders, and a typed `/name` loads a skill in
`bin/pikuri-code`. The decision, its measurements, its roads not taken and
the reasons the *remaining* items were left unbuilt all live in
`DECISIONS.md` `D-skill-path-activation` (see its last two consequence
bullets) and `D-slash-commands` (the typed-name chain). The
prior-art survey lives in `COMPARISON.md` (*Skills → Frontmatter*, *→ How
grok-build's conditional activation actually works*).

**All that is left here is prose owed to the book.** Nothing below changes
code, and when both bullets are written this note is **deleted**.

This note used to carry the whole argument — ten rounds of it, plus ten
numbered items. That history is in git (`6c902ea` and its parents) and is
not worth re-reading.

Related:

- [`skill-cost-model.md`](skill-cost-model.md) — the tier measurements this
  note used to consume. Its cheap borrows 2 and 5 are closed by the same
  decision; borrow 7 (compaction) waits on compaction existing.
- `DECISIONS.md` `D-skill-path-activation` — the matcher mechanism, shipped
  2026-08-17: a `paths:` skill is withheld until a touched file fires it.
- `DECISIONS.md` `D-no-skills-in-sub-agents` — why a persona's brief is
  complete on arrival, which retired this note's sub-agent question.


## Owed to the book

`book/skills.md` is still marked a stub, and these are two of the things
it is a stub for. Both are *concepts*, not API facts, so yardoc is the
wrong home — and both are advice to skill **authors**, who never read
pikuri's source.

1. **The capability-vs-correction asymmetry.** An MCP server advertises a
   *capability* the model can feel the lack of; a skill advertises a
   *correction* the model cannot. That is why skills need a trigger where
   MCP servers do not, and why no amount of description tuning fully
   closes the gap — it is also why every harness surveyed relies on model
   judgment and then adds a nudge mechanism anyway, which is the half
   `COMPARISON.md` should carry.

   The sharp form: a correction is overwhelmingly **subtractive**
   ("delete this", "never write that"), and a subtractive instruction
   loses to a concrete exemplar sitting in the same context — because
   **imitation transmits presence and never absence**. You can copy a
   neighbour's tag style; you cannot learn "cut your rationale section"
   from a file whose author already cut theirs.

2. **How to author a skill that fires.** Four rules:

   - Lead with the trigger, not a summary of the content.
   - Cut the narrative — a description is a routing decision, not a pitch.
   - A **gated** description is paid only on activation, so it can afford
     to be trigger-heavy; an **ungated** one is resident forever, so it
     must be tight.
   - **State a ban literally, never categorically.** "Never write `Not
     thread-safe`" beats "skip the negative", because a categorical ban
     asks the model to classify its own output as an instance before it
     can obey.

   Teach the fourth as a reason, not a tally. It has local-model runs
   behind it, but far too few to quote — see the anecdote-not-measurement
   caveat on `D-skill-path-activation`. A rule that needs a statistic to
   be believed does not belong in a chapter.
