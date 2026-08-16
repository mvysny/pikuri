# Path-triggered skill activation — promoting a skill at the moment it becomes relevant

Status: **idea, not built.** Split out of what is now
[`skill-cost-model.md`](skill-cost-model.md), where it arrived disguised
as `feedback.txt` item 3(a) ("auto-inject `cop` and `tuile` when the path
is `lib/**/*.rb`"). That framing is rejected over there and stays
rejected. This note is the *other* thing the same mechanism can do — the
trigger as a **relevance filter**, not a preloader — which is a different
feature with a different cost profile.

(Filed as `lazy-skill-registration.md` until 2026-08-16. Renamed because
nothing is registered lazily: the catalog is scanned at boot as always,
and what the trigger moves is *how much of an entry is advertised*.)

**Scope.** This note owns the trigger: the `paths:` predicate, what fires
it, how pikuri would wire it, and what a promotion costs. It does **not**
own what a promoted entry contains or whether the baseline should shrink
(→ `skill-catalog-in-context.md`), nor the measurements it argues from
(→ `skill-cost-model.md`). The same matcher applied to the *tool* list is
a different noun with a different decision and moved to its own note.

Related:

- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — the
  sister note, and the *prior* question: is an always-resident
  `<available_skills>` worth its cost? Its answer (a names-only baseline
  promoted to descriptions on a match) uses *this* note's matcher as the
  trigger, and defines what "withheld" means here.
- [`skill-cost-model.md`](skill-cost-model.md) — the cost arithmetic that
  rules out body pre-injection, and the KV-cache analysis that prices
  prefix mutation (i.e. what each activation costs).
- [`tool-list-in-context.md`](tool-list-in-context.md) — the same matcher
  aimed at tool schemas. Shares the machinery, decides separately.
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

Its **description is withheld from `<available_skills>`** until a tool
touches a matching file. At that point the harness announces it — name +
description + location, ~50–100 tokens — and the model loads the body
with the `skill` tool as usual, if it wants it.

Three things this is *not*:

- **Not body pre-injection.** The trigger promotes the skill into tier 1
  of progressive disclosure. Tier 2 still costs the tool call, and should
  — that call is ~30 tokens against a body of thousands.
- **Not batched loading.** Nothing here changes the `skill` tool's shape.
- **Not hiding the name.** An earlier draft of this note withheld the
  whole entry, which leaves the model unable to call `skill(name:)` for a
  skill it has never seen — a discoverability hole with no upside, since
  names are ~40× cheaper than the descriptions they sit next to. The
  sister note owns that argument and the baseline that falls out of it;
  read it before implementing "withheld".

What it buys is the axis that actually costs: the catalog is paid **per
skill installed**, on every turn, forever. A 30-skill `~/.claude/skills/`
makes every unrelated session pay for `pdf-tools`, `dataviz` and
`karibu-testing`. Withholding the ones that can't apply is a real saving,
and unlike pre-injection it gets *cheaper* the more skills you have
installed.

The secondary benefit is the one Grok actually wanted: the skill shows up
**at the moment the work starts**, not after half the recon is done under
the wrong mental model.

One nice consequence of the name-only baseline: it also makes the
**opt-in free of any policy knob.** A skill declaring `paths:` is
asserting its trigger is lexical-on-file, so withholding its description
until the glob fires is what the author already meant.


## Prior art: how grok-build builds it

`xai-org/grok-build@main`,
`crates/codegen/xai-grok-tools/src/types/skill_discovery_tracker/`.
(`skill-cost-model.md` covers *what it proves* — that the only shipped
implementation still makes the model spend the tool call. This is *how*.)

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

|  | `mcp_connect` (shipped) | path-triggered activation |
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
a much bigger change than this feature deserves — and, per
`skill-cost-model.md`'s caching section, would throw away the prompt
cache every time it fired.

Which is fine, because there's a better answer: **announce the activation
as an injection**, exactly as grok-build does with its
`<system-reminder>`. pikuri already has that — `Control::Interloper`'s
`:system` kind, the same channel
{Pikuri::Skill::Extension#schedule_load_skill} uses. The catalog block
stays a boot-time baseline; activations arrive as deltas, appended.

(opencode v2 takes the third road — its `SystemContext` blocks declare
`baseline` / `update` / `removed` renders and it re-sends a delta when the
skill set changes. Structurally the cleanest, and the furthest from
pikuri's assemble-once prompt.)

**The cost of an injection, stated plainly:** `:system` items are hoisted
into the top-level system param on Anthropic, so each activation rewrites
the prefix and invalidates the prompt cache for the rest of the
conversation. That is paid *per activation*, which is why open question 4
below is a prerequisite to building rather than a nice-to-have.


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
  newly = @tracker.activate_for_paths(paths)  # NOT @catalog — see below
  @ext.announce(newly) unless newly.empty?   # → interloper.inject_system_message
end
```

**Correction (2026-08-16, from `skill-catalog-in-context.md` R5): the
activation state cannot live on the catalog.** `Catalog::Bundled#initialize`
ends with `@skills.freeze`, `@list.freeze` and `freeze`, so an
`@catalog.activate_for_paths` would raise `FrozenError`. An earlier draft
of the sketch above did exactly that. The state belongs in the listener
(or a small tracker it owns), which is the better shape anyway — it keeps
the catalog pure discovery/validation/holding, and it is what makes the
sister note's tier-0 baseline stateless, so `clear_conversation` needs no
`rehide` where grok-build does. Read the deep freeze as a constraint worth
keeping, not an obstacle: any design that mutates the catalog per session
gives it up.

**The one honest gap** is walked vs. supplied paths — the distinction the
Denylist seam already names. `Event::ToolCall#arguments` gives the path
the *model supplied*; it can't give the paths a `grep` or `file_list`
*walked to*, because `Event::ToolResult` carries only a String and
pikuri's tools return prose, not typed records. Notably grok-build lands
in the same place from the opposite direction — it has typed outputs and
still excludes bash/grep as "unparseable / incidental." So supplied-only
is not a pikuri limitation to apologize for; it's where the shipped
implementation also drew the line.


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
listener — including the tool-gating variant in
[`tool-list-in-context.md`](tool-list-in-context.md), which is why
building it for skills keeps that option open at no extra cost.


## Open questions

1. **Does it earn its complexity at pikuri's catalog sizes?** The saving
   scales with skills installed. Three skills: worthless. Thirty
   (a realistic `~/.claude/skills/`): a catalog block worth low-thousands
   of tokens on every turn, most of it irrelevant. Where's the crossover,
   and is anyone actually past it? The sister note's name-only baseline
   turns this from measure-and-hope into arithmetic — the saving is the
   description bytes of every path-gated skill, on every turn, forever —
   but the *count* of gated skills in a real catalog is still a
   measurement nobody has taken.
2. **Is `paths:` even the right predicate?** It's the one grok-build
   picked, and it's honest about what a coding agent does. But `cop`
   applies when you're *shaping* a component, not when you touch any Ruby
   file — a glob can't express that, and a mis-triggering catalog entry is
   noise the model has to ignore on every subsequent turn. Cheaper rival:
   just write better `description`s (see `claude-parity.md`). Does the
   glob beat the sentence? (The sister note's claim-1 table is the
   evidence: 2 of the 5 hand-written nudges are intent-gated, so a glob
   wouldn't have rescued them either.)

   **Sharpened 2026-08-16, by drafting the frontmatter for a real
   12-skill catalog rather than estimating it.** Only 2 of 10 turned out
   to be clean fits; the sister note's measurement carries the arithmetic
   and the 3× correction it forced. What belongs *here* is the mechanism
   defect the exercise exposed, because it is a fact about the predicate
   and not about that catalog:

   **`paths:` fires on a file being *touched*, never on a file
   *existing*** — grok-build extracts activation paths from tool outputs,
   so nothing fires until the agent reads or writes something. But the two
   most mechanical real-world triggers are project-shape predicates:
   *"this is a Gradle project"* (`build.gradle` exists), *"this is a Maven
   project"* (`pom.xml` exists). You can work an entire Gradle session
   without ever opening a build file, so a `paths: ["build.gradle*"]`
   under-fires badly — while the honest glob for the same intent
   (`**/*.java`) over-fires on every Java project alive.

   That is a **missing predicate, not a tuning problem**, and it is
   exactly the shape of the `gradle`/`maven` nudges the sister note's
   claim 1 opens with — the two rows its own table calls "yes, exactly"
   expressible as a glob. They are not: the table conflated *file exists*
   with *file touched*. If this note is ever built, a `project-has:`
   predicate (evaluated once at catalog scan, against the workspace root)
   is cheaper than `paths:` in every dimension — no listener, no path-args
   map, no injection, no per-activation cache cost, because it resolves
   at boot and the baseline stays static. It also has no bootstrap hole.
   Worth considering *before* `paths:`, not after.
3. **A non-standard frontmatter key is a compatibility cost.** `paths:`
   isn't in the Agent Skills spec. A skill authored for pikuri would
   behave differently in Claude Code (which ignores unknown keys and lists
   it always) — arguably the safe direction, but it means the same bundle
   isn't the same skill. Adopt grok-build's spelling verbatim so at least
   two harnesses agree? (Same cost `when-to-use:` carries in the sister
   note; if both land, they should be justified together.)
4. **How many activations does a real session fire?** The load-bearing
   measurement, because each one costs an Anthropic prompt cache. 1–3 is
   noise; a chatty glob firing fifteen times makes the whole scheme a net
   loss on that provider. Measurable today with a throwaway listener over
   `Event::ToolCall`, before any of this is built.
5. **Does an activation survive `clear_conversation`?** grok-build
   `rehide`s on `/clear`. pikuri rebuilds the system prompt there, so the
   baseline returns automatically — but any injected announcements are
   discarded too, which is probably the right semantics for free. Note it
   means a long session that clears re-pays every activation, which
   interacts with question 4.
6. **Should the announcement be `:system` or something new?** It reuses
   `Event::SystemInjected`, which listeners render. A "3 skills became
   available" line is arguably chrome, not conversation. Worth a
   dedicated event so a TUI can render it as a status line rather than a
   message? The sister note raises the stakes: if the hand-off is also
   *for the human* — "here's the Tuile manual, now that you're in a Tuile
   file" — this stops being a rendering nicety and becomes the feature's
   selling point.
7. **Is an activation per-agent or catalog-wide?** Sub-agents don't
   inherit extensions, but they *do* inherit the `skill` tool via the
   tool snapshot, closing over the same catalog. So a sub-agent could
   load a gated skill by name while never seeing its description
   advertised. Bug, feature, or a reason to activate catalog-wide?
   (Compare `add_raw_tool`, which deliberately keeps MCP activation
   per-agent by staying out of `Agent#tools`. The sister note's name-only
   baseline mostly dissolves the *discoverability* half — the sub-agent
   does see the name — leaving only this scope question. Its own
   sub-agent question is the different one: who supplies the name list at
   all.)
8. **Is `mcp_connect`-shaped activation the better generalization?**
   Model-driven, one round-trip, no bootstrap hole, works for
   intent-driven families a glob can't reach. Against it: it's another
   tool schema, and it puts the decision back on the model — which is
   exactly the judgment the sister note argues is unreliable for
   correction-shaped skills. Possibly the answer splits by axis:
   harness-driven `paths:` for skills (cheap, additive, appends),
   model-driven connect for tools (expensive, prefix-busting, deserves an
   explicit decision) — the fork
   [`tool-list-in-context.md`](tool-list-in-context.md) owns.


## Graduation plan (when this settles)

- **Rejected** → the shared `DECISIONS.md` entry (the
  what-the-catalog-advertises-and-when-the-body-arrives axis, per
  `skill-cost-model.md` open question 2) gains the
  advertise-always-vs-path-gated fork, plus a one-line why-not where a
  future reader would look — probably {Pikuri::Skill::Catalog}'s yardoc,
  since the temptation recurs whenever someone's catalog gets big.
- **Built** → `paths:` semantics to {Pikuri::Skill::Catalog} yardoc, the
  activation mechanism to `pikuri-skills`' own docs, the
  observe-via-`ToolCall`-args pattern to CLAUDE.md only if it becomes a
  seam (it would be the first listener that *acts*, which is a real
  invariant worth recording against the capability seam).
- The path-args map (supplied vs. walked paths, and where the map lives)
  is a fact about tools, not about skills — if it gets built it belongs
  wherever that mechanism lands, and it should be cross-referenced from
  the Denylist seam, which names the same distinction.
- The `mcp_connect` parallel → `COMPARISON.md` or the book's skills
  material, wherever the two-tier-inventory pattern is best taught once.
- The name-only-baseline material graduates with
  [`skill-catalog-in-context.md`](skill-catalog-in-context.md), not here.
  All three skill notes land in the *same* `DECISIONS.md` entry, so
  whichever settles last edits it rather than opening a second.
