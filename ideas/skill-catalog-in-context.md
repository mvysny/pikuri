# Does the skill catalog earn its slot in the system prompt?

Status: **open question, nothing decided.** Split out of what is now
[`skill-path-activation.md`](skill-path-activation.md), where it arrived
as a thread. It's a *sister* idea, not a sub-idea: that note asks "*when*
should an entry be promoted?", this one asks the prior question — **is an
always-resident `<available_skills>` block worth what it costs, given the
model rarely activates on it anyway?** The two answers compose (the
synthesis below uses `paths:` as the promotion trigger), but each is
decidable without the other.

**Scope.** This note owns *what a resident entry contains* — names vs.
descriptions, how long a description should be, what it's allowed to say,
and who gets to see the list at all (including sub-agents). It does
**not** own the trigger mechanism (→ `skill-path-activation.md`) or the
measurements it argues from (→ `skill-cost-model.md`).

Related:

- [`skill-cost-model.md`](skill-cost-model.md) — the tier measurements
  (including the 40:1 names-to-descriptions ratio this note turns on),
  the KV-cache analysis that prices *prefix mutation* (load it before
  arguing about token counts here), and the cheap borrows, one of which
  hands this note its tier 0 for free.
- [`skill-path-activation.md`](skill-path-activation.md) — the
  path-matcher mechanism this note's tier 1 would ride on.
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
     which is the thing `feedback.txt` item 3 set out to avoid.

   **Author's objection (2026-08-16):** *yes, true, the LLM can't load a
   skill it never saw — but as my experience shows, even with a full
   catalog loaded, the LLM rarely auto-loads a skill unless massively
   nudged. The user tells the LLM to load the skill (or loads it directly
   via a slash command), which means it's the **UX's** job to list
   skills, not the context's. So maybe all we need is `Available skills:
   [cop, tuile, …]` in context, so the LLM knows what exists and isn't
   issuing a load call in the dark — but that's it, no description
   attached.*

   **Granted — and it reframes tier 0 from a compromise into the design.**
   The one hole is that *"listing is the UX's job"* assumes a human at a
   keyboard, and **a sub-agent has no keyboard**: no CLAUDE.md, no slash
   commands, no picker, and its persona `system_prompt:` replaces the
   main prompt rather than extending it. It still inherits the `skill`
   tool over the same catalog, so if listing belongs to the UX then a
   sub-agent's skill list is *nobody's* job — and it would be calling
   `skill` genuinely blind, which is the exact failure the bare-name line
   exists to prevent. Two consequences:

   - The name list should live where a persona can still see it: the
     **tool schema enum** (`skill-cost-model.md` cheap borrow 1), not a
     system-prompt block the persona overwrites. For a main agent the
     enum is a redundancy; for a sub-agent it's the whole interface.
   - It reopens *which* names. Options: (i) every persona sees the full
     name list — cheap, but `FILE_MINER` gets `dataviz` forever; (ii) the
     parent pre-selects per persona at wiring time, exactly as
     `tool_names:` already does, so a `skill_names:` field is the same
     move one axis over; (iii) personas get no skills at all, consistent
     with "sub-agents don't inherit extensions" and roughly what happens
     today for the description half.

   My read: (ii). It matches how a persona already owns its toolset
   verbatim, costs nothing at runtime, and it is the only option where
   "which skills does this agent need?" is answered by a human — the
   objection's own principle, applied one level down. See open question 6.
2. **So "drop the registry, nudge from CLAUDE.md" is a wash on cost and a
   loss on freshness.** The saving people picture comes from dropping the
   **descriptions**, not from dropping the **mechanism**. Those are
   separable, and only one of them is expensive.
3. **Sub-agents and non-`bin/` hosts never see CLAUDE.md.** A persona
   gets its tool snapshot and its own system prompt, and it *does* inherit
   the `skill` tool closing over the same catalog. Whatever carries name
   knowledge has to be the catalog, or personas lose skills entirely —
   and the same hole swallows the picker, not just CLAUDE.md, which is
   the gap under the objection above.
4. **A `bin/` demo's manual load is not evidence about the library.**
   CLAUDE.md's own warning: no bundled binary even exposes
   {Pikuri::Skill::Extension#schedule_load_skill}, so "the user loads it
   manually anyway" describes a wiring gap, not pikuri's behaviour. The
   real host being designed against is a TUI with a skill picker, where
   both paths coexist.


## The synthesis: three tiers, not two

The separable thing in claim 2 is descriptions-vs-names, and
`skill-cost-model.md` prices the split: on this machine's 12 on-disk
skills, names render to ~65 tokens and descriptions to ~1.5 k.

| tier | resident | arrives |
|---|---|---|
| 0 | `<name>` only (~65 tok / 12 skills) | always |
| 1 | + `<description>` (~1.5 k tok / 12 skills) | on a `paths:` match, as an injection |
| 2 | body (2–30 KB each) | on the `skill` call |

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

- **Tier 0 may already be free.** `skill-cost-model.md` cheap borrow 1
  proposes enum-constraining `SkillTool`'s `name` parameter to the
  catalog's names. An enum of every skill name **is** a names-only
  catalog, living in the tool schema where it is paid anyway. If that
  borrow lands first, tier 0 costs literally nothing extra and the
  `<available_skills>` entry for a path-gated skill can simply be
  deleted. Cheap borrow 4 (drop `<location>` from the catalog render)
  composes the same way — tier 0 must not carry locations.
- **It does not fix a description that fails to say *when*.** Such a
  description fails identically at tier 1, one turn later. The preamble
  sharpening and the lead-with-the-trigger authoring guidance in open
  question 1 below remain prerequisites, not alternatives.


## What the caching analysis does to this

`skill-cost-model.md`'s KV-cache section is the reason this note can't be
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

That is a genuine cost, and it is the thing to measure before building:
**how many activations does a realistic session actually fire?** If it's
1–3, this is noise. If a chatty glob fires fifteen times, tier 0 is a net
loss on Anthropic. (Open question 2, shared with the activation note.)


## Four observations (Claude, 2026-08-16)

### 1. Why claim 1 holds — and why better descriptions can't fully fix it

pikuri already runs this exact experiment, on a different noun.
`Mcp::Servers` renders `<available_mcps>` with `<id>` + `<description>`
per server and a preamble telling the model to call `mcp_connect`. Same
shape, same position, same activation-by-judgment. The instructive part
is that the MCP version *works* and the skill version reportedly doesn't
— and the difference isn't the rendering, it's what's being advertised:

- **An MCP server advertises a capability.** The model can tell it lacks
  one. "I need to query Open Library and I have no tool for it" is a
  gap the model observes directly, from a failed plan.
- **A skill advertises a correction.** The model cannot tell it is about
  to do something the wrong way. `cop` exists precisely because the model
  will confidently write an `AbstractView` base class and never
  experience a missing capability while doing it.

That asymmetry predicts the observed behaviour better than "the
descriptions are badly written", and it predicts something else: **no
amount of description tuning closes it**, because the failure isn't that
the model misjudged relevance — it's that the model never ran the
relevance check, having felt no gap. It's the same reason a junior dev
doesn't look up the style guide before writing the code.

Consequences for this note: it strengthens the *structural* half of claim
2 (a trigger that fires on something the model doesn't have to notice)
and weakens `claude-parity.md`'s description-side rival as a *complete*
answer, without making it wrong — sharper descriptions still help the
cases where the model does pause to check. It also means open question 4's
fair test should be read carefully: skills that fire on description alone
will skew toward the capability-shaped ones (`dataviz`, `gh-auth`), and
that's a real result, not a confound — it just doesn't generalize to the
correction-shaped ones, which are the ones anybody bothered to nudge.

### 2. Tier 0 is a security win, not only a token win — with one prerequisite

Not mentioned anywhere above: **a skill is untrusted text**.
{Pikuri::Skill::SkillTool} declares `untrusted: :hard` in its
`trifecta_legs`, with the reasoning that a bundle travels between
harnesses and the tool can't tell a hand-written skill from a downloaded
`.agents/` one. A 28-entry catalog is therefore ~3.8 KB of
attacker-influenceable prose sitting in the **system prompt** — the
most-trusted position in the request — on every single turn, for skills
the session will never use.

And pikuri is inconsistent about this today. MCP server descriptions land
in the same position via `<available_mcps>` and get a **pre-flight
injection scan** — `Servers#start_one` rejects a server on
`Verifier::InjectionDetected` before it ever reaches the LLM. Skill
descriptions get no scan at all: `Catalog::Bundled#scan_root` parses the
frontmatter and the text goes straight into the prompt. Same trust class,
same position, different treatment. (The skill *body* is untrusted too,
but it arrives as a tool result — a data position — which is where
untrusted text belongs. The description is the one in the wrong place.)

