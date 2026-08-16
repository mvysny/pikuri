# Does the skill catalog earn its slot in the system prompt?

Status: **open question; three items now owed regardless of how it
settles** (enum + name strictness, description injection-scan parity, the
`SkillTool` description bug — open questions 1–3). Split out of what is now
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

**Both readings were revised on 2026-08-16** — see *Contradictions,
resolved* below. Claim 1's evidence turns out to be asking for a
**deterministic** load channel rather than a better advisory one (R2),
and tier 0 — the shape claim 2 resolves into — survives only as a *cost*
argument, not an activation one (R1). Neither is dead; both are narrower.


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
   The one hole the objection leaves is that *"listing is the UX's job"*
   assumes a human at a keyboard, and **a sub-agent has no keyboard**: no
   CLAUDE.md, no slash commands, no picker, and its persona
   `system_prompt:` *replaces* the main prompt rather than extending it.

   **But the hole is currently empty — a load-bearing correction to an
   earlier draft of this note.** A sub-agent does *not* automatically
   inherit the `skill` tool: {Pikuri::SubAgent::SubAgentTool} filters
   `parent.tools` by `persona.tool_names`, and **no bundled persona lists
   `skill`** (`RESEARCHER`, `FILE_MINER`, `LIBRARIAN`,
   `GIT_REPO_RESEARCHER` — checked 2026-08-16). Its own yardoc already
   states the policy: *"Personas are self-contained — one that needs MCP
   / Skills ships its own wiring."* So today sub-agents have **no skills
   at all**, and `tool_names:` **already is** the per-persona skill
   opt-in, one level up: listing `skill` is a human deciding, at wiring
   time, that this persona gets skills. That is option (ii) of the
   earlier draft, already shipped, one noun coarser.

   Two consequences, both smaller than that draft's:

   - A `skill_names:` field would be a *second* filter underneath an
     existing one, for a case nobody has had. Rejected on the
     no-abstraction-just-in-case rule — with the honest caveat that the
     granularity available today is **all-or-nothing**, because a persona
     draws from `parent.tools` and therefore cannot be handed a
     *narrower catalog*. If a persona ever wants three skills out of
     thirty, that is when the field earns its way in.
   - What survives is a **live bug**, not a design gap. `SkillTool`'s
     description tells the model three times that the inventory is "in
     your system prompt under `<available_skills>`" — false for any
     persona that *does* list `skill`, whose prompt carries no such
     block. Fixable today, independent of every question in this note,
     and the strongest concrete argument for observation 4: put the
     inventory on the tool, where a persona inherits it verbatim.
2. **So "drop the registry, nudge from CLAUDE.md" is a wash on cost and a
   loss on freshness.** The saving people picture comes from dropping the
   **descriptions**, not from dropping the **mechanism**. Those are
   separable, and only one of them is expensive.
3. **Sub-agents and non-`bin/` hosts never see CLAUDE.md.** A persona
   gets its tool snapshot and its own system prompt, so neither a
   hand-written nudge nor a host picker reaches it. Corrected per the
   paragraph above: this is a *conditional* hole, live only for a host
   that opts a persona into `skill` — none of the bundled ones do. It
   still decides where name knowledge has to live *for that host*: on
   the tool, not in a prompt block the persona overwrites.
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
its trigger is conceptual); `tuile` and `ideas-folder` drop to name-only
until a matching file is touched, and `gradle` / `maven` /
`karibu-testing` drop only if you accept a predicate that misfires. That
list is shorter than an earlier draft's, which also gated
`writing-rdoc`/`-javadoc` and `vaadin-boot-app` — see the measurement
below, where authoring the frontmatter cut the estimate by 3×.


### Measured: pikuri's own catalog (2026-08-16)

Rendered the way `bin/pikuri-code` wires it — `search_bases: [project_root,
Dir.home]` over all three subdirs. Every number above this line was Claude
Code's accounting or a raw `~/.claude/skills` byte count; this is the first
measurement of the catalog **pikuri actually builds**.

