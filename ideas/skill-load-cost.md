# Does loading a skill cost too much?

Status: **idea, brainstorming — nothing built, nothing decided.** Origin:
`feedback.txt` item 3 ("skill load costs a turn"), which asked for one of
three things: path-triggered auto-injection, a batch `skill` call, or at
least for skill-loading to feel like the *expected opening move* rather
than a surprise tax.

The framing is the first thing to fix, and then two of the three asks
mostly dissolve. What survives is a genuinely open question about
*ordering* (not cost) plus a handful of cheap borrows that fell out of
reading the prior art.

Related:

- [`claude-parity.md`](claude-parity.md) — its one live open item,
  "Skill-invocation emphasis — measure", is the same question as item
  3(c) below. Whichever note survives, these two should merge.
- [`context-budget.md`](context-budget.md) — same shape of mistake:
  feedback asking for a per-turn signal, where the honest answer is much
  smaller than the ask.
- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — the
  general form of the same axis: given all of the above, does an
  always-resident `<available_skills>` earn its slot at all? Consumes
  this note's measurements and the caching section.


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


## Measured: what tier 1 actually costs

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

Two things follow. First, the item-3 framing is confirmed from the other
side: the expensive thing is what's resident, not what a call costs.
Second — and this is new — **the over-budget descriptions are the
cheapest thing on this whole list to fix**, and nothing about them
requires a mechanism.

The reason they're fat is visible in the same table: `claude-api` and
`dataviz` carry TRIGGER/SKIP blocks inside their `description`. The
description has started doing the skill's job. That's the failure
`when-to-use:` exists to fix structurally, and it's also a tension with
no free answer — see open question 1.


## Does the KV cache neutralize the length? (author's question, 2026-08-16)

Partly — and working out *which* part turns out to matter more than the
token counts above.

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
no cache refunds.

**The inversion.** Once caching is in the picture, the expensive operation
is not *length*, it's **mutating the prefix**. A stable prefix is free
after turn one; a prefix that changes invalidates everything after the
change point and re-prefills. Which means pikuri's current shape is
accidentally the cache-optimal one:

- the catalog lives in the **assemble-once system prompt** — the most
  stable, best-cached position available;
- the body arrives as a **tool result appended at the end** — append-only,
  so it invalidates nothing and is itself cached from the next turn.

That reframes two things written elsewhere in these notes:

1. `assemble_system_prompt` building once and never amending was
   described in `lazy-skill-registration.md` as a *limitation*. It's also
   a cache virtue, and any "amend the system prompt mid-conversation"
   seam — opencode's `SystemContext` delta re-render, or a catalog that
   grows entries as skills activate — buys its flexibility by throwing
   away the cache on every change. That's a real cost against lazy
   registration that neither note had priced.
2. It sharpens why the tool path beats the host path (see open question
   2): a tool result is append-only on *every* provider, whereas the
   `:system` interloper kind is hoisted into the top-level system param on
   Anthropic — i.e. it **rewrites the prefix**, invalidating the entire
   prompt cache for the rest of the conversation. Every host-loaded skill,
   one full cache nuke. The stickiness I flagged earlier is the smaller
   half of that problem.

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

{Pikuri::Skill::SkillTool}'s header says the inventory lives in the
system prompt "as PI and Claude Code do (opencode is the outlier)".
**That is now out of date.** opencode v2 renders `<available_skills>`
into a system-context block (`core/src/skill/guidance.ts`,
`SystemContext.Key "core/skill-guidance"`); only its docs page still
claims the tool description. The yardoc sentence needs a correction pass
regardless of what happens to this note.