Tier 0 closes that gap almost for free: it shrinks the always-resident
untrusted surface from free-form prose to a list of identifiers.

**The prerequisite, though:** that argument only holds if names are
*actually* constrained, and pikuri's validation is deliberately lenient —
`Catalog::Bundled`'s header: "invalid name chars … log a warning and load
anyway". So a `SKILL.md` can today declare a name containing arbitrary
text, and tier 0 would render it into the prompt with the descriptions
gone and the injection vector intact. Tier 0 therefore comes with a small
strictness decision: enforce the standard's `^[a-z0-9]+(-[a-z0-9]+)*$` for
*names* (still lenient about everything else), or run names through
{Pikuri::Sanitizer}. Cheap either way, but it must be part of the same
change, not a follow-up — and it's a mild break from the
lenient-validation posture, which is exactly the kind of thing that
belongs in the `DECISIONS.md` entry this note is already routing to.

### 3. The enum must carry the withheld names too

The tier-0-rides-the-enum rider is right, but it has a constraint worth
stating before someone implements it the obvious way: the enum has to
list **every** skill in the catalog, including the `paths:`-gated ones
whose descriptions are withheld. Otherwise a promoted skill is
un-callable — the model reads the injected description, calls
`skill(name: "tuile")`, and the schema rejects an argument that isn't in
its enum.

