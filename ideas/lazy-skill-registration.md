# Lazy skill registration — a skill that stays out of the catalog until it's relevant

Status: **idea, not built.** Split out of
[`skill-load-cost.md`](skill-load-cost.md), where it arrived disguised as
`feedback.txt` item 3(a) ("auto-inject `cop` and `tuile` when the path is
`lib/**/*.rb`"). That framing is rejected over there and stays rejected.
This note is the *other* thing the same mechanism can do — and it is a
different feature with a different cost profile, which is why it gets its
own file.

Since then it has grown one further thread, from the author
(2026-08-16): **the same matcher applied to the *tool* list**, which is
below. A second thread — whether the catalog earns its system-prompt slot
at all — split off again into its own sister note, because it is the
*prior* question and decidable without this one.

Related:

- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — the
  sister note. Asks whether an always-resident `<available_skills>` is
  worth its cost; its answer (a names-only baseline promoted to
  descriptions on a match) uses *this* note's matcher as the trigger, and
  changes what "withheld" should mean here — the name stays, only the
  description is withheld.
- [`skill-load-cost.md`](skill-load-cost.md) — the cost arithmetic that
  rules out body pre-injection, the KV-cache analysis that prices prefix
  mutation, and the rest of the feedback item.
- [`claude-parity.md`](claude-parity.md) — its "Skill-invocation
  emphasis — measure" item is the *description-side* answer to the same
  ordering problem, and the cheaper one. If that fixes enough, this note
  may never be worth building.


## The idea

A skill declares in frontmatter which paths it applies to:

```yaml
---
name: tuile
description: Building TUIs with Tuile — the event loop and the rendering rule.
paths: ["**/*_widget.rb", "lib/**/view.rb"]
---
```

It is then **withheld from `<available_skills>`** until a tool touches a
matching file. At that point the harness announces it — name +
description + location, ~50–100 tokens — and the model loads the body
with the `skill` tool as usual, if it wants it.

Two things this is *not*:

- **Not body pre-injection.** The trigger promotes the skill into tier 1
  of progressive disclosure. Tier 2 still costs the tool call, and should
  — that call is ~30 tokens against a body of thousands.
- **Not batched loading.** Nothing here changes the `skill` tool's shape.

What it buys is the axis that actually costs: the catalog is paid **per
skill installed**, on every turn, forever. A 30-skill `~/.claude/skills/`
makes every unrelated session pay for `pdf-tools`, `dataviz` and
`karibu-testing`. Withholding the ones that can't apply is a real saving,
and unlike pre-injection it gets *cheaper* the more skills you have
installed.

The secondary benefit is the one Grok actually wanted: the skill shows up
**at the moment the work starts**, not after half the recon is done under
the wrong mental model.


## Prior art: grok-build ships exactly this

`xai-org/grok-build@main`,
`crates/codegen/xai-grok-tools/src/types/skill_discovery_tracker/`.

- **`conditional.rs`** — `ConditionalSkills` holds `paths:`-gated skills
  out of the listing (`is_pending`, `take_unconditional`), activates them
  on a touch (`activate_for_paths`), and `rehide`s on `/clear` so a new
  conversation starts from the same baseline. Globs are gitignore syntax,
  matched with `matched_path_or_any_parents` so a bare directory pattern
  covers everything beneath it.
- **`reminders/skill_discovery.rs`** — a cross-cutting reminder firing
  after every tool call. It extracts activation paths from *typed* tool
  outputs: `ReadFile`, `ListDir`, `SearchReplace`, and every file of a
  multi-file `ApplyPatch`. Explicitly: *"Bash/grep paths are excluded
  (unparseable / incidental)."*
- **`listing.rs`** — the announcement is a `<system-reminder>` carrying
  `- name: description / Use when: … / Absolute path: …`, budget-capped,
  with the comment that settles the whole question: *"Discovery only —
  the full skill body is loaded on invocation, so the listing stays
  terse."*

The same file also does dynamic *discovery* — reading or writing a
`SKILL.md` anywhere under a known skills root registers that skill
mid-session. Separate feature, same hook; probably out of scope for
pikuri, which scans once at boot.


## The `mcp_connect` analogy — half of it holds

|  | `mcp_connect` (shipped) | lazy skill registration |
|---|---|---|
| advertised as | `<available_mcps>` in the system prompt | `<available_skills>` in the system prompt |
| who activates | **the model**, by calling a tool | **the harness**, by observing a tool call |
| what activation mutates | the chat's tool list, via `ExtensionContext#add_raw_tool` | the *advertised catalog* — a system-prompt block |
| cost deferred | MCP tool schemas | one catalog entry (~50–100 tokens) |

So the shared half is genuine: pikuri already accepts that **the
advertised inventory is a two-tier thing, and the registry mutates
mid-conversation**. `Mcp::Servers#register_tools_with_agent` proves the
mutation path works and that nothing in the loop objects.

The half that doesn't hold is the interesting one. `add_raw_tool` mutates
the *chat*, which is live. The skills catalog lives in the **system
prompt**, which {Pikuri::Agent#assemble_system_prompt} builds once at
construction and rebuilds only on `clear_conversation`. There is no
"amend the system prompt mid-conversation" seam, and adding one would be
a much bigger change than this feature deserves.

Which is fine, because there's a better answer: **announce the activation
as an injection**, exactly as grok-build does with its
`<system-reminder>`. pikuri already has that — `Control::Interloper`'s
`:system` kind, the same channel
{Pikuri::Skill::Extension#schedule_load_skill} uses. The catalog block
stays a boot-time baseline; activations arrive as deltas.

(opencode v2 takes the third road — its `SystemContext` blocks declare
`baseline` / `update` / `removed` renders and it re-sends a delta when the
skill set changes. Structurally the cleanest, and the furthest from
pikuri's assemble-once prompt.)


## What pikuri already has — more than it looks

The user's read was "we don't have machinery for observing file-is-touched
events." That's *nearly* right, but the gap is smaller than it sounds.
Every piece is already in place:

| need | pikuri today |
|---|---|
| see which path a tool is about to touch | `Event::ToolCall = Data.define(:name, :arguments)` — emitted in `before_tool_call` (`agent.rb:453`) with the **model-supplied arguments**, so `read`'s `file_path`, `edit`'s path, `write`'s path are all right there |
| act on the agent from an observer | capture the interloper in `Extension#bind`, enqueue with `inject_system_message` — precisely `schedule_load_skill`'s trick, and thread-safe by design |
| register the observer | `Configurator#add_listener` from the extension's `configure` |
| land the announcement at the right moment | `drain_interloper` runs at `after_tool_result` (`agent.rb:458`), so an enqueue made at `before_tool_call` lands **immediately after that tool's own result** — in-turn, no extra round-trip |

So the whole loop is buildable today inside `pikuri-skills`, with **zero
core changes**. Sketch:

```ruby
# in Skill::Extension#configure
c.add_listener(PathActivationListener.new(catalog: @catalog, ext: self))

# in the listener
def on_event(event)
  return unless event.is_a?(Pikuri::Agent::Event::ToolCall)

  paths = PATH_ARGS[event.name]&.filter_map { |k| event.arguments[k] } or return
  newly = @catalog.activate_for_paths(paths)
  @ext.announce(newly) unless newly.empty?   # → interloper.inject_system_message
end
```

**The one honest gap** is walked vs. supplied paths — the distinction the
Denylist seam already names. `Event::ToolCall#arguments` gives the path
the *model supplied*; it can't give the paths a `grep` or `file_list`
*walked to*, because `Event::ToolResult` carries only a String and
pikuri's tools return prose, not typed records. Notably grok-build lands
in the same place from the opposite direction — it has typed outputs and
still excludes bash/grep as "unparseable / incidental." So supplied-only
is not a pikuri limitation to apologize for; it's where the shipped
implementation also drew the line.


## Thread: the same matcher, applied to *tools*

The author's framing: a user accumulates *tools* the way they accumulate
skills — thunderbird, vectordb, memory, a pile of MCP servers — and only
a slice of them is applicable to any one project. Gate the **tool list**
on `paths:` the same way and only advertise what this project needs.

### The prize is genuinely bigger

Measured on this repo, 2026-08-16. Proxy for the tool side: every
heredoc body plus every single-line `description:` string in the 30 files
under `pikuri-*/lib/` that define a `Pikuri::Tool` — which is what a
JSON schema is mostly made of, modulo ~20–30 % scaffolding.

| | bytes | ≈ tokens |
|---|---|---|
| all 30 pikuri tools' schema prose | 22 KB | ~5.5 k |
| the 12-skill `~/.claude/skills` catalog render | 5.9 KB | ~1.5 k |

Per item: ~730 B/tool vs ~380 B/skill-description. So **the whole tool
surface is roughly 4× the whole skill catalog** — and it is paid on the
same terms the catalog is: resident, every turn, scaling with what's
*installed* rather than what's *used*. (Deliberately no window-percentage
here; `skill-load-cost.md` retracted that framing, and the asymmetry is
the argument at any window size.)

### …but pikuri already answers it twice, and both beat a matcher

1. **Per-binary wiring.** No shipped binary wires all 30 tools.
   `bin/pikuri-thunderbird` doesn't pay for `vectordb_*`. "Which tools
   does this project need?" is answered at *construction*, by a human, in
   Ruby — which is precisely pikuri's counter-move to the wall of JSON.
2. **Sub-agent personas.** A persona owns its toolset verbatim and costs
   the parent exactly one `agent` schema. That's *better* than gating,
   because the sub-agent's whole context is separate — the parent never
   pays the observations either. `LIBRARIAN` is this pattern applied to
   the "vectordb tools don't belong in a coding agent's list" case, and
   it already ships.

Which bounds the scope honestly: **this is a feature for a future
general-purpose host** (a `pikuri-tui` that wires everything because it
can't know what you'll ask), not for anything in `bin/` today. CLAUDE.md's
warning applies — don't propose a library feature whose value rests on a
demo's shortcut; here it's the opposite, the demos are *fine* and the
hypothetical host is the one with the problem.

### Three things make tools harder to gate than skills

- **Withholding a tool withholds a capability, not a document.** A skill
  the model never sees → it does the work with worse instructions. A tool
  it never sees → it *can't do the work at all* and has no way to ask.
  That asymmetry is why `mcp_connect` advertises `<available_mcps>`
  rather than hiding servers outright.
- **The bootstrap hole.** A path matcher fires only *after* some tool
  touched a matching path, so the trigger tools (`read`, `glob`,
  `file_list`) must always be wired. Fine for families downstream of file
  work; useless for intent-driven ones — nothing the model *reads* tells
  you it is about to want `thunderbird_mail_search`. Half a real toolbox
  is unreachable by this predicate.
- **Cache invalidation, and it's the whole prefix.** Tool schemas sit at
  the very front of the request; adding one mid-conversation invalidates
  the *entire* cached prefix — the general point `skill-load-cost.md`'s
  caching section makes, that the expensive operation is not length but
  **mutating the prefix**. Paid **per activation**, where `mcp_connect`
  pays it once per session by design. Note this is the same wall the
  skills case hits with the system prompt, and there the escape is
  "announce via an interloper injection, which *appends*". Tools have no
  such escape: a tool must actually be in the list to be callable.

Removal is worse than addition — history containing a call to a tool no
longer declared is a shape some providers reject. **Gating is add-only.**

### Rivals, in the order to exhaust them

1. **Per-binary wiring + sub-agent personas** — shipped, free,
   human-authored, and it's what pikuri is *for*.
2. **Model-driven activation** — `mcp_connect`'s shape, generalized:
   advertise a *family* in one line, let the model materialize the
   schemas with a connect call. Paid once, model-controlled, no bootstrap
   hole, and `ExtensionContext#add_raw_tool` already exists. This is what
   Claude Code does at scale today: the session this note was written in
   has ~100 MCP tools deferred to names-only, with a `ToolSearch` tool
   that fetches schemas on demand.
3. **Path-gated tools** — last, only for a general-purpose host, and only
   for path-shaped families.

Note the inversion between the two applications: for **skills** the
predicate is the easy part and the assemble-once system prompt is the
wall; for **tools** the mutation seam already exists and the *predicate*
is what doesn't fit.


## What the sister note does to this one

[`skill-catalog-in-context.md`](skill-catalog-in-context.md) asks the
prior question — is an always-resident catalog worth its slot? — and its
answer feeds straight back here, so read the two together before
building either. In short: **withhold the description, never the name.**

The framing at the top of this note ("withheld from `<available_skills>`
until a tool touches a matching file") hides the name too, which leaves
the model unable to call `skill(name:)` for a skill it has never seen —
a discoverability hole with no upside, since the names are ~40× cheaper
than the descriptions they sit next to (measured over there). Redefine
"withheld" as *name-only until the path fires*, and:

- the hole closes, and a sub-agent that inherits the `skill` tool but not
  the extension can still reach a gated skill by name (open question 4
  below becomes much less sharp);
- the opt-in needs no policy knob — a skill declaring `paths:` is
  asserting its trigger is lexical-on-file, so withholding its
  description until the glob fires is what the author already meant;
- open question 1 ("does it earn its complexity at pikuri's catalog
  sizes?") turns from measure-and-hope into arithmetic: the saving is the
  description bytes of every path-gated skill, on every turn, forever.

The cost that arrives with it is on the other side of the ledger and is
priced in the sister note: a promotion is an interloper `:system` item,
which Anthropic hoists into the system param — **rewriting the prefix and
nuking the prompt cache, once per activation**. That makes "how many
activations does a real session fire?" a load-bearing measurement for
this note too, not just for that one.


## Open questions

1. **Does it earn its complexity at pikuri's catalog sizes?** The saving
   scales with skills installed. Three skills: worthless. Thirty
   (a realistic `~/.claude/skills/`): a catalog block worth low-thousands
   of tokens on every turn, most of it irrelevant. Where's the crossover,
   and is anyone actually past it? Measure a real catalog before building.
2. **Is `paths:` even the right predicate?** It's the one grok-build
   picked, and it's honest about what a coding agent does. But `cop`
   applies when you're *shaping* a component, not when you touch any Ruby
   file — a glob can't express that, and a mis-triggering catalog entry is
   noise the model has to ignore on every subsequent turn. Cheaper rival:
   just write better `description`s (see `claude-parity.md`). Does the
   glob beat the sentence?
3. **A non-standard frontmatter key is a compatibility cost.** `paths:`
   isn't in the Agent Skills spec. A skill authored for pikuri would
   behave differently in Claude Code (which ignores unknown keys and lists
   it always) — arguably the safe direction, but it means the same bundle
   isn't the same skill. Adopt grok-build's spelling verbatim so at least
   two harnesses agree?
4. **Sub-agents.** They don't inherit extensions, but they *do* inherit
   the `skill` tool via the tool snapshot, closing over the same catalog.
   So a sub-agent could load a withheld skill by name while never seeing
   it advertised. Is that a bug, a feature, or a reason to activate
   catalog-wide rather than per-agent? (Compare `add_raw_tool`, which
   deliberately keeps MCP activation per-agent by staying out of
   `Agent#tools`. And note the sister note's name-only baseline mostly
   dissolves this: the sub-agent *does* see the name, just not the
   description.)
5. **Does an activation survive `clear_conversation`?** grok-build
   `rehide`s on `/clear`. pikuri rebuilds the system prompt there, so the
   baseline returns automatically — but any injected announcements are
   discarded too, which is probably the right semantics for free.
6. **Should the announcement be `:system` or something new?** It reuses
   `Event::SystemInjected`, which listeners render. A "3 skills became
   available" line is arguably chrome, not conversation. Worth a
   dedicated event so a TUI can render it as a status line rather than a
   message? (The sister note raises the stakes: if the hand-off is also
   *for the human* — "here's the Tuile manual, now that you're in a Tuile
   file" — this stops being a rendering nicety and becomes the feature's
   selling point.)
7. **Does the tool thread survive contact with per-binary wiring?** My
   read is no, not until a general-purpose host exists — but the shared
   machinery (the `paths:` matcher, the path-args map in *Prerequisite*
   below) is the same either way, so building it for skills costs nothing
   extra and keeps the option. Don't build the tool half speculatively.
8. **Is `mcp_connect`-shaped activation the better generalization for
   *both*?** Model-driven, one round-trip, no bootstrap hole, works for
   intent-driven families a glob can't reach. Against it: it's another
   tool schema, and it puts the decision back on the model — which is
   exactly the judgment the sister note argues is unreliable. Possibly
   the answer splits by axis: harness-driven `paths:` for skills (cheap,
   additive, appends), model-driven connect for tools (expensive,
   prefix-busting, deserves an explicit decision).


## Prerequisite worth doing regardless

The listener sketch needs a `name → path-bearing argument keys` map
(`read`→`file_path`, `edit`→`file_path`, …). That map is exactly the kind
of cross-gem coupling pikuri avoids: `pikuri-skills` would be hardcoding
`pikuri-workspace`'s parameter names, and it silently rots when a tool
renames an argument.

If this gets built, the map is the first design problem, not an
implementation detail. Options: a `Pikuri::Tool` mixin declaring "these
args are paths"; a convention (`*_path` / `path` / `file_path`) checked
against the workspace tools' actual schemas by a spec; or accept the
coupling and put a grep tripwire on it. Worth thinking about even if this
note dies, because the same map would serve any future path-aware
listener.


## Graduation plan (when this settles)

- **Rejected** → one `DECISIONS.md` entry covering the fork
  (advertise-always vs. path-gated advertising), and a one-line why-not
  where a future reader would look — probably {Pikuri::Skill::Catalog}'s
  yardoc, since the temptation recurs whenever someone's catalog gets big.
- **Built** → `paths:` semantics to {Pikuri::Skill::Catalog} yardoc, the
  activation mechanism to `pikuri-skills`' own docs, the
  observe-via-`ToolCall`-args pattern to CLAUDE.md only if it becomes a
  seam (it would be the first listener that *acts*, which is a real
  invariant worth recording against the capability seam).
- The `mcp_connect` parallel → `COMPARISON.md` or the book's skills
  material, wherever the two-tier-inventory pattern is best taught once.
- **The tool-gating thread** → whichever way it goes, the durable nugget
  is *"per-binary wiring and sub-agent personas are pikuri's answer to
  tool-list bloat"*, plus the add-only / prefix-invalidation constraint.
  That's a `DECISIONS.md` entry on its own axis (**not** the catalog one)
  — the fork is real and someone will re-propose it the first time a
  general-purpose host exists. Point {Pikuri::SubAgent::Persona}'s yardoc
  at it.
- The name-only-baseline material graduates with
  [`skill-catalog-in-context.md`](skill-catalog-in-context.md), not here.
  Both notes land in the *same* `DECISIONS.md` entry (the
  what-the-catalog-advertises axis, per `skill-load-cost.md` open
  question 3) — so whichever settles last edits that entry rather than
  opening a second.
