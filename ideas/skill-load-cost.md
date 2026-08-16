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

1. **Is the ordering problem better solved in the description?**
   grok-build's `when-to-use:` split says the real failure is
   descriptions that don't say *when*. pikuri could get most of the
   benefit by (i) sharpening the catalog preamble from "before answering
   from your own knowledge" to something that covers *recon* too, and
   (ii) saying so in whatever guidance we give skill authors. Both are
   free — and if they work, `lazy-skill-registration.md` never needs
   building.
2. **What is the actual failure mode we're fixing?** Grok's pain wasn't
   tokens or latency — it was doing half its recon under the wrong mental
   model and having to redo it. That wasted recon is *itself* far more
   context than the skill body. Worth stating explicitly wherever this
   lands, because it's the argument that makes the trigger-wording fix
   the high-value one.
3. **Should the human path fold into the user turn instead of `:system`?**
   Both prior-art harnesses put a human-loaded skill in the user message;
   pikuri puts it in `:system`, which is sticky on Anthropic and
   positional elsewhere. Is the divergence (documented honestly in
   `schedule_load_skill`'s yardoc) the right call, or is it a bug we
   haven't hit because no bundled binary exercises it?
4. **Does this earn a DECISIONS.md entry on its own?** The fork here is
   real (pre-inject bodies vs. load on demand) and no `D-` entry covers
   skills yet — but `lazy-skill-registration.md` will want an entry too,
   on an adjacent fork. One entry covering "what the catalog advertises
   and when the body arrives", or two?


## Cheap borrows spotted along the way

Independent of how the main question settles; each is small enough to
land on its own.

1. **Enum-constrain `SkillTool`'s `name`.** {Pikuri::Tool::Parameters}
   already has `required_enum`, and the catalog is fixed at construction,
   so this is a one-line change that makes a hallucinated skill name
   impossible instead of merely well-handled. The spec explicitly
   recommends it. Note the interaction: the tool is snapshot into
   sub-agents, so the enum must be built from the same `catalog.list` the
   closure captures.
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
4. **`when-to-use:` / `disable-model-invocation:` frontmatter** — noted,
   not proposed. Both are non-standard extensions; worth knowing they
   exist before inventing our own spelling if we ever want them.


## Graduation plan (when this settles)

- The 100:1 arithmetic + "the trigger is a relevance filter, not a
  preloader" → {Pikuri::Skill::SkillTool} yardoc, tightening the sentence
  that's already there.
- The rejected forks (glob→skill config table; `names:` array; body
  pre-injection) → `DECISIONS.md`, one entry.
- The prior-art survey (opencode v2's live system-context block,
  grok-build's `paths:` gating, both harnesses' zero-round-trip human
  path) → `COMPARISON.md` §Skills, which is *also* stale on pikuri's own
  class names (`Tool::SkillCatalog` → `Pikuri::Skill::Catalog`) and
  should be refreshed in the same pass.
- Cheap borrows → their own commits; drop them from this note as they
  land.
- `feedback.txt` item 3 → cut, remaining items renumbered, and the
  settled-so-far preamble extended.
