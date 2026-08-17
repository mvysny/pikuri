# What skills actually cost in context — the shared evidence base

Status: **all but graduated.** Every fork this note fed is closed
(2026-08-17 — `paths:` gating shipped and is the whole of what the skills
surface earned; see `DECISIONS.md` `D-skill-path-activation`, *this is
where the skills-surface work stops*), and the evidence base it existed to
hold now has durable homes: the tier costs and the caching arithmetic sit
in that entry's **Context**, the build-once-is-a-price consequence in
{Pikuri::Agent#assemble_system_prompt}'s yardoc, the prior-art survey in
`COMPARISON.md` §Skills, and the don't-prune-skills constraint in
`context-overflow-behavior.md`. **Nothing cites this file any more.** What
is left is the 100:1 arithmetic below plus the housekeeping listed at the
end; when those land, delete it.

Origin: `feedback.txt` item 3 ("skill load costs a turn"), which asked for
one of three things — path-triggered auto-injection, a batch `skill` call,
or at least for skill-loading to feel like the *expected opening move*
rather than a surprise tax. The framing was the first thing to fix, and
then all three settled:

- **(a) auto-injection — rejected as asked, shipped reframed.** Injecting
  bodies on a path match pays the expensive axis unconditionally on any
  Ruby file touch, and needs a glob→skill config table, which is the
  wall-of-JSON pikuri exists as a counter-move to. A path glob as a
  relevance filter promoting a withheld *catalog entry* is a different
  feature: `D-skill-path-activation`.
- **(b) batch load — already available.** ruby_llm executes *every* tool
  call in an assistant message (`chat.rb:346`, `tool_calls.each_value`),
  so `skill("cop")` + `skill("tuile")` + a `read` in one message is
  already one round-trip. Grok's own escape hatch ("if I can already batch
  `skill` with other tools, that's enough") is satisfied by machinery that
  already exists. A `names:` array would be a second way to do the same
  thing — and would make the pathological case (four bodies in one shot)
  the easier one to type.
- **(c) "expected opening move" — a prompt-wording problem, not a
  mechanism one.** Lives in [`claude-parity.md`](claude-parity.md) as its
  "Skill-invocation emphasis — measure" item.

**Scope.** This note owns the numbers, and nothing else. Prior art lives in
`COMPARISON.md` §Skills. It does **not** decide what the catalog contains (→
`D-skill-path-activation` and the book's [skills
chapter](../book/skills.md)) or how the shipped `paths:` trigger is wired
(→ the same entry).

Related:

- `DECISIONS.md` `D-skill-path-activation` — where every fork here landed,
  and now the home of the numbers too: the tier-0-vs-tier-1 40:1 ratio, the
  28-skill calibration, and what caching does and does not refund. (An
  earlier sibling note, `skill-catalog-in-context.md`, covered *what* the
  catalog advertises; fully graduated and deleted 2026-08-17.)
- [`tool-list-in-context.md`](tool-list-in-context.md) — the same
  resident-prefix arithmetic applied to tool schemas, which turn out to be
  ~4× the skill catalog. It cited this file for the caching section and now
  cites that entry instead.
- [`context-overflow-behavior.md`](context-overflow-behavior.md) — owns
  the spec's don't-prune-skill-content constraint (moved there 2026-08-17,
  since it is a compaction question and compaction lives there).
- [`grok-build-cheap-borrows.md`](grok-build-cheap-borrows.md) — a
  *different* set of borrows from the same survey (Edit/Read shaped). Same
  name, no overlap.
- [`context-budget.md`](context-budget.md) — same shape of mistake:
  feedback asking for a per-turn signal, where the honest answer is much
  smaller than the ask.


## The arithmetic — "a turn" is the cheap axis

On this repo's own skills, for the pairing Grok actually complained about:

| | cost |
|---|---|
| the `skill(name: "cop")` call itself | ~30 output tokens, once |
| `cop` SKILL.md (11 157 B) + `tuile` (5 231 B) | ~4 000 input tokens, resident for the rest of the conversation |

Roughly **100:1**. Every mechanism proposed to shave the 30 makes the
4 000 worse, or pays it on turns where it buys nothing.
{Pikuri::Skill::SkillTool}'s class header already states the principle
("the prompt pays per skill *installed*, this tool pays per skill
*used*"); item 3 is a request to trade the cheap axis for the expensive
one, from a reviewer who could not see the price tag.

One nuance worth keeping honest: **latency isn't nothing.** On a cacheless
local llama.cpp an extra round-trip is a full prefill. But it is *one*
turn and it doesn't scale with skill size, whereas pre-injection
re-prefills 4 k tokens on every subsequent turn. The latency argument
points the same way as the token one.


## Graduation plan — three lines, then delete

- **The 100:1 ratio above** → {Pikuri::Skill::SkillTool}'s class header,
  tightening the installed-vs-used sentence already there with the number
  that backs it, and with the framing that survived every fork: *a trigger
  is a relevance filter, not a preloader.*
- **`feedback.txt` item 3** → cut, remaining items renumbered, and the
  settled-so-far preamble extended with the `paths:` gate.
- **The failure mode worth naming wherever this lands:** Grok's pain was
  not tokens or latency, it was doing half its recon under the wrong
  mental model and having to redo it — and that wasted recon is *itself*
  far more context than the skill body. It's the argument that makes the
  free, prompt-side fixes the high-value ones. Fits the same `SkillTool`
  header, or the book's [skills chapter](../book/skills.md).
