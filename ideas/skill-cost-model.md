# What skills actually cost in context — the shared evidence base

Status: **measurements + settled dispositions; every fork this note fed is
now closed** (2026-08-17 — `paths:` gating shipped and is the whole of what
the skills surface earned; see `D-skill-path-activation`, *this is where the
skills-surface work stops*). What keeps the note alive is the evidence base
itself: the tier costs and the KV-cache section are cited from the decision
and from the sister notes, and borrow 7 waits on compaction existing.
Origin: `feedback.txt` item 3 ("skill load costs a
turn"), which asked for one of three things: path-triggered
auto-injection, a batch `skill` call, or at least for skill-loading to
feel like the *expected opening move* rather than a surprise tax.

The framing was the first thing to fix, and then two of the three asks
mostly dissolved. What was left was not one question but three, so this
note kept the part that is *evidence* — what each tier costs, what the KV
cache does and does not refund, and what the other harnesses ship — and
handed the live forks to the notes below.

**Scope.** This note owns the numbers and the prior art, so the other two
can argue without re-deriving them. It does **not** decide what the
catalog should contain (→ `skill-catalog-in-context.md`) or how the
shipped `paths:` trigger is wired (→ `DECISIONS.md`
`D-skill-path-activation`).
Anything
here that turns into a fork belongs over there.

Related:

- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — *what*
  the resident catalog advertises. Consumed the tier measurements and the
  caching section below, and is now down to two bullets of prose owed to
  the book: every mechanism question on that axis closed 2026-08-17.
- `DECISIONS.md` `D-skill-path-activation` — *when* an entry is promoted;
  shipped 2026-08-17, and it consumed the grok-build survey below.
- [`tool-list-in-context.md`](tool-list-in-context.md) — the same
  resident-prefix arithmetic applied to tool schemas, which turn out to
  be ~4× the skill catalog.
- [`claude-parity.md`](claude-parity.md) — its one live open item,
  "Skill-invocation emphasis — measure", is item 3(c) below. Whichever
  note survives, these two should merge.
- [`grok-build-cheap-borrows.md`](grok-build-cheap-borrows.md) — a
  *different* set of borrows from the same survey (Edit/Read shaped).
  Same name, no overlap; the ones below are all skills-surface.
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

Two nuances worth keeping honest:

- **Latency isn't nothing.** On a cacheless local llama.cpp an extra
  round-trip is a full prefill. But it is *one* turn and it doesn't scale
  with skill size, whereas pre-injection re-prefills 4 k tokens on every
  subsequent turn. The latency argument points the same way as the token
  one.
- **On Anthropic, a host-loaded skill is sticky.** `:system` messages get
  hoisted into the top-level system param, so
  {Pikuri::Skill::Extension#schedule_load_skill}'s injection stays in
  force for the whole conversation — 4 k tokens per turn, not once. Any
  auto-load design must reckon with that; the `skill` tool's observation
  is a one-shot and doesn't have the problem.


## Measured: what each tier costs

### Tier 1, at real catalog size

Claude Code's `/context` on this machine, 2026-08-16 — a real 28-skill
catalog, which is the closest thing to evidence available. (Its
accounting, not pikuri's, but the number is dominated by description
length either way.)

- **28 skills → 3.8 k tokens** of catalog, every turn: 1.5 % of a 256 k
  window, ~6 % of 64 k. (An earlier draft here cited 12 % against a 32 k
  window. Not a fair benchmark — any host doing real coding work runs
  64 k+, and pikuri's own `/props` probe reads whatever the server
  actually serves. The percentage is not where the argument lives.)

  Where it *does* live: this is paid **every turn, by every session,
  forever**, and it scales with skills *installed* rather than skills
  used. A body is paid once, by the session that asked. That asymmetry is
  the whole point and it holds at any window size.
- Per-entry: `dataviz` ~380, `claude-api` ~360, `cop` ~310,
  `update-config` ~240, `writing-rdoc` ~210. The Agent Skills spec
  budgets **50–100 tokens per entry**. These are 3–6× over.
- `cop`: catalog entry ~310 tokens, body ~2 800. So tier 1 : tier 2 is
  about **1:9** for a single skill — but tier 1 is paid every turn by
  every session, and tier 2 only by the session that asked.

### Tier 0 vs tier 1 — names are 40× cheaper than descriptions

Measured 2026-08-16 on `~/.claude/skills` (12 on-disk skills; the 28 /
3.8 k figure above is Claude Code's own accounting and includes plugin
skills):

| tier | resident | cost, 12 skills |
|---|---|---|
| 0 | `<name>` only | 116 B of names, ~250 B rendered → **~65 tok** |
| 1 | + `<description>` | 4 587 B → **~1.5 k tok** rendered |
| 2 | body | 2–30 KB each, on the `skill` call |

That 40:1 ratio is the load-bearing number for
[`skill-catalog-in-context.md`](skill-catalog-in-context.md), which owns
what to do about it.

Two things follow from the tier-1 numbers here. First, the item-3 framing
is confirmed from the other side: the expensive thing is what's resident,
not what a call costs. Second, **the over-budget descriptions are the
cheapest thing on this whole list to fix**, and nothing about them
requires a mechanism — the reason they're fat is visible in the same
table, since `claude-api` and `dataviz` carry TRIGGER/SKIP blocks inside
their `description`. The description has started doing the skill's job.
(That tension — say *when* vs. stay short — is a what-an-entry-contains
question and moved to the catalog note.)


## Does the KV cache neutralize the length? (author's question, 2026-08-16)

Partly — and working out *which* part turns out to matter more than the
token counts above. This section is the reason none of these notes can be
argued in raw token counts; read it before quoting any number.

| cost | neutralized by caching? |
|---|---|
| **prefill / latency** | **Yes, essentially.** The catalog sits in the stable system prefix, so llama.cpp's slot prefix-reuse and Anthropic's prompt cache both skip it after turn one. This is the cost the "3.8 k every turn" phrasing implies, and for it the phrasing is wrong. |
| **window capacity** | **No.** Cached tokens still occupy KV slots. 3.8 k of a 64 k window is 3.8 k the conversation can't have, cache or no cache — and on a local GPU it's VRAM held for the whole session. |
| **attention** | **No, and this is the real one.** Every decoded token attends over the whole prefix. Twenty-eight skill descriptions the current task will never use are twenty-eight distractors competing for attention on every single token. No cache touches this. |
| **cloud spend** | **Mostly.** Anthropic cache reads are ~0.1×, not 0×; writes are 1.25×. Cheap, not free. |

So the honest correction: the naive "4 000 tokens **per turn**" framing
overstates it in compute terms, and pre-injection is less catastrophic
than that arithmetic implies. What survives is capacity and attention —
you pay for skills you don't use, in every session, in the two currencies
no cache refunds. Note that both of those scale with catalog **size**, so
no amount of per-entry editing fixes them; only removing entries does.

**The inversion.** Once caching is in the picture, the expensive operation
is not *length*, it's **mutating the prefix**. A stable prefix is free
after turn one; a prefix that changes invalidates everything after the
change point and re-prefills. Which means pikuri's current shape is
accidentally the cache-optimal one:

- the catalog lives in the **assemble-once system prompt** — the most
  stable, best-cached position available;
- the body arrives as a **tool result appended at the end** — append-only,
  so it invalidates nothing and is itself cached from the next turn.

Three consequences, each of which is a *cost* the sister notes have to
carry:

1. `assemble_system_prompt` building once and never amending is not only
   a limitation — it's a cache virtue. Any "amend the system prompt
   mid-conversation" seam (opencode's `SystemContext` delta re-render, or
   a catalog that grows entries as skills activate) buys its flexibility
   by throwing away the cache on every change.
2. The tool path beats the host path (see open question 1): a tool result
   is append-only on *every* provider, whereas the `:system` interloper
   kind is hoisted into the top-level system param on Anthropic — i.e. it
   **rewrites the prefix**, invalidating the entire prompt cache for the
   rest of the conversation. Every host-loaded skill, one full cache
   nuke. The stickiness flagged above is the smaller half of that problem.
3. Anything that promotes a catalog entry mid-session pays (2) **per
   activation**. That makes *"how many activations does a realistic
   session fire?"* a load-bearing measurement for both sister notes.

**Decision (author, 2026-08-16): keep `:system` for the host path, and
don't build anything that leans on Anthropic's hoist-and-stick.** pikuri
can't stop the provider hoisting — that's ruby_llm's Anthropic adapter —
but it can decline to *rely* on the behaviour, and should say plainly in
`schedule_load_skill`'s yardoc that a host load costs an Anthropic prompt
cache on top of the divergence already documented there.


## Prior art: what the other harnesses actually ship

Checked against a local opencode checkout (`~/temp/opencode`,
`4ddfa7c6`), grok-build via `gh api` on `xai-org/grok-build@main`, and
the Agent Skills spec's own client-implementation guide.

### The load tool is one-name-at-a-time, everywhere

| harness | tool input | notes |
|---|---|---|
| pikuri | `name` | |
| opencode | `name` (`core/src/tool/skill.ts`) | v1 and v2 both |
| grok-build | `skill` + optional `args` (`implementations/skills/skill.rs`) | `args` is the slash-command argument, not a batch |

**Nobody batches.** Three independent implementations, none of them
grew a `names: []`. That is weak evidence, but it is the only evidence
available, and it points away from item 3(b).

Also: pikuri already gets the batching for free. ruby_llm executes
*every* tool call in an assistant message (`chat.rb:346`,
`tool_calls.each_value`), so `skill("cop")` + `skill("tuile")` + a `read`
in one message is already one round-trip. Grok's own escape hatch ("if I
can already batch `skill` with other tools, that's enough") is satisfied
by machinery that already exists. A `names:` array would be a second way
to do the same thing — and would make the pathological case (four bodies
in one shot) the easier one to type.

### The catalog is in the system prompt — opencode moved

{Pikuri::Skill::SkillTool}'s header used to say the inventory lives in
the system prompt "as PI and Claude Code do (opencode is the outlier)".
opencode v2 renders `<available_skills>` into a system-context block
(`core/src/skill/guidance.ts`, `SystemContext.Key "core/skill-guidance"`);
only its docs page still claims the tool description. **Corrected
2026-08-16** — the convention is now unanimous, which is also the
strongest argument against sister-note item 4's move.

opencode's version is *live*, though, in a way pikuri's isn't: the block
declares `baseline` / `update` / `removed` renders, so when the skill set
changes mid-session the model gets a delta ("The available skills have
changed. This list supersedes the previous available skills list."), and
when the `skill` tool is denied the block vanishes entirely. pikuri
assembles the system prompt once at construction (and on
`clear_conversation`). Probably fine — pikuri scans at boot and doesn't
watch the filesystem — but it's the mechanism a hot-reload would need,
and per the caching section it is the mechanism that costs a cache.

### grok-build ships item 3(a) — and it does *not* inject the body

The important find, and the one that settles this item. grok-build has
exactly the path trigger Grok asked for: a skill declaring `paths:` globs
in frontmatter is withheld from the catalog until a tool touches a
matching file. But activation emits a `<system-reminder>` **listing** —
name, description, `Use when:`, path — and nothing else, because
(`skill_discovery_tracker/listing.rs`) *"the full skill body is loaded on
invocation, so the listing stays terse."*

So the only shipped implementation of "auto-load on path match" promotes
the skill *into tier 1* and still makes the model spend the tool call for
tier 2. **The trigger fixes ordering; it does not skip the round-trip** —
independent confirmation of the split argued above. Item 3(a) *as asked*
stays rejected here; the reframed version is a different feature and
was accepted as `DECISIONS.md` `D-skill-path-activation` and shipped;
grok-build's implementation detail is in `COMPARISON.md`.

Two more grok-build details in the same area:

- `disable-model-invocation: true` — a skill only the human's slash
  command can fire. `user-invocable: false` — the mirror image.
- `when-to-use:` as a frontmatter field *separate* from `description`,
  with the listing formatter stripping "Use when …" trigger prefixes out
  of the description when both are present. That is a targeted fix for
  exactly the failure Grok reported: descriptions that say what a skill
  *is* but not *when* to reach for it. (Whether to adopt it: catalog
  note.)

### Both harnesses make the *human* path zero-round-trip

Neither harness optimizes the model's load path. Both optimize the
human's, and they do it the same way — by expanding the body at
prompt-assembly time:

- **opencode**: every skill is auto-registered as a slash command whose
  `template` *is* the skill body (`opencode/src/command/index.ts:142`).
  The `/skills` picker (`tui/component/dialog-skill.tsx`) doesn't inject
  anything — it types `/<skill> ` into the prompt input, and the body
  lands as the user message.
- **grok-build**: `/commit fix the build` expands into a
  `<skill_information>` envelope appended after `<user_query>`, with a
  `<skills_referenced>` index of name + path. The source calls it, in so
  many words, "the new zero-round-trip path".

pikuri has this seam already —
{Pikuri::Skill::Extension#schedule_load_skill} — but injects `:system`
rather than folding into the user turn, and no bundled `bin/` exposes it.
The `:user` vs `:system` choice is the interesting divergence, and it is
settled in open question 1 below.

### The spec's own guidance

`agentskills.io/client-implementation/adding-skills-support` codifies the
three tiers (catalog ~50–100 tok/skill → body <5 000 tok recommended →
resources on demand) and says the quiet part out loud: *"Most
implementations rely on the model's own judgment as the activation
mechanism, rather than implementing harness-side trigger matching or
keyword detection."* It also recommends two things pikuri doesn't do —
constraining the tool's `name` parameter to an enum of valid skill names,
and exempting skill content from context compaction.


## Where that leaves the three asks

- **(a) path-triggered auto-injection — no, as asked.** Pays the
  expensive axis unconditionally on any Ruby file touch, and most edits
  under `lib/` aren't component design. Also a glob→skill config table,
  which is the wall-of-JSON pikuri exists as a counter-move to. The
  reframed version — a path glob as a relevance filter that promotes a
  withheld *catalog entry* — is a different feature, shipped as
  `D-skill-path-activation`.
- **(b) batch load — already available**, via parallel tool calls. No
  new parameter.
- **(c) "expected opening move" — a prompt/description problem, not a
  mechanism one.** Merge with `claude-parity.md`'s open measure item; the
  per-entry half is the catalog note's business.


## Open questions

1. ~~**Should the human path fold into the user turn instead of
   `:system`?**~~ **Answered — keep `:system`.** Worth writing down,
   because the three roles in play are easy to conflate:

   | path | role | behaviour |
   |---|---|---|
   | `skill` tool | **tool result** (`:tool`) | positional, one-shot, identical on every provider |
   | `schedule_load_skill` | `:system` | positional on OpenAI-family; hoisted + **sticky** on Anthropic |
   | opencode / grok-build human path | `:user` | folded into the user turn |

   So the tool path — the one that actually runs today — has no provider
   divergence at all. The `:system` question is confined to the host
   path, and `:user` is the wrong answer there for a reason that predates
   this note: an interloper `:user` item fires the
   {Pikuri::Agent::Extension#on_user_message} dispatch, so a skill body
   would trigger memory prefetch and capture as if the human had typed
   it. Reference text isn't a user turn — that's precisely why
   `Control::Interloper` has two kinds. Matching opencode/grok-build here
   would import a bug.

   The residual divergence (Anthropic stickiness) is real but defensible:
   a host-loaded skill *is* session guidance. What deserves stating
   plainly, and currently isn't anywhere, is the **trust** consequence —
   {Pikuri::Skill::SkillTool} declares skills `untrusted: :hard`, and the
   `:system` path promotes that hard-untrusted text from an observation
   to a harness-level instruction, landing in the most-trusted slot in
   the whole prompt on Anthropic. The justification is that a host load
   is human-chosen (a UI picker), so it's trusted by act of selection —
   which is fine, but it's an argument nobody has written down. One
   sentence in `schedule_load_skill`'s yardoc closes it.
2. ~~**One DECISIONS.md entry or two?**~~ **Settled: one**, and it
   governs all three skill notes. Same axis — *what the catalog
   advertises, and when the body arrives* — and entries are mutable, so
   whichever note settles last edits the entry in place rather than
   opening a second. (The tool-gating fork is **not** on this axis and
   gets its own entry; see
   [`tool-list-in-context.md`](tool-list-in-context.md).)


## Cheap borrows spotted along the way

Independent of how the main questions settle; each is small enough to
land on its own.

1. ~~**Enum-constrain `SkillTool`'s `name`.**~~ **Dropped 2026-08-16**,
   with `D-skill-path-activation` decision 5: a gated skill must refuse
   *by name* until its path fires, so an enum of the active set would be
   rebuilt on every promotion, churning the tool schema mid-session. The
   "hands tier 0 for free" argument died with the tier — there is no
   names-only tier any more, a gated skill is withheld outright. Both
   surveyed harnesses agree by construction: the one that hides skills is
   the one that takes a free-form name. Full reasoning in
   [`skill-catalog-in-context.md`](skill-catalog-in-context.md) item 1.
2. ~~**List the skill's sidecar files in the load result.**~~ **Closed
   2026-08-17**, not on its merits — it remains the borrow most directly
   responsive to the feedback — but with the whole skills surface: `paths:`
   gating is what this axis earned, and everything else stays unbuilt by
   decision. See `D-skill-path-activation`, *this is where the
   skills-surface work stops*. For the record, what it would have been:
   opencode globs the skill dir, caps at 10, sorts, excludes `SKILL.md`,
   and emits `<skill_files>` with a "file list is sampled" note;
   grok-build rewrites relative links in the body to absolute paths.
   pikuri says only "sidecar paths … are relative to `<base_dir>`", so a
   model pays a `glob` to discover there are none.
3. ~~**Correct the "opencode is the outlier" sentence**~~ — **done
   2026-08-16**, alongside the sub-agent fix in the same header.
4. ~~**Drop `<location>` from the catalog render.**~~ **Shipped 2026-08-17** —
   gone from `format_catalog` *and* `format_promotion` (one shared
   `entry_lines`, and a promotion is an inventory entry too), with a `refute`
   guard in `renderer_spec.rb` so re-adding it goes red. The counter-argument
   below resolved rather than lost: `Filesystem#readable:` over
   `catalog.roots` is load-bearing for **sidecar reads** and stays either
   way, so what the trim narrows is only the direct-`read`-`SKILL.md`
   fallback, which needs a catalog the `skill` tool cannot serve and
   `Extension` cannot produce. The original case, for the record — the spec
   says outright:
   *"If your dedicated activation tool provides the skill directory path
   in its result, you can omit `location` from the catalog."* pikuri
   emits it in both — `format_catalog`'s `<location>` **and**
   `format_skill`'s `location=` attribute plus the base-dir sentence. The
   catalog copy is the redundant one, and it's not cheap: absolute paths
   like `/home/mavi/.claude/skills/writing-javadoc/SKILL.md` run ~15
   tokens, so a 28-skill catalog pays ~400 tokens for a duplicate. On the
   exact axis these notes are about, and spec-blessed.
   Counter-argument to weigh first: `location` is also what enables
   *file-read activation* (the model `read`s SKILL.md directly, no tool),
   which is the documented fallback if the `skill` tool is ever absent —
   and pikuri wires skill roots into `Filesystem#readable:` precisely so
   that works. Dropping it makes the tool the only door. Probably fine —
   the tool is auto-registered whenever the catalog is non-empty — but
   it's a real coupling, not a pure win.
5. ~~**Dedupe a repeated load.**~~ **Closed 2026-08-17** with the rest of
   the surface, and it had already lost its sharpest edge: the "worse on
   Anthropic, where a host-loaded skill is hoisted and sticky" half is
   stale, since `D-reference-text-as-user-turn` means nothing pikuri
   appends mid-conversation is `role: :system` at all, so repeat loads no
   longer accumulate in the system param. What remains is the plain cost —
   {Pikuri::Skill::SkillTool} re-renders the full body per call, so loading
   `cop` three times pays ~2 800 tokens three times, where the spec's Step
   5 recommends tracking activations and skipping re-injection.
6. ~~**`when-to-use:` frontmatter** — noted, not proposed.~~ **Shipped**,
   on grok-build's spelling rather than one of our own, which is what
   noting it bought. `Catalog::Skill` carries `when_to_use` (accepting
   `when-to-use` or `when_to_use`), `Renderer` emits a `<when-to-use>`
   element in the catalog entry, and `Trigger.strip_prefix` keeps it from
   restating the description.

   **`disable-model-invocation:` is answered and needs no key** (shipped
   2026-08-16). The two skills this note measured as *resident tokens
   spent telling the model to ignore them* — `wh` and `grill-me`, both
   with "only invoked manually" descriptions — were skills filed on the
   wrong surface. They are slash commands, which pikuri now scans from
   `.claude/commands` and never advertises, so the cost is zero by
   construction rather than by a key that suppresses a listing.
   See `DECISIONS.md` `D-slash-commands`.
7. **Compaction, when it ever exists.** The spec's Step 5 says to exempt
   skill content from pruning — losing a skill mid-conversation degrades
   the agent silently, with no error. pikuri doesn't summarize-and-
   continue today (see `claude-parity.md`), so there is nothing to fix;
   recording it because the enabling half is *already* in place — the
   `<skill name="…">` envelope is exactly the tag a future compactor
   would key on. Don't lose that if the envelope is ever restyled.


## Graduation plan (when this settles)

- The 100:1 arithmetic + "the trigger is a relevance filter, not a
  preloader" → {Pikuri::Skill::SkillTool} yardoc, tightening the sentence
  that's already there.
- The rejected forks that are *this note's* (a `names:` array; body
  pre-injection; a glob→skill config table) → the shared `DECISIONS.md`
  entry on the what-the-catalog-advertises-and-when-the-body-arrives
  axis. The sister notes extend that same entry in place.
- Why the host path is `:system` and not `:user` (the `on_user_message`
  dispatch would fire on reference text), the trust consequence of
  promoting hard-untrusted skill text into the system slot, and the
  Anthropic prompt-cache invalidation a host load costs →
  {Pikuri::Skill::Extension#schedule_load_skill} yardoc, one sentence
  each. The catalog note routes a sentence to the same place — merge,
  don't stack.
- "The cache makes a stable prefix free; mutating it is the expensive
  operation" is a cross-cutting fact, not a skills fact — it belongs
  wherever the book teaches prompt assembly, and it is the reason
  {Pikuri::Agent#assemble_system_prompt}'s build-once shape is a virtue
  rather than a missing feature. Worth a line in that method's yardoc so
  the next person to propose an amend-the-prompt seam sees the price.
- The failure mode worth naming wherever this lands: Grok's pain was not
  tokens or latency, it was doing half its recon under the wrong mental
  model and having to redo it — and that wasted recon is *itself* far
  more context than the skill body. It's the argument that makes the
  free, prompt-side fixes the high-value ones.
- The prior-art survey (opencode v2's live system-context block,
  grok-build's `paths:` gating, both harnesses' zero-round-trip human
  path) → `COMPARISON.md` §Skills, which is *also* stale on pikuri's own
  class names (`Tool::SkillCatalog` → `Pikuri::Skill::Catalog`) and
  should be refreshed in the same pass.
- Cheap borrows → their own commits; drop them from this note as they
  land.
- `feedback.txt` item 3 → cut, remaining items renumbered, and the
  settled-so-far preamble extended.