opencode's version is *live*, though, in a way pikuri's isn't: the block
declares `baseline` / `update` / `removed` renders, so when the skill set
changes mid-session the model gets a delta ("The available skills have
changed. This list supersedes the previous available skills list."), and
when the `skill` tool is denied the block vanishes entirely. pikuri
assembles the system prompt once at construction (and on
`clear_conversation`). Probably fine — pikuri scans at boot and doesn't
watch the filesystem — but it's the mechanism a hot-reload would need.

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
tier 2. The trigger fixes **ordering**, it does not skip the round-trip —
independent confirmation of the split argued above.

That also means the mechanism is a different feature from the one the
feedback asked for, with a different cost profile, so it moved to its own
note: **[`lazy-skill-registration.md`](lazy-skill-registration.md)**, which
carries the grok-build implementation detail, the `mcp_connect` parallel,
and the (surprisingly short) list of what pikuri would need to build it.
Item 3(a) *as asked* stays rejected here.

Two more grok-build details in the same area:

- `disable-model-invocation: true` — a skill only the human's slash
  command can fire. `user-invocable: false` — the mirror image.
- `when-to-use:` as a frontmatter field *separate* from `description`,
  with the listing formatter stripping "Use when …" trigger prefixes out
  of the description when both are present. That is a targeted fix for
  exactly the failure Grok reported: descriptions that say what a skill
  *is* but not *when* to reach for it.

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
The `:user` vs `:system` choice is the interesting divergence: `:system`
is what makes it sticky on Anthropic (above).

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
  reframed version — path glob as a relevance filter that promotes a
  withheld skill into the *catalog* — is a different feature and now
  lives in [`lazy-skill-registration.md`](lazy-skill-registration.md).
- **(b) batch load — already available**, via parallel tool calls. No
  new parameter.
- **(c) "expected opening move" — the only live residue**, and it's a
  prompt/description problem, not a mechanism one. Merge with
  `claude-parity.md`'s open measure item.


## Open questions (the brainstorm continues here)

1. **Say-*when* vs. stay-short — the description tension.** This is the
   live one. The failure Grok reported is a description that says what a
   skill *is* but not when to reach for it; the fix is to add the
   trigger. But the measurement above says descriptions are *already*
   3–6× the spec's budget, and every added word is paid every turn by
   every session. Two levers pull opposite ways, and the note has no
   answer yet:
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
     structurally right answer and the only one that survives
     lazy-registration later, but a non-standard key; (iv) truncate in
     the catalog render like grok-build's proportional split — clever,
     and clever is how you cut a trigger sentence in half.

   My read: (i) + the preamble now, (ii) if a real catalog keeps
   growing, (iii) only if `when-to-use:` earns its way in for another
   reason. Explicitly *not* (iv).

   **Revised after the caching section above.** The trade is less tight
   than it looked, and it tilts toward *saying when*. A longer description
   costs prefill only on turn one; what it costs forever is window
   capacity and attention. But a description that fails to fire the right
   skill costs a whole wasted recon pass — which is far more of *both*.
   So on the merits: pay the words, spend them on the trigger. That
   demotes (ii) from "cheap and honest" to "solving the cheap half" and
   makes (i) — teaching authors to lead with the trigger and cut the
   *narrative*, not the trigger — the whole answer for now. The remaining
   worry isn't length, it's **twenty-eight descriptions of which one is
   relevant**: attention dilution scales with catalog *size*, and no
   amount of per-entry editing fixes it. Which is the one honest argument
   left standing for `lazy-skill-registration.md` — and, more directly,
   for [`skill-catalog-in-context.md`](skill-catalog-in-context.md),
   whose name-only baseline is the only proposal on the table that
   removes descriptions rather than shortening them.
2. ~~**Should the human path fold into the user turn instead of
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
3. ~~**One DECISIONS.md entry or two?**~~ **Settled: one**, written when
   this note graduates rather than waiting on
   `lazy-skill-registration.md`. Same axis — *what the catalog
   advertises, and when the body arrives* — and entries are mutable, so
   lazy registration extends it in place if it ever lands. Same ruling
   for [`skill-catalog-in-context.md`](skill-catalog-in-context.md),
   which is that axis at its most general: three notes, one entry,
   whichever settles last does the editing.


## Cheap borrows spotted along the way

Independent of how the main question settles; each is small enough to
land on its own.

1. **Enum-constrain `SkillTool`'s `name`.** {Pikuri::Tool::Parameters}
   already has `required_enum`, and the catalog is fixed at construction,
   so this is a one-line change that makes a hallucinated skill name
   impossible instead of merely well-handled. The spec explicitly
   recommends it. Note the interaction: the tool is snapshot into
   sub-agents, so the enum must be built from the same `catalog.list` the
   closure captures. Second interaction, spotted later: an enum of every
   skill name **is** a names-only catalog living in the tool schema, so
   this borrow also hands
   [`skill-catalog-in-context.md`](skill-catalog-in-context.md)'s tier 0
   for free. Land it first if that note goes anywhere.
2. **List the skill's sidecar files in the load result.** Both harnesses
   do it: opencode globs the skill dir, caps at 10, sorts, excludes
   `SKILL.md`, and emits `<skill_files>` with a "file list is sampled"
   note; grok-build rewrites relative links in the body to absolute paths.
   pikuri currently says only "sidecar paths … are relative to
   `<base_dir>`", which costs the model a `glob` round-trip to find out
   there *are* none — a real round-trip, unlike the one item 3 complained
   about. This is the borrow most directly responsive to the actual
   feedback.
3. **Correct the "opencode is the outlier" sentence** in
   {Pikuri::Skill::SkillTool}'s header (see above). Needed regardless.
4. **Drop `<location>` from the catalog render.** The spec says outright:
   *"If your dedicated activation tool provides the skill directory path
   in its result, you can omit `location` from the catalog."* pikuri
   emits it in both — `format_catalog`'s `<location>` **and**
   `format_skill`'s `location=` attribute plus the base-dir sentence. The
   catalog copy is the redundant one, and it's not cheap: absolute paths
   like `/home/mavi/.claude/skills/writing-javadoc/SKILL.md` run ~15
   tokens, so a 28-skill catalog pays ~400 tokens for a duplicate. On the
   exact axis this note is about, and spec-blessed.
   Counter-argument to weigh first: `location` is also what enables
   *file-read activation* (the model `read`s SKILL.md directly, no tool),
   which is the documented fallback if the `skill` tool is ever absent —
   and pikuri wires skill roots into `Filesystem#readable:` precisely so
   that works. Dropping it makes the tool the only door. Probably fine —
   the tool is auto-registered whenever the catalog is non-empty — but
   it's a real coupling, not a pure win.
5. **Dedupe a repeated load.** {Pikuri::Skill::SkillTool} re-renders the
   full body every time it's called, so a model that loads `cop` three
   times pays ~2 800 tokens three times. The spec's Step 5 recommends
   tracking activations and skipping re-injection. This is worse on
   Anthropic, where a *host*-loaded skill is hoisted and sticky — repeat
   loads accumulate in the system param. Cheap fix (a `Set` of loaded
   names in the tool's closure, returning "already loaded in this
   conversation" on a repeat); the only design question is what
   `clear_conversation` does to it, and the answer is obvious.
6. **`when-to-use:` / `disable-model-invocation:` frontmatter** — noted,
   not proposed. Both are non-standard extensions; worth knowing they
   exist before inventing our own spelling if we ever want them.
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
- The rejected forks (glob→skill config table; `names:` array; body
  pre-injection) → `DECISIONS.md`, **one** entry on the
  what-the-catalog-advertises-and-when-the-body-arrives axis; lazy
  registration extends it in place later rather than opening a second.
- Why the host path is `:system` and not `:user` (the `on_user_message`
  dispatch would fire on reference text), the trust consequence of
  promoting hard-untrusted skill text into the system slot, and the
  Anthropic prompt-cache invalidation a host load costs →
  {Pikuri::Skill::Extension#schedule_load_skill} yardoc, one sentence
  each.
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
