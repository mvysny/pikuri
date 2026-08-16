# Does the skill catalog earn its slot in the system prompt?

Status: **open question, nothing decided.** Split out of
[`lazy-skill-registration.md`](lazy-skill-registration.md), where it
arrived as a thread. It's a *sister* idea, not a sub-idea: that note asks
"can a `paths:` glob promote a skill at the moment it becomes relevant?",
this one asks the prior question — **is an always-resident
`<available_skills>` block worth what it costs, given the model rarely
activates on it anyway?** The two answers compose (the synthesis below
uses `paths:` as the promotion trigger), but each is decidable without
the other, and the ideas graduate to different places.

Related:

- [`lazy-skill-registration.md`](lazy-skill-registration.md) — the
  path-matcher mechanism this note's tier 1 would ride on. Also carries
  the same-matcher-applied-to-*tools* thread.
- [`skill-load-cost.md`](skill-load-cost.md) — the tier measurements, the
  KV-cache analysis that prices *prefix mutation* (load it before
  arguing about token counts here), and the cheap borrows, one of which
  hands this note its tier 0 for free.
- [`claude-parity.md`](claude-parity.md) — "Skill-invocation emphasis —
  measure" is the description-side rival: maybe the catalog works fine
  and the descriptions are just bad.


## The question

Stated by the author, 2026-08-16:

> What is the value of a skill definition when the user has to load the
> skill manually anyway? The LLM only rarely auto-loads a skill, and that
> usually happens after massive nudges from CLAUDE.md. If you need
> CLAUDE.md to say which skills to auto-load for which tasks, then the
> skill registry is useless and can be dropped from the context
> completely — `skill` loads a skill by name anyway, and `paths:` can
> auto-activate a skill when a file is touched: *"I see you're editing a
> Tuile component, here's a Tuile manual"* — which is brilliant for a
> human coder as well, being handed what you need exactly when you need
> it.

Two claims, worth separating because they fare differently:

1. **Empirical** — the catalog does not, in practice, cause activation.
2. **Structural** — therefore delete it; `skill(name:)` plus `paths:`
   covers everything it was doing.

Claim 1 holds up better than expected. Claim 2 doesn't survive contact
with "where does the model learn the name?", but the thing it's reaching
for survives in a better shape.


## Claim 1: the evidence is in this user's own config

`~/.claude/CLAUDE.md` hand-writes five skill nudges. Three are pure path
predicates:

| nudge | predicate | a glob expresses it? |
|---|---|---|
| `gradlew`/`build.gradle` → `gradle` | file exists | yes, exactly |
| `pom.xml`/`mvnw`/`.mvn` → `maven` | file exists | yes, exactly |
| Ruby docs → `writing-rdoc` | `**/*.rb` **+ intent** | over-fires on every Ruby touch |
| Java docs → `writing-javadoc` | same | over-fires |
| "before designing components" → `cop` | pure intent | no |

That someone wrote these **by hand, in an always-loaded file, while a
4.6 KB description catalog was already resident** is the strongest
available evidence that the catalog isn't earning its slot. Nobody writes
a redundant nudge for a mechanism that works.

It also argues for a **narrower** claim than the one being made, in two
directions:

- Descriptions fail for *task-shaped* triggers ("when writing docs",
  "when designing components"), not universally. A skill whose trigger is
  lexical — the user literally says "dataviz" — is the case descriptions
  handle fine, and it's under-represented in a hand-written nudge list by
  construction: **you only notice the nudges you had to write.**
- 2 of the 5 rows show a glob wouldn't have rescued them either. `cop`'s
  trigger is conceptual and `writing-rdoc`'s is intent-gated; a
  `**/*.rb` glob fires on every Ruby file touch, which is a
  mis-triggering catalog entry the model must ignore on every subsequent
  turn. Path activation is not a superset of what descriptions do.

The spec, notably, concedes claim 1 without solving it:
*"Most implementations rely on the model's own judgment as the activation
mechanism, rather than implementing harness-side trigger matching."*
Relying on judgment is a choice, not a finding.


## Claim 2: where "just delete it" breaks

1. **`skill(name:)` needs the name from somewhere.** The model cannot
   call a tool with an argument it has never seen. Delete the block and
   name knowledge has to come from one of:
   - **CLAUDE.md** — which is *also* always loaded, hand-maintained, and
     rots silently on a rename, where the catalog is regenerated from the
     filesystem at every boot. Same words, worse home.
   - **path activation only** — then a skill without `paths:` is
     permanently unreachable, and `cop` is exactly that skill.
   - **a `skill_list` discovery call** — a genuine extra round-trip,
     which is the thing `skill-load-cost.md` item 3 set out to avoid.
