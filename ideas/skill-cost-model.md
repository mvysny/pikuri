# What skills actually cost in context — the shared evidence base

Status: **evidence base only; every fork this note fed is closed**
(2026-08-17 — `paths:` gating shipped and is the whole of what the skills
surface earned; see `DECISIONS.md` `D-skill-path-activation`, *this is
where the skills-surface work stops*). What keeps the file alive is not a
question but a **debt**: the tier costs and the KV-cache section are cited
from a sister note and neither has a durable home yet. When they get one,
delete this file. (The prior-art survey graduated to `COMPARISON.md`
§Skills on 2026-08-17.)

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

- `DECISIONS.md` `D-skill-path-activation` — where every fork here landed;
  it consumed the grok-build survey and the 40:1 ratio below. (An earlier
  sibling note, `skill-catalog-in-context.md`, covered *what* the catalog
  advertises; fully graduated and deleted 2026-08-17.)
- [`tool-list-in-context.md`](tool-list-in-context.md) — the same
  resident-prefix arithmetic applied to tool schemas, which turn out to be
  ~4× the skill catalog. **The only inbound citation this file has**, and
  what the KV-cache section below is being kept for.
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

That 40:1 ratio is the load-bearing number behind
`D-skill-path-activation`, which decided what to do about it (gate per
skill on `paths:`, and reject a names-only tier).

Two things follow from the tier-1 numbers. First, the item-3 framing is
confirmed from the other side: the expensive thing is what's resident, not
what a call costs. Second, **the over-budget descriptions are the cheapest
thing on this whole list to fix**, and nothing about them requires a
mechanism — the reason they're fat is visible in the same table, since
`claude-api` and `dataviz` carry TRIGGER/SKIP blocks inside their
`description`. The description has started doing the skill's job. (That
tension — say *when* vs. stay short — is what `when-to-use:` addresses;
shipped, see `Catalog::Skill#when_to_use` and {Pikuri::Skill::Trigger},
which keeps the two fields from restating each other from both ends.)


## Does the KV cache neutralize the length? (author's question, 2026-08-16)

Partly — and working out *which* part turns out to matter more than the
token counts above. **This section is the reason none of these notes can
be argued in raw token counts; read it before quoting any number.** It is
also the half of the cache story that is *not* yet written down anywhere
durable: the repo documents prefix-*mutation* cost well
(`D-reference-text-as-user-turn`, `D-skill-path-activation`'s
Consequences, `COMPARISON.md` on grok-build's injection channel,
`pikuri-memory/DESIGN.md`'s append-only log discipline), but nowhere says
that a *successfully cached* prefix still costs two things no cache
refunds.

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
That is the argument `D-skill-path-activation` actually rests on, and its
Context currently states it as raw resident KB.

**The inversion.** Once caching is in the picture, the expensive operation
is not *length*, it's **mutating the prefix**. A stable prefix is free
after turn one; a prefix that changes invalidates everything after the
change point and re-prefills. Which means pikuri's current shape is
accidentally the cache-optimal one:

- the catalog lives in the **assemble-once system prompt** — the most
  stable, best-cached position available;
- the body arrives as a **tool result appended at the end** — append-only,
  so it invalidates nothing and is itself cached from the next turn.

The consequence that has *not* graduated:
{Pikuri::Agent#assemble_system_prompt} building once and never amending is
not only a limitation — it's a cache virtue. Any "amend the system prompt
mid-conversation" seam (opencode's `SystemContext` delta re-render, or a
catalog that grows entries as skills activate) buys its flexibility by
throwing away the cache on every change. `D-skill-path-activation` records
the *fact* that the method runs exactly twice; nothing records the *price*
at the method itself, which is where the next person to propose an
amend-the-prompt seam will be standing.

(The other two consequences are settled and recorded elsewhere. Injections
are `role: :user` in a `<system-reminder>` on every provider since
`D-reference-text-as-user-turn`, so the host path no longer rewrites any
prefix and the old "tool path beats host path" asymmetry is gone; the
residual Anthropic invalidation on a *promotion* is logged and accepted in
`D-skill-path-activation`'s Consequences.)


## Graduation plan — what is actually left

Everything else this note carried has landed. What remains:

- **The cache table's second half** — "a cached prefix is free in prefill
  but never in window capacity or attention, so only *removing* entries
  helps" → `D-skill-path-activation`'s **Context**, which argues the same
  conclusion from raw resident KB and would be stronger with the reason.
  DECISIONS is also the right home on the single-source rule: it's the
  rejection rationale for every per-entry-editing alternative.
- **The cache virtue** → one line in
  {Pikuri::Agent#assemble_system_prompt}'s yardoc: building once is a
  price, not a missing feature. This is the note's only lib-side debt.
- **`feedback.txt` item 3** → cut, remaining items renumbered, and the
  settled-so-far preamble extended with the `paths:` gate.
- **The failure mode worth naming wherever this lands:** Grok's pain was
  not tokens or latency, it was doing half its recon under the wrong
  mental model and having to redo it — and that wasted recon is *itself*
  far more context than the skill body. It's the argument that makes the
  free, prompt-side fixes the high-value ones.

Then this file goes, and `tool-list-in-context.md`'s two citations of it
repoint at whichever home the cache table got.