| | bytes | note |
|---|---|---|
| 12 skills, names | 104 | |
| descriptions | 4 611 | **44:1** vs names — confirms the 40:1 |
| `<location>` paths | 524 | 5× the whole name list (cheap borrow 4's prize) |
| bodies | 123 KB | tier 2, paid only when asked |

Longest descriptions: `cop` 921 chars, `writing-rdoc` 629,
`writing-javadoc` 606, `karibu-testing` 474. None exceeds the standard's
1024-char cap; all are 2–9× the spec's 50–100 token budget.

Two things the measurement says that no previous number did:

**1. The gated fraction, which nobody had counted — and which shrank by
3× when someone actually counted it.** The first pass estimated 7 of 12
skills as carrying a plausible `paths:` predicate, at 2 678 B / 58 % of
the description bytes, and concluded tier 0 saves ~700 tokens per turn.
**That estimate was made by pattern-matching skill names, by the same
party arguing for the mechanism.** Drafting the actual frontmatter per
skill, 2026-08-16, gives a very different answer:

| | skills | description bytes | share |
|---|---|---|---|
| clean `paths:` fit | 2 (`tuile`, `ideas-folder`) | 795 | **17 %** |
| + partial / over-firing | 5 (+ `maven`, `gradle`, `karibu-testing`) | 1 557 | 33 % |
| the estimate it replaces | 7 | 2 678 | 58 % |

Where the four lost skills went, and why each is a category rather than a
quibble:

- `writing-rdoc` / `writing-javadoc` — `**/*.rb` / `**/*.java` fires on
  every touch of the language. Per claim 1's table a mis-triggering entry
  is **worse** than a resident one: the model pays to ignore it on every
  subsequent turn. These want `when-to-use:` (question 12), not `paths:`.
- `vaadin-boot-app` — the **bootstrap hole** in miniature
  (`tool-list-in-context.md` names it for tools): the skill is most needed
  at *scaffold* time, when the project has no files to touch.
- `cop` — pure intent, as claim 1 already said.

So tier 0's saving on this catalog is **~200 tokens per turn**, not 700 —
about 0.3 % of a 64 k window, and the prefill is cached anyway, so what it
actually buys is window capacity plus *two* fewer distractors. The
scaling argument survives but is much weaker: the thing that shrank is the
**ratio**, not the count, so it does not recover at 28 skills the way the
first estimate implied.

The methodological lesson outlives the number, and belongs wherever this
lands: **an estimate of how much a mechanism would save, made by the party
proposing it, was 3× optimistic — and the correction cost one afternoon of
writing the config it was estimating.** Authoring beats estimating,
cheaply, and should have come first.

**2. A third category the tier table has no row for.** `wh`'s description
is *"Generates a weekly work log. Only invoked manually."* — 51 resident
bytes spent telling the model to ignore a skill, on every turn, forever.
`grill-me` is the same shape. grok-build's `disable-model-invocation:`
(`skill-cost-model.md` cheap borrow 6) names exactly this: a
slash-command-only skill should cost **zero** resident tokens — no
description, and not in the enum either — while staying reachable through
{Pikuri::Skill::Extension#schedule_load_skill}. It is cheaper and more
certain than any glob, needs no matcher, no injection and no cache
invalidation, and it is the one category the *measurement* surfaced rather
than the argument. See open question 6.

**Acted on the same day, which is why the numbers above are a snapshot.**
Both skills turned out to be slash commands filed as skills — `wh` even
carried `argument-hint:`, a command key — and both moved to
`~/.claude/commands/`, where the body expands into the user turn on
invocation and costs nothing resident. The catalog is now **10 skills /
4 651 description bytes**. Keep the 12-skill figures above as the
measurement of record: they are what the argument was derived from, and
re-deriving against a shrinking catalog would quietly move the goalposts.
Note what the shrink cost, too — `grill-me`'s description carried a
genuine lexical model trigger (*"or mentions 'grill me'"*), so as a
command it now fires only on `/grill-me` and no longer on the phrase in
prose. That is the trade this whole category makes: **zero resident cost
buys up exactly the model-invocability you were paying for.** Cheap for
`wh`, a real loss for `grill-me`, and the author's call either way — which
is the same "a human decides at wiring time" principle that settled the
sub-agent question in claim 2.1.

**Aside worth noticing:** all 12 skills came from `~/.claude/skills`;
nothing from `.pikuri/skills` or `.agents/skills`, and nothing
project-local. pikuri's catalog today is *somebody else's* catalog, with
descriptions authored against Claude Code's preamble and Claude-sized
models. That is a confound in every activation argument here — see open
question 10.


### Two riders on the synthesis

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
  question 11 below remain prerequisites, not alternatives.


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
loss on Anthropic. (Open question 8, shared with the activation note.)


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
cases where the model does pause to check. It also means open question 9's
fair test should be read carefully: skills that fire on description alone
will skew toward the capability-shaped ones (`dataviz`, `gh-auth`), and
that's a real result, not a confound — it just doesn't generalize to the
correction-shaped ones, which are the ones anybody bothered to nudge.

### 2. Tier 0 is a security win, not only a token win — with one prerequisite

Not mentioned anywhere above: **a skill is untrusted text**.
{Pikuri::Skill::SkillTool} declares `untrusted: :hard` in its
`trifecta_legs`, with the reasoning that a bundle travels between
harnesses and the tool can't tell a hand-written skill from a downloaded
`.agents/` one. A 28-entry catalog is therefore ~3.8 k *tokens* of
attacker-influenceable prose (this repo's 12-skill catalog: 4.6 KB)
sitting in the **system prompt** — the most-trusted position in the
request — on every single turn, for skills the session will never use.
(An earlier draft wrote "3.8 KB", transcribing the cost note's token
figure as bytes.)

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

**Two corrections to how far that argument reaches.** First, it is an
argument for *removing* descriptions, not for *relocating* them — a tool
description (observation 4) is model-facing prefix text too, so moving
the catalog there shrinks the untrusted surface by exactly zero. Second,
and this is the awkward one: **promotion makes the per-skill trust story
worse, not better.** A promoted description arrives via
`Control::Interloper`'s `:system` kind, which Anthropic hoists into the
top-level system param — so a gated skill's untrusted description ends up
in a *more* trusted slot than the `<available_skills>` block it was
withheld from, and sticks there for the rest of the conversation. Tier 0
shrinks the aggregate and concentrates the remainder. Which promotes the
MCP-parity scan from a nice-to-have to a **prerequisite of promotion**
(open question 2).

**The other prerequisite — smaller than it reads, and owed earlier than
stated.** The argument only holds if names are *actually* constrained,
and pikuri's validation is deliberately lenient: `Catalog::Bundled`'s
header says "invalid name chars … log a warning and load anyway". But
`#validate_name` *already* checks the standard's shape — `/\A[a-z0-9-]+\z/`
plus the 64-char cap, the leading/trailing hyphen and the `--` cases — and
merely warns. The change is one word: `warn` → skip. And it is owed not
to tier 0 but to **cheap borrow 1**: the moment names become a tool-schema
`enum`, a lenient name is injected text in the *tool schema*, which is if
anything a worse position than a prompt block. So the strictness reversal
is a prerequisite of the enum, and the enum is what everything else here
is built on. It is a mild break from the lenient-validation posture —
exactly the kind of thing that belongs in the `DECISIONS.md` entry this
note already routes to.

(Descriptions get no sanitizing at all today. `Renderer.escape_xml` is
tag-forgery defense — it stops a description closing `</available_skills>`
and opening something else — not instruction defense, and nothing in the
note above should be read as claiming otherwise.)

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

### 4. A third placement for the inventory: the tool description

(Now open question 4.) The choices on the table were the schema enum or a
system-prompt block. There's a third, and it's the one pikuri explicitly
ruled out: put the catalog in
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

**Correction to the "cleaner end-state" framing: this is a rival to the
tier table, not a refinement of it.** "Everything rides the tool" is a
*one home* claim, and one home survives only while there is no promotion
mechanism — the first promoted description is a second home by
construction. Separating the axes makes both usable and shows they are
independent:

| axis | options |
|---|---|
| **what the baseline contains** | names only (tier 0) / names + descriptions |
| **where the baseline lives** | system-prompt block / tool description + enum |
| **how a promotion arrives** | interloper injection — the only option, either way |

Observation 4 answers the *middle* row and nothing else. Its real virtue
is therefore narrower than "one home", and better: it makes the inventory
**persona-correct by construction** — the live bug from claim 2.1 — and it
does that whether the baseline is names-only or full. Which also means it
can ship first, alone, as a bug fix, without deciding tier 0 at all.


## Contradictions, resolved (2026-08-16)

Eight tensions the note was carrying without naming. Each is settled here
so the open list below is genuinely open.

### R1. Tier 0 withholds the descriptions that *work* and keeps the ones that *don't*

The sharpest one, and it was hiding in plain sight between claim 1 and the
synthesis. Observation 1 says descriptions fail for **correction-shaped**
skills (`cop`) and succeed for **capability/lexical-shaped** ones
(`dataviz`, `gradle`). But the `paths:`-implies-withhold rule gates exactly
the lexical ones — a skill whose trigger is a file glob is by construction
the kind whose description *would* have fired. So tier 0 removes the
working half of the catalog and leaves the failing half resident, and a
gated skill now needs **two** things to go right (the glob fires *and* the
model acts on an injected description) where it previously needed one.

**Resolution: tier 0 is a cost measure, not an activation measure, and
must stop being sold as both.** The note currently argues it as an
activation improvement ("the skill shows up at the moment the work
starts") and a cost improvement, and only the second survives R1. The
activation claim belongs entirely to `skill-path-activation.md`'s trigger,
and *there* it is defensible for a different reason — the glob fires on
something the model doesn't have to notice, which is the failure
observation 1 identifies. Two mechanisms, two arguments; the catalog note
owns only the cost one.

Corollary: if the saving is ~200 tokens per turn (measured above, after
the 3× correction) and the activation story is neutral-to-worse, tier 0's
case rests on catalog *size* — and thinly, because what the correction cut
was the ratio, not the count, so a bigger catalog scales a smaller
fraction. Open question 8 stays the deciding measurement, but the burden
it has to clear went up.

### R2. The hand-written nudges are asking for a *deterministic* channel, not a better advisory one

Claim 1 reads the five `~/.claude/CLAUDE.md` nudges as evidence that the
catalog fails to trigger. Re-read them and three of the five are not
"consider this skill" at all — they are *"read and follow the listed skill
file before doing work"*. That is a **policy**, and no description-based
mechanism can express it, because descriptions are advisory by nature. The
nudge exists because the user wanted `gradle` **loaded**, unconditionally,
in a Gradle project — tier 2, not tier 1. `paths:` promotion would not
have satisfied it either; grok-build's promotes to a listing too.

**Resolution: the under-built thing is the host-driven load path, not the
trigger.** pikuri already has the seam that models "the operator decided
this skill is in force for this session" —
{Pikuri::Skill::Extension#schedule_load_skill} — and claim 2.4 already
notes no `bin/` exposes it. Those two observations were sitting in the same
note without being connected. And the trust basis is the part that makes
this legitimate where body pre-injection isn't: a `paths:` in a downloaded
bundle deciding to occupy 4 k of your context is the skill *author*
spending your window, which `skill-cost-model.md` rightly rejects; an
operator wiring "in a Gradle project, load `gradle`" is a human spending
their own. Same mechanism, different hand on it, opposite verdict. See
open question 7.

### R3. Length economics split per skill, and the note's two halves are compatible

Open question 11's revision concludes "pay the words, spend them on the
trigger" — longer descriptions. The synthesis concludes "withhold
descriptions". Read as a global rule those fight; read per skill they
compose exactly:

- **Gated skill** — description paid only on activation, to a model that
  is *already* in a matching file. It can afford to be fat and
  trigger-heavy; it is tier-2-adjacent pricing.
- **Ungated skill** — resident forever, in every session. Must be tight,
  and must lead with the trigger, because it is competing for attention on
  every decoded token.

So tier 0 doesn't override the authoring guidance; it **splits the budget
in two** and tells an author which one they opted into by writing `paths:`.
That is a better answer than either half alone and it should survive into
the authoring guidance regardless of whether tier 0 ships.

### R4. `paths:` gating is advisory-only — it is never an access control

Observation 3 requires the enum to carry *every* name, gated ones
included, or a promoted skill would be un-callable. The direct consequence,
nowhere stated: **the model can load a gated skill's body at any time**, by
reading a bare name off the enum and guessing it's relevant. Gating hides a
description; it restricts nothing.

That is fine — it is the same posture as `<available_mcps>` and it's what
makes the mechanism cheap. But someone will eventually reach for `paths:`
as "this skill only applies to Java projects, so keep it away from the
model", and it does not do that. Worth an explicit non-claim in whatever
yardoc lands, because the feature's name invites the misreading.

### R5. Activation state cannot live in the catalog — it is frozen

`Catalog::Bundled#initialize` ends with `@skills.freeze`, `@list.freeze`
and `freeze`. `skill-path-activation.md`'s implementation sketch calls
`@catalog.activate_for_paths(paths)`, which would raise `FrozenError`.
Not fatal — activation state belongs in the listener anyway — but the
sketch needs correcting, and there is a nicer reading of the constraint:
**the frozen catalog is what makes tier 0's baseline stateless**, which is
why old question 8 answers itself (below). Any design that mutates the
catalog per session breaks a deep freeze that is currently load-bearing.
Routed to the sister note, which owns the mechanism.

### R6. The direct-read fallback door dies as a side effect of two separately-argued changes

`skill-cost-model.md` cheap borrow 4 drops `<location>` from the catalog
render, with a noted counter-argument: `location` is what lets the model
`read` a `SKILL.md` directly if the `skill` tool is ever absent, and
`Filesystem#readable:` is wired for exactly that. Tier 0 removes locations
too (the rider says so outright). Neither change argues the point; both
assume the other will keep the door open.

**Resolution: decide it once, deliberately, and the answer is probably
"close it".** The tool is auto-registered whenever the catalog is
non-empty, so the fallback covers a configuration that cannot occur through
`Extension`. But it should be closed on purpose, in one commit, with the
coupling recorded — not fall out of two independent optimizations neither
of which owned it.

### R7. Old question 8 (`clear_conversation`) answers itself under tier 0

Asked whether tier 0 changes what a clear restores. It doesn't, and the
reason is structural rather than lucky: **the tier-0 baseline holds no
per-session state**, so there is nothing to rehide. grok-build needs an
explicit `rehide` on `/clear` precisely because its baseline *mutates*;
pikuri's would not. Promotions were injections, injections are discarded,
the rebuilt prompt is byte-identical to boot. The only residue is the one
already noted — a long session that clears re-pays its activations, which
is open question 8's measurement and not a semantics question. Dropped
from the open list.


### R8. "Descriptions don't fire reliably, therefore drop them" — the premises hold, the inference doesn't

The author's sharpest formulation, 2026-08-16:

> LLM is notoriously unreliable to auto-load skills; usually they're
> loaded either by human operator manually or by LLM when explicitly told
> to do so by CLAUDE.md; therefore skill descriptions do not work as a
> reliable auto-loading mechanism; therefore it doesn't make much sense
> to have skill descriptions in the context.

This is a cleaner statement of claim 2 than the note had, and it is worth
answering step by step because the first two steps are granted and the
third does not follow.

**"Reliable" is the wrong bar.** A description is not a *mechanism*, it is
a **prior**. It costs ~95 tokens resident; it does not have to fire
reliably, it has to fire often enough to beat the alternative — and the
alternative, per `skill-cost-model.md`'s closing observation, is the model
doing half its recon under the wrong mental model and redoing it, which
costs far more context than the description *and* the body combined. The
break-even hit rate is therefore very low, and **nothing in the evidence
measures it.** What the evidence measures is the complement.

**There is no denominator.** The dataset is five hand-written nudges.
There is no record of the times a description fired and the work simply
went right, because those are invisible by construction — which is claim
1's own caveat ("you only notice the nudges you had to write") applied to
the conclusion rather than the premise. You cannot get from *"I wrote five
nudges"* to *"descriptions never fire"* without knowing how many skills
never needed one.

**grok-build does not support the conclusion** — a factual correction,
since the survey is doing real work in this argument. grok-build ships
descriptions in `<available_skills>` for every *unconditional* skill
(`take_unconditional`); `paths:` gates only the conditional subset, and
even then activation promotes to a listing that **includes the
description**. Claude Code, PI, opencode v2 and grok-build all keep
descriptions resident. **No surveyed harness ships a names-only catalog.**
grok-build agrees with tier 0's `paths:`-implies-withhold rule; it does
not agree that descriptions are pointless.

**The authoring-style confound, which is the testable rival.** The 12
skills the measurement found on disk are all hand-written by the author.
The 28-skill figure includes Anthropic-shipped *plugin* skills, and the
two groups are written differently:

| | where the trigger sits |
|---|---|
| `cop` (author's) | ~800 chars of content summary, *then* "Read this skill before designing UI components…" |
| `writing-rdoc` (author's) | gerund opener, the numbered gist, trigger repeated last |
| `dataviz` (plugin) | opens with "Use this skill whenever you are about to create ANY chart…", plus an explicit `Triggers on:` lexical list |
| `claude-api` (plugin) | opens with a literal `TRIGGER —` block, enumerates observable conditions, then `SKIP only when … (overrides all triggers)` with a cheap disambiguation procedure |

Every skill that needed a hand-written nudge is in the first group. The
people who ship skills professionally escalated the trigger **into the
description** rather than reaching for a CLAUDE.md nudge. So the honest
reading of claim 1's evidence is that it is evidence about *this catalog's
authoring style*, not about descriptions as a mechanism.

**And there is a plausible causal story for why the first group
under-fires, which the note had not considered: a description that
summarizes the skill teaches the model it does not need the skill.**
`cop`'s description contains the four rules. A model reading "composition
over inheritance, dependencies point toward data" has been *given the
gist* and has no felt gap — which is exactly observation 1's
correction-shaped failure, except self-inflicted by the description rather
than inherent to the skill. Note that `claude-api` and `dataviz` carry
almost no content summary: they say what they *cover* and then spend the
whole budget on when to reach for them. That is a mechanism, it predicts
the observed behaviour, and it is falsifiable for the price of rewriting
two descriptions (open question 9).

**Resolution: the premises stand, the inference is rejected, and the
cheapest next move is a description rewrite, not a mechanism.** Rewrite
`cop` and `writing-rdoc` in `claude-api`'s shape — trigger first, timing
verb ("before writing the class declaration"), an anti-rationalization
clause, enumerated *observable* cues, and a SKIP clause with explicit
precedence — drop the numbered gist, delete the corresponding CLAUDE.md
nudges, and see whether they fire. Leave `writing-javadoc` untouched as a
control. If they fire, this whole family of notes is unnecessary and the
fix was free. If they don't, claim 1 is confirmed *for correction-shaped
skills specifically* and R2's answer applies: build the deterministic host
load path, which is what the nudges were asking for all along.

Two concessions to the statement, both real:

- **The counterfactual bites in a picker-driven host.** If a human always
  drives a skill picker, the resident descriptions genuinely bought
  nothing *in that workflow*, and names-only is defensible there. This is
  the author's objection in claim 2.1 and it survives R8 intact.
- **Target-model dependence, uncovered by any evidence here.** Every
  anecdote and number in this note came from a frontier model over a
  catalog authored for it. pikuri defaults to local llama.cpp, where the
  prior is far weaker — so the answer may legitimately differ by model,
  and the description-side fix may work on Claude and not on a 7B. Open
  question 10.


## Open questions

Ordered by what blocks what, not by interest. Items 1–3 are owed
regardless of how the forks settle; 4–7 are the forks; 8–10 are the
measurements that decide them; 11–15 are content and compatibility.

### Owed regardless

1. **Enum-constrain `SkillTool`'s `name` — and price in the leniency
   reversal.** `skill-cost-model.md` cheap borrow 1, which everything
   here builds on: it is tier 0's carrier (rider 1), it is what survives a
   persona replacing the system prompt (observation 4), and observation 3
   fixes its shape (every name, byte-stable for the session). But it is
   **not** the advertised one-liner — per observation 2, an enum built
   from leniently-validated names puts arbitrary text in the tool schema,
   so `Catalog::Bundled#validate_name` must go `warn` → skip in the same
   commit. That is a documented-posture reversal and needs the
   `DECISIONS.md` line. Open: skip the skill entirely, or load it and
   omit it from the enum (unreachable but visible in logs)?
2. **Scan skill descriptions for injection, at MCP parity — and where
   does the scan live?** Observation 2's asymmetry is real and live today:
   `<available_mcps>` descriptions get `Mcp::Verifier` before they reach
   the LLM (on by default, `verify_mcp_servers: true`),
   `<available_skills>` descriptions get nothing. The obvious fix has a
   structural problem the note hasn't faced: the MCP verifier is an **LLM
   pass** wired at `Agent#initialize` with a transport in hand, whereas
   `Catalog::Bundled` is constructed *before* the agent, is pure, takes no
   transport, and freezes itself. So parity is not a copy-paste. Options:
   move the scan to `Skill::Extension#configure` (has the agent, but the
   catalog is already built and shared); a cheaper static tripwire
   (`ideas/injection-tripwire.md`); or accept the asymmetry and document
   why. Not optional if promotion ships — R1's injection channel lands
   these descriptions in the *system* param on Anthropic.
3. **Fix `SkillTool`'s description, which lies to a sub-agent.** It points
   at `<available_skills>` three times; a persona that lists `skill` has no
   such block. Independent of every fork, and it pairs with
   `skill-cost-model.md` cheap borrow 3 (the stale "opencode is the
   outlier" sentence in the same class header) — one pass, one commit.

### The forks

4. **Where does the baseline live — system-prompt block, or tool
   description + enum?** Observation 4's middle row, and the only fork
   that can ship alone: it fixes item 3's bug by construction and decides
   nothing about tier 0. Against it: the `SkillTool` header's convention
   argument (PI and Claude Code put the inventory in the prompt) is real
   and needs rebutting rather than ignoring, and opencode v2 moved *to*
   the prompt, not away from it. For it: a persona inherits the tool
   verbatim and overwrites the prompt, so the tool is the only home that
   is correct for both agent kinds. Residual from the resolved sub-agent
   question: this makes a persona's skill access all-or-nothing on
   `tool_names:`, which is fine until someone wants a subset.
5. **Does tier 0 earn it — now that it's a cost argument only?** Per R1,
   the activation half belongs to the sister note, so this turns purely on
   catalog size. Measured here, after authoring the frontmatter rather
   than estimating it: **17 % of description bytes, ~200 tokens per turn**,
   ~0.3 % of a 64 k window — against a permanent complexity cost (a
   matcher, a listener, a path-args map, an injection channel, a
   per-activation Anthropic cache nuke). My read hardened from "not at 12
   skills" to **probably not at any size**: the 3× correction hit the
   *ratio*, so a 28-skill catalog gates the same thin fraction. Open
   question 8 still decides it, but it now has a much higher bar to clear.
6. **Is `disable-model-invocation:` the cheaper first cut?** The category
   the measurement surfaced, not the argument: `wh` and `grill-me` are
   slash-command-only skills paying resident tokens to tell the model to
   ignore them. Withholding *those* costs no matcher, no injection, no
   cache invalidation and no new failure mode — it is strictly free, where
   `paths:` gating is a trade. It also composes with everything above
   (not in the prompt, not in the enum, reachable only via
   `schedule_load_skill`). Same non-standard-key cost as `paths:` and
   `when-to-use:` (question 12), and the same grok-build spelling
   available. Should this ship *before* tier 0 is even decided?

   **Two answers, 2026-08-16.**

   *(a) An empty `paths:` is not the spelling.* Asked whether `paths: []`
   could express "human-only" for free, since a skill that never matches
   is never promoted. It would work, and it should still be rejected on
   four counts: it is a **coincidence, not a declaration** (the two
   propositions coincide only under today's promotion rule — add a second
   trigger and `paths: []` silently stops meaning "never"); it is a
   **YAML footgun with an inverted failure**, because absent-`paths:`
   means *always advertised* and a bare `paths:` with nothing under it
   parses to `nil` rather than `[]`, so the author types the thing that
   means "hide" and gets "advertise"; it **does not reach zero**, since
   per R4 the enum must carry every gated name, leaving the skill both
   resident and loadable; and it makes the **cheap feature depend on the
   expensive one** — `disable-model-invocation:` needs no matcher, no
   listener, no path-args map, no injection channel and costs no cache
   invalidation, where `paths:` needs all five.

   *(b) It acquires a hard dependency, and that is the finding.* A
   `disable-model-invocation:` skill is reachable **only** through
   {Pikuri::Skill::Extension#schedule_load_skill}. No bundled `bin/`
   exposes it (claim 2.4), so shipping this key into pikuri today would
   make such a skill unloadable outright. **Question 6 therefore depends
   on question 7** — the two are not independent ideas to weigh against
   each other, and the host load path is now the prerequisite of two
   separate features plus R2's whole argument. That is the third
   independent route to the same conclusion, which is about as much
   convergence as an idea note ever gets.

   Corroborating detail from the catalog: `wh` is the only one of the 12
   skills carrying `argument-hint:` — a **slash-command** frontmatter key,
   not an Agent Skills one. It was authored as a command all along and
   filed as a skill, which is why it spent 51 resident bytes telling the
   model to ignore it. Resolved outside pikuri by moving it to
   `~/.claude/commands/`, where a slash command is expanded into the user
   turn on invocation and costs nothing resident — the same zero-round-trip
   human path opencode and grok-build ship. Worth noting as the honest
   baseline: **for a purely human-invoked skill, the existing
   slash-command mechanism already solves this, and neither `paths:` nor
   `disable-model-invocation:` is needed at all.** The key only earns its
   way in for a skill that must stay in the *catalog* (sidecar files,
   `roots` wiring) while staying out of the *prompt*.
7. **Should the host-driven load path be built before any trigger?** R2's
   conclusion: the hand-written nudges are asking for deterministic
   loading, which is {Pikuri::Skill::Extension#schedule_load_skill} — a
   seam that exists, is main-agent-only, and that no bundled `bin/`
   exposes. Exposing it in `bin/pikuri-code` (a `/skill <name>` line, or a
   boot-time "in a Gradle project, load `gradle`" wiring) is small, tests
   the whole premise cheaply, and is the honest answer to the feedback
   this family of notes came from. Caveat, and it's the reason this isn't
   already done: CLAUDE.md's own rule says a `bin/` demo's shortcut is not
   evidence about the library — so this must be argued as "the library
   seam is under-exercised", not "the demo needs a feature".

### Measurements that decide the forks

8. **How many activations per session, and how big is a real catalog?**
   Two numbers, one listener. The first decides the Anthropic cache trade
   (1–3 is noise; fifteen makes tier 0 a net loss on that provider); the
   second decides question 5, since the whole case scales with skills
   installed and this repo's 12 do not clear the bar. Measurable today
   with a throwaway listener over `Event::ToolCall`, before anything is
   built. (Shared with `skill-path-activation.md`, which owns the
   mechanism side.)
9. **Does claim 1 survive a fair test?** The nudge list is
   selection-biased — you only notice the nudges you had to write. Two
   experiments, both cheap, and R8 makes the second the sharper one:
   (a) take the skills *without* a CLAUDE.md nudge and check whether they
   ever fire on description alone; (b) **rewrite the nudged descriptions
   in `claude-api`'s shape and delete the nudges.** `cop` and
   `writing-rdoc` were rewritten 2026-08-16 (trigger first, timing verb,
   anti-rationalization clause, enumerated observable cues, SKIP clause
   with precedence, numbered gist dropped); `writing-javadoc` was left in
   the old shape as a **control**. Confound still standing at the time of
   writing: the CLAUDE.md nudges for both were *not* removed, so a fire
   cannot yet be attributed to the description. Remove them before
   reading any result.
10. **Is a bare name a strong enough recall cue — on a *local* model?**
    Tier 0 assumes a model seeing `karibu-testing` in a name list will
    reach for it once the path fires and the description arrives.
    Plausible, untested, and the test that matters is not the one the
    evidence came from: pikuri is local-llama.cpp-by-default, and every
    number and anecdote in this note came from Claude Code, over a catalog
    authored for Claude Code (see the measurement's aside — all 12 skills
    are `~/.claude/skills`, none pikuri-native). That cuts both ways: a
    small model is *more* likely to ignore an advisory description
    (strengthening claim 1) and *less* likely to recall from a bare name
    (weakening tier 0). Failure mode to watch: the model ignores the
    name-only entry *and* the injected description, because the latter
    arrived mid-turn rather than in the prompt it was primed on. Cheapest
    probe: hand-render tier 0 for this catalog and try it against the
    local model — no code required.

### Content and compatibility

11. **Say-*when* vs. stay-short — the per-entry content tension.** (Moved
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
      later, but a non-standard key (see question 12); (iv) truncate in
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

    **Second revision, after R3.** The tension is not global, it is
    per skill: a gated description is paid on activation to a model
    already in a matching file and can afford to be fat and
    trigger-heavy; an ungated one is resident forever and must be tight.
    So the answer to "say when or stay short" is *both*, split by whether
    the author wrote `paths:` — which is guidance worth writing down even
    if tier 0 never ships.
12. **Is `when-to-use:` the better cut?** grok-build splits the trigger
    out of the description as its own frontmatter field. Tier 0 withholds
    the *whole* description; a `when-to-use:` split would let the baseline
    carry name + trigger (cheap, and the part that decides activation)
    while withholding the narrative (expensive, and only useful once
    you've decided). Strictly better shaped, one more non-standard key —
    and the same compatibility cost `paths:` carries in the activation
    note, and now `disable-model-invocation:` in question 6. **Three
    non-standard keys is no longer three separate small costs**; it is a
    dialect. If any of them lands, they should be justified and spelled
    (grok-build's spelling) in one pass, so at least two harnesses agree.
13. **Where do we say `paths:` is not an access control?** Per R4, the
    enum must carry every name, so a gated skill's body is loadable at
    any time — gating hides a description and restricts nothing. Correct
    and cheap, but the feature's name invites the opposite reading, and
    someone will eventually gate a skill *hoping* to keep it from the
    model. One explicit non-claim, in {Pikuri::Skill::Catalog}'s yardoc
    next to the `paths:` semantics — assuming they ever exist.
14. **Close the direct-read fallback door on purpose.** Per R6, dropping
    `<location>` (cost-note borrow 4) and tier 0 each independently
    remove the model's ability to `read` a `SKILL.md` directly, and
    neither argues the point. Decide once, in one commit, and record the
    coupling — the `Filesystem#readable:` wiring of `catalog.roots` exists
    to serve that door and becomes vestigial if it closes.
15. **What does a *human* see?** The author's framing — being handed the
    Tuile manual at the moment you open a Tuile file — is a UX claim, not
    a token claim, and it's the part with no counter-argument. If
    promotion lands, the render must be legible in a TUI, not just a
    model-facing `<system-reminder>`. Mechanism side:
    `skill-path-activation.md`'s question about a dedicated event vs.
    `Event::SystemInjected`, which this note upgrades from a rendering
    nicety to the feature's actual selling point. One reassurance the
    note never gave itself: **withholding costs the model's view, never
    the human's** — descriptions stay on disk, so a host picker renders
    the full catalog under every design here.

**Closed since the last revision:** *"who lists skills for a sub-agent?"*
— answered by `tool_names:`, which already is the opt-in; residual folded
into question 4. *"does tier 0 change what `clear_conversation`
restores?"* — no, per R7.


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
- The **authoring guidance** from question 11 (lead with the trigger, cut
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
- **The persona fact is now settled and should graduate on its own**, not
  wait for the forks: *a sub-agent gets skills only if its persona names
  `skill` in `tool_names:`, and no bundled persona does* →
  {Pikuri::SubAgent::Persona}'s yardoc, which is currently silent in both
  directions (which is why the gap looked bigger than it is).
  {Pikuri::SubAgent::SubAgentTool}'s header already carries the general
  form ("one that needs MCP / Skills ships its own wiring"); `Persona` is
  where someone writing one will look.
- **`SkillTool`'s description bug graduates as a fix, not a nugget** — it
  points at `<available_skills>` three times, which is false under a
  persona. Land it with cost-note borrow 3 (the stale "opencode is the
  outlier" sentence in the same header).
- **The pikuri-catalog measurement** (12 skills, 44:1 names-to-
  descriptions, **17 %** of description bytes cleanly path-gated, ~200
  tokens/turn) is the number that makes tier 0 decidable rather than
  arguable. If tier 0 is rejected, it is the *reason* — so it belongs in
  the `DECISIONS.md` entry, next to the 40:1 ratio and outliving both.
  Carry the **3× correction** with it, not just the final figure: the
  estimate-vs-authored gap is the part a future reader needs, because the
  next person to propose this will arrive with an estimate too.
- **R2's reframe outlives every fork**: the hand-written CLAUDE.md nudges
  are asking for *deterministic* loading, which is the host path, not a
  trigger. That is the sentence
  {Pikuri::Skill::Extension#schedule_load_skill}'s yardoc is missing —
  *why* a host load exists at all, as opposed to trusting the catalog —
  and it merges with the two sentences already routed there.
- **R4's non-claim** (gating hides a description, it restricts nothing) and
  **R6's coupling** (closing the direct-read door) are both facts that
  only exist once something ships; if nothing does, they die with the
  note and that is correct.