Objection: yes, true, LLM can't load a skill it never saw, but as my experience shows,
even with a full catalog loaded, LLM rarely auto-loads a skill unless massively nudged.
The user tells the LLM to load the skill (or loads it directly via a slash command),
which means it's the UX job to list skills, not the context job.
So maybe all we need is a "Available skills: [cop, tuile, ...]" in a context, so that
the LLM knows which tools are available, so that it doesn't feel like issuing
skill load tool call in the dark, but that's it - no description attached to the skill.
2. **So "drop the registry, nudge from CLAUDE.md" is a wash on cost and a
   loss on freshness.** The saving people picture comes from dropping the
   **descriptions**, not from dropping the **mechanism**. Those are
   separable, and only one of them is expensive.
3. **Sub-agents and non-`bin/` hosts never see CLAUDE.md.** A persona
   gets its tool snapshot and its own system prompt, and it *does* inherit
   the `skill` tool closing over the same catalog. Whatever carries name
   knowledge has to be the catalog, or personas lose skills entirely.
4. **A `bin/` demo's manual load is not evidence about the library.**
   CLAUDE.md's own warning: no bundled binary even exposes
   {Pikuri::Skill::Extension#schedule_load_skill}, so "the user loads it
   manually anyway" describes a wiring gap, not pikuri's behaviour. The
   real host being designed against is a TUI with a skill picker, where
   both paths coexist.


## The synthesis: three tiers, not two

The separable thing in claim 2 is descriptions-vs-names. Measured
2026-08-16 on `~/.claude/skills` (12 on-disk skills; `skill-load-cost.md`'s
28 / 3.8 k figure is Claude Code's own accounting and includes plugin
skills):

| tier | resident | cost, 12 skills | arrives |
|---|---|---|---|
| 0 | `<name>` only | 116 B of names, ~250 B rendered → **~65 tok** | always |
| 1 | + `<description>` | 4 587 B → **~1.5 k tok** rendered | on a `paths:` match, as an injection |
| 2 | body | 2–30 KB each | on the `skill` call |

**Descriptions are 40× the names.** That ratio is the whole argument:
tier 0 is nearly free, and it is the tier that keeps `skill(name:)`
callable, keeps the list generated rather than hand-written, and reaches
sub-agents.

And the opt-in falls out with **no new policy knob**: a skill declaring
`paths:` is asserting its trigger is lexical-on-file, so its description
is dead weight until the path fires — withhold it. A skill with no
`paths:` keeps its description in the baseline, because nothing else will
ever surface it. The author self-selects, per skill, in the frontmatter
they were already writing.

Against this repo's real catalog: `cop` stays fully advertised (correct —
its trigger is conceptual); `gradle`, `maven`, `karibu-testing`,
`vaadin-boot-app`, `writing-rdoc`/`-javadoc` drop to name-only until a
matching file is touched.

Two riders:

- **Tier 0 may already be free.** `skill-load-cost.md` cheap borrow 1
  proposes enum-constraining `SkillTool`'s `name` parameter to the
  catalog's names. An enum of every skill name **is** a names-only
  catalog, living in the tool schema where it is paid anyway. If that
  borrow lands first, tier 0 costs literally nothing extra and the
  `<available_skills>` entry for a path-gated skill can simply be
  deleted. Cheap borrow 4 (drop `<location>` from the catalog render)
  composes the same way — tier 0 must not carry locations.
- **It does not fix a description that fails to say *when*.** Such a
  description fails identically at tier 1, one turn later. The preamble
  sharpening and the lead-with-the-trigger authoring guidance in
  `skill-load-cost.md` open question 1 remain prerequisites, not
  alternatives.


## What the caching analysis does to this

`skill-load-cost.md`'s KV-cache section is the reason this note can't be
argued in raw token counts, and it cuts both ways.

**For tier 0.** The costs a cache does *not* refund are window capacity
and attention, and both scale with catalog **size** — twenty-eight
descriptions of which one is relevant is twenty-eight distractors on
every decoded token. That is the one cost per-entry editing cannot fix,
and it is exactly what tier 0 removes. On the merits this is the
strongest argument in the note.

