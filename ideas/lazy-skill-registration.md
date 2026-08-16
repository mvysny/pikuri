# Lazy skill registration — a skill that stays out of the catalog until it's relevant

Status: **idea, not built.** Split out of
[`skill-load-cost.md`](skill-load-cost.md), where it arrived disguised as
`feedback.txt` item 3(a) ("auto-inject `cop` and `tuile` when the path is
`lib/**/*.rb`"). That framing is rejected over there and stays rejected.
This note is the *other* thing the same mechanism can do — and it is a
different feature with a different cost profile, which is why it gets its
own file.

Related:

- [`skill-load-cost.md`](skill-load-cost.md) — the cost arithmetic that
  rules out body pre-injection, and the rest of the feedback item.
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
   `Agent#tools`.)
5. **Does an activation survive `clear_conversation`?** grok-build
   `rehide`s on `/clear`. pikuri rebuilds the system prompt there, so the
   baseline returns automatically — but any injected announcements are
   discarded too, which is probably the right semantics for free.
6. **Should the announcement be `:system` or something new?** It reuses
   `Event::SystemInjected`, which listeners render. A "3 skills became
   available" line is arguably chrome, not conversation. Worth a
   dedicated event so a TUI can render it as a status line rather than a
   message?


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