Stated positively, this is what makes the two mechanisms compose instead
of fight: **the enum is the stable tier 0 and never changes; only the
descriptions move.** The tool schema stays byte-identical for the whole
session, which matters more than it sounds given the caching section —
tool schemas are part of the cached prefix, so an enum that grew on each
activation would invalidate the cache exactly like the system prompt
does. The withhold-descriptions-only design keeps the prefix stable and
confines all mutation to appended injections.

### 4. A third placement for question 6(a): the tool description

Question 6(a) offers the enum or a system-prompt block. There's a third,
and it's the one pikuri explicitly ruled out: put the catalog in
{Pikuri::Skill::SkillTool}'s `description`. Its class header rejects this
today ("the inventory … lives in the system prompt … as PI and Claude
Code do (opencode is the outlier)") — but note that reasoning is about
*convention*, not mechanics, and opencode v1 shipped it.

For the sub-agent case it's exactly right, and for the same reason as the
enum: a persona replaces the system prompt but inherits the tool
verbatim, so anything carried on the tool survives. That suggests a
cleaner end-state than "enum + prompt block": **everything skills-related
rides the tool** — names in the enum, descriptions in the tool
description — and the system prompt carries nothing about skills at all.
One home, inherited correctly by construction, and the main agent's
`<available_skills>` block disappears entirely rather than being
duplicated.

Two caveats, neither fatal: a tool description is built once at
`configure` time, so it can't host promotions any better than the prompt
can (promotions stay injections either way); and it would need the
`SkillTool` header's convention argument revisited rather than ignored,
since that sentence also needs correcting for opencode v2's move
(`skill-cost-model.md` cheap borrow 3 — do both in one pass).


## Open questions

1. **Say-*when* vs. stay-short — the per-entry content tension.** (Moved
   here from `skill-cost-model.md`, where it was open question 1: it's a
   what-does-an-entry-contain question, so it belongs on this axis.) The
   failure Grok reported is a description that says what a skill *is* but
   not when to reach for it; the fix is to add the trigger. But the
   measurement says descriptions are *already* 3–6× the spec's 50–100
   token budget, and every added word is paid every turn by every
   session. Two levers pull opposite ways:
   - **The prompt half is free and unambiguous** — sharpen the
     `format_catalog` preamble from "load it *before* answering from
     your own knowledge" to something that also covers *recon*. One
     sentence, paid once, not per skill. Do this regardless.
   - **The per-skill half is the trade.** Options, roughly in order of
     how much machinery they cost: (i) author guidance only ("lead with
     the trigger, cap at ~2 lines") — free, unenforced; (ii) warn at
     scan time above some length well under the standard's 1024-char
     cap — cheap, honest, no truncation risk; (iii) adopt
     `when-to-use:` as a separate field so the *trigger* is structured
     and the *description* can be trimmed independently — the
     structurally right answer and the only one that survives tier 0
     later, but a non-standard key (see question 5); (iv) truncate in
     the catalog render like grok-build's proportional split — clever,
     and clever is how you cut a trigger sentence in half.

   My read: (i) + the preamble now, (ii) if a real catalog keeps
   growing, (iii) only if `when-to-use:` earns its way in for another
   reason. Explicitly *not* (iv).

   **Revised after the caching analysis.** The trade is less tight than
   it looked, and it tilts toward *saying when*. A longer description
   costs prefill only on turn one; what it costs forever is window
   capacity and attention. But a description that fails to fire the right
   skill costs a whole wasted recon pass — which is far more of *both*.
   So on the merits: pay the words, spend them on the trigger. That
   demotes (ii) from "cheap and honest" to "solving the cheap half" and
   makes (i) — teaching authors to lead with the trigger and cut the
   *narrative*, not the trigger — the whole answer for per-entry editing.
   The remaining worry isn't length, it's **twenty-eight descriptions of
   which one is relevant**: attention dilution scales with catalog
   *size*, and no amount of per-entry editing fixes it. Which is the
   argument for tier 0 — the only proposal on the table that *removes*
   descriptions rather than shortening them.
2. **Is a bare name a strong enough recall cue?** Tier 0 assumes a model
   seeing `karibu-testing` in a name list will reach for it once the path
   fires and the description arrives. Plausible, untested. Failure mode
   to watch: a model that ignores the name-only entry *and* ignores the
   injected description because it arrived mid-turn rather than in the
   prompt it was primed on. Cheapest probe: hand-render tier 0 for this
   repo's catalog and try it against a local model — no code required.
3. **How many activations per session?** The number that decides the
   Anthropic cache trade above. Measurable today with a throwaway
   listener over `Event::ToolCall`, before any of this is built. (Shared
   with `skill-path-activation.md`, which owns the mechanism side.)
4. **Does claim 1 survive a fair test?** The nudge list is
   selection-biased. The honest experiment is the other direction: take
   the skills *without* a CLAUDE.md nudge and check whether they ever
   fire on description alone. If they do, the catalog is working and only
   the task-shaped triggers need help — which is a much smaller fix
   (better descriptions) than any mechanism here.
5. **Is `when-to-use:` the better cut?** grok-build splits the trigger
   out of the description as its own frontmatter field. Tier 0 withholds
   the *whole* description; a `when-to-use:` split would let the baseline
   carry name + trigger (cheap, and the part that decides activation)
   while withholding the narrative (expensive, and only useful once
   you've decided). Strictly better shaped, one more non-standard key —
   and the same compatibility cost `paths:` carries in the activation
   note. Both notes want it; neither has justified it alone.
6. **Who lists skills for a sub-agent?** The picker-less UX gap under the
   author's objection in claim 2.1: if listing is the host UX's job, a
   persona has no host UX. Sub-questions, in the order they need
   answering:
   (a) does the name list ride the **tool schema enum**, which survives a
   persona replacing the system prompt, rather than a prompt block?
   (b) does a persona get the **whole** catalog or a `skill_names:`
   subset chosen at wiring time, mirroring `tool_names:`? (c) is that
   field worth adding before any persona actually wants a skill —
   `RESEARCHER` / `FILE_MINER` / `LIBRARIAN` arguably want none, which
   would make the honest answer "no skills for sub-agents, and say so in
   {Pikuri::SubAgent::Persona}'s yardoc" rather than a new field.
   Note this is the *only* question here that can't be deferred by
   shipping tier 0 first: whatever carries the names decides it.
   (Distinct from the activation note's sub-agent question, which is
   about whether an *activation* is per-agent or catalog-wide.)
7. **What does a *human* see?** The author's framing — being handed the
   Tuile manual at the moment you open a Tuile file — is a UX claim, not
   a token claim, and it's the part with no counter-argument. If
   promotion lands, the render must be legible in a TUI, not just a
   model-facing `<system-reminder>`. Mechanism side:
   `skill-path-activation.md`'s question about a dedicated event vs.
   `Event::SystemInjected`, which this note upgrades from a rendering
   nicety to the feature's actual selling point.
8. **Does tier 0 change what `clear_conversation` restores?** The
   baseline is rebuilt from the catalog, so name-only returns and
   promotions are discarded with the injections that carried them.
   Probably correct semantics for free — but it means a long session that
   clears loses its promotions and re-pays them, which interacts with
   question 3.


## Graduation plan (when this settles)

- **Same `DECISIONS.md` entry as the other two skill notes**, not a new
  one — the *what the catalog advertises, and when the body arrives*
  axis, stated here at its most general. Entries are mutable; this
  extends it in place. (`skill-cost-model.md` open question 2 settled
  that coordination.)
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
- **Either way**, two facts from observation 2 outlive the decision and
  belong in the durable places now, because they're true today and
  invisible in the code:
  - skill descriptions are `untrusted: :hard` text resident in the
    *system prompt*, while the equivalent MCP text gets a pre-flight
    injection scan → the asymmetry is a `SECURITY.md` / threat-model
    fact, not a skills-feature fact, and it is a live gap regardless of
    whether tier 0 ever ships;
  - lenient *name* validation is load-bearing in the wrong direction the
    moment names are the only thing resident → one line in
    {Pikuri::Skill::Catalog}'s validation paragraph.
- The **authoring guidance** from question 1 (lead with the trigger, cut
  the narrative, ~2 lines) is advice to skill *authors*, so it belongs
  wherever the book teaches skill authoring — not in a yardoc nobody
  writing a `SKILL.md` will read.
- The capability-vs-correction asymmetry (observation 1) is a *concept*,
  not a per-symbol fact: it explains why skills need a trigger where MCP
  servers don't, and it's the kind of thing the book's skills material
  exists to teach. It also belongs in `COMPARISON.md`'s reasoning about
  why every harness surveyed relies on model judgment and every one of
  them then adds a nudge mechanism anyway.
- The Anthropic prefix-rewrite cost of a `:system` promotion →
  {Pikuri::Skill::Extension#schedule_load_skill} yardoc, where
  `skill-cost-model.md` is already sending one sentence on the same
  mechanism. Merge, don't stack.
- The human-facing half ("handed the manual at the moment you open the
  file") → the book's skills material if it ships, since it's a concept
  and a teaching example, not a per-symbol fact.
- **Whichever way question 6 goes**, the answer is a fact about personas
  and belongs in {Pikuri::SubAgent::Persona}'s yardoc — including "a
  sub-agent gets no skills", if that's the ruling. It is currently
  unstated in either direction, which is why the gap was invisible.