**Against tier 0.** Promotion has to arrive as an injection, and
`Control::Interloper`'s `:system` kind is *hoisted into the top-level
system param on Anthropic* — i.e. it **rewrites the prefix and
invalidates the whole prompt cache**, per activation. So tier 0 trades a
permanent capacity/attention saving for a per-activation re-prefill on
one provider. Two mitigations, neither free:

- Activations cluster at the **start** of a session (first touch of a
  file kind), when the conversation is short and there is little to
  re-prefill. The cost is proportional to history length so far, which is
  smallest exactly when activations fire.
- The `:tool` path has no such divergence — it's positional on every
  provider. But a promotion is not a tool call, so it can't ride it
  without inventing a fake one, which is worse than the problem.

That is a genuine cost neither note had priced, and it is the thing to
measure before building: **how many activations does a realistic session
actually fire?** If it's 1–3, this is noise. If a chatty glob fires
fifteen times, tier 0 is a net loss on Anthropic.


## Open questions

1. **Is a bare name a strong enough recall cue?** Tier 0 assumes a model
   seeing `karibu-testing` in a name list will reach for it once the path
   fires and the description arrives. Plausible, untested. Failure mode
   to watch: a model that ignores the name-only entry *and* ignores the
   injected description because it arrived mid-turn rather than in the
   prompt it was primed on. Cheapest probe: hand-render tier 0 for this
   repo's catalog and try it against a local model — no code required.
2. **How many activations per session?** The number that decides the
   Anthropic cache trade above. Measurable today with a throwaway
   listener over `Event::ToolCall`, before any of this is built.
3. **Does claim 1 survive a fair test?** The nudge list is
   selection-biased. The honest experiment is the other direction: take
   the skills *without* a CLAUDE.md nudge and check whether they ever
   fire on description alone. If they do, the catalog is working and only
   the task-shaped triggers need help — which is a much smaller fix
   (better descriptions) than any mechanism here.
4. **What does a *human* see?** The author's framing — being handed the
   Tuile manual at the moment you open a Tuile file — is a UX claim, not
   a token claim, and it's the part with no counter-argument. If
   promotion lands, the render must be legible in a TUI, not just a
   model-facing `<system-reminder>`. That's
   `lazy-skill-registration.md`'s open question 6 (dedicated event vs.
   `Event::SystemInjected`), which this note upgrades from a rendering
   nicety to the feature's actual selling point.
5. **Is `when-to-use:` the better cut?** grok-build splits the trigger
   out of the description as its own frontmatter field. Tier 0 withholds
   the *whole* description; a `when-to-use:` split would let the baseline
   carry name + trigger (cheap, and the part that decides activation)
   while withholding the narrative (expensive, and only useful once
   you've decided). Strictly better shaped, one more non-standard key.
   Both notes want it; neither has justified it alone.
6. **Does tier 0 change what `clear_conversation` restores?** The
   baseline is rebuilt from the catalog, so name-only returns and
   promotions are discarded with the injections that carried them.
   Probably correct semantics for free — but it means a long session that
   clears loses its promotions and re-pays them, which interacts with
   question 2.


## Graduation plan (when this settles)

- **Same `DECISIONS.md` entry as the other two notes**, not a new one.
  `skill-load-cost.md` open question 3 already settled on *one* entry for
  the *what the catalog advertises, and when the body arrives* axis, and
  this is that axis stated at its most general. Entries are mutable;
  this extends it in place.
- **If tier 0 is built** → the three-tier table belongs in
  {Pikuri::Skill::Renderer}'s header, which already documents the two
  renders and would gain a third; the `paths:`-implies-withhold rule to
  {Pikuri::Skill::Catalog} yardoc alongside the `paths:` semantics
  themselves.
- **If rejected** → the durable nugget is the **40:1
  names-to-descriptions measurement** and why "just delete the catalog"
  doesn't follow from it (the name has to come from somewhere; a
  hand-written CLAUDE.md nudge is the same words in a rotting home). One
  line in {Pikuri::Skill::Catalog}'s yardoc, because the temptation
  recurs every time someone's catalog gets big.
- The Anthropic prefix-rewrite cost of a `:system` promotion →
  {Pikuri::Skill::Extension#schedule_load_skill} yardoc, where
  `skill-load-cost.md` is already sending one sentence on the same
  mechanism. Merge, don't stack.
- The human-facing half ("handed the manual at the moment you open the
  file") → the book's skills material if it ships, since it's a concept
  and a teaching example, not a per-symbol fact.
