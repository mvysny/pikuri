# Slash commands — human-invoked prompt templates, alongside skills

Status: **proposal, agreed in direction, unbuilt.** Prompted 2026-08-16
by moving the `wh` skill from `~/.claude/skills/wh/SKILL.md` to
`~/.claude/commands/wh.md`, which makes it invisible to pikuri: the
catalog scans `.pikuri/skills` / `.claude/skills` / `.agents/skills` and
requires a *directory* containing `SKILL.md`, so a bare `.md` in an
unscanned dir misses twice over. Nothing in pikuri parses a typed
`/name` either — the only slash handling anywhere is the hardcoded
`/plan` / `/impl` case in three `bin/` demos.

**Scope.** This note owns the *human-invoked* half of the prompt-bundle
surface: discovery of `commands/`, argument interpolation, and how a
host dispatches one. It does **not** own anything about what the *model*
sees — the `<available_skills>` block, its cost, or when an entry is
promoted (→ `skill-catalog-in-context.md`, `skill-path-activation.md`,
`skill-cost-model.md`). The load-bearing claim of this note is that
those two halves barely touch, and the design should keep it that way.

Related:

- [`skill-catalog-in-context.md`](skill-catalog-in-context.md) — the
  sister surface, and the reason the split is cheap: every argument
  there is about *what the catalog costs in the prompt*. A command costs
  **zero prompt tokens**, so none of it applies.
- [`claude-parity.md`](claude-parity.md) — Claude-Code parity, but for
  the *prompt*. This is a *harness* parity item; if it lands, that note
  gains nothing and this one graduates on its own.
- [`assistant.md`](assistant.md) / the planned `pikuri-tui` — the only
  real consumer. See "No host today" below.


## What a slash command actually is

Not a skill with a different trigger. The two differ on every axis that
drives a design decision:

| | skill | slash command |
|---|---|---|
| who invokes | the **model**, via the `skill` tool, on a relevance judgement | the **human**, by typing `/wh swingai` |
| what it lands as | `:system` reference text (`Renderer.format_skill`) | the **user turn** — it *is* the human's request, typed short |
| advertised to the model | yes, `<available_skills>` in the system prompt | **no**, and that's the point |
| prompt cost | per skill installed, every turn, forever | zero |
| arguments | none | positional + free-text, with a hint for the UI |
| on-disk unit | directory + `SKILL.md` + sidecars | one `.md` file; subdirs are namespaces |

The middle two rows are the ones that settle the API.


## The proposal, and the three places I'd change it

The proposal as stated: a `Command` registry in `pikuri-skills`, not
exposed to LLM context; a Ruby API the TUI reads to build its `/` menu;
maybe unify with the skill catalog; and either extend
`schedule_load_skill` or add a sibling. Agreed on the first two. The
last two I'd answer differently.

### P1 — two registries, not one unified catalog

Keep `Skill::Catalog` and a new `Command::Registry` as separate types.

The reason is not tidiness, it's that **"never advertise a command to
the model" should be a property of the type, not a filter someone
remembers to apply.** `Skill::Extension#system_prompt_snippets` renders
whatever the catalog holds. Merge commands into that catalog and the
invariant becomes a `reject { it.command? }` that a future refactor can
drop silently, costing tokens on every turn and offering the model a
`skill(name: "wh")` that half-works. Two types, and the mistake is
unrepresentable.

Secondary, but real: the records genuinely differ (`argument_hint` and
an interpolatable body vs. `location`-relative sidecars and final text),
and so does the scan (recursive, bare `.md`, `:`-joined namespaces vs.
one level of `SKILL.md`-bearing dirs). One class serving both is two
classes in a trench coat.

What they *should* share is the frontmatter split, today a private
`Catalog::Bundled#split_frontmatter`. Extract it as a concrete
collaborator (composition, not a base class — a `Catalog::Bundled`
inheriting a `MarkdownScanner` is exactly the shape the project rejects).

### P2 — a command lands as `:user`, which is why it isn't a `schedule_load_skill` flag

`schedule_load_skill` injects `:system`, and its yardoc spends a
paragraph on what that *means*: reference text, no `UserTurn` event, no
`on_user_message` dispatch, and — on Anthropic — hoisted into the
top-level system param, so a host-loaded skill is **sticky for the rest
of the conversation**.

Every one of those is wrong for a command:

- **`on_user_message` must fire.** `pikuri-memory` hangs its per-turn
  prefetch/capture there. `/wh swingai` is a user request; a memory
  layer that never sees it is a silent hole.
- **Stickiness is wrong.** A one-shot "generate this week's log" that
  stays in force forever is a bug, and on Anthropic that is exactly what
  `:system` does.
- **`EmptyTurnError` disappears.** A bare `:system` load has to worry
  about system-hoisting providers raising on a blank turn. A `:user`
  injection is an ordinary turn on every provider.

So it's a different kind, not a parameter. Which leads to:

### P3 — …and it probably needs no scheduling function at all

`schedule_load_skill` exists because the host doesn't otherwise hold the
catalog→renderer wiring, and because skill loading is entangled with the
extension that also *advertises* skills. Commands have no advertisement,
contribute no tool, and touch no system prompt — so there is nothing for
an `Extension` to configure or bind. The host already owns both handles:

```ruby
cmd = registry.get('wh') or return warn_unknown
text = Pikuri::Command::Renderer.expand(cmd, arguments: 'swingai')

agent.run_loop(user_message: text)          # synchronous host
interloper.inject_user_message(text)        # async host, mid-loop
```

Two consequences worth having:

- **It's testable and usable with zero agent integration** — registry +
  renderer are pure functions over disk. `Command::Registry.new(...)`,
  `#list`, `#get`, `#roots`, `Renderer.expand`. That's the whole gem
  surface.
- **A synchronous `bin/` host can wire it today**, without an
  interloper, which is how we'd prove the API before `pikuri-tui`
  exists (see "No host today").

The one argument the other way: the `:user`-vs-`:system` choice is a
decision the library made in P2, and leaving it to each host means a
host can get it wrong by calling `inject_system_message`. Cheap
mitigation: state it in `Renderer.expand`'s yardoc and give
`Registry#expand(name, arguments:)` as the one-call form. If that turns
out to be too subtle in practice, *then* add the scheduling function —
but it's the kind of "just in case" wrapper the project's own rules push
back on.

### P4 — unify the *menu*, in the TUI, not the library

The TUI's `/` popup does want both: `/wh` (a command) and `/cop` (a
skill the human wants loaded now, via `schedule_load_skill`). But the
merge is a five-line presentation concern over two arrays that already
carry `name` + `description`, and the two halves **dispatch
differently** — one to a user turn, one to a system block. A merged
record would need a kind discriminator, at which point the library is
modelling the TUI's popup.

So: ship the two registries with deliberately parallel shapes (`#list`,
`#get(name)`, `#roots`; records both leading with `name`, `description`,
`location`) so the merge is trivial, and let the host do it. If a second
host appears and writes the same merge, *that's* when a
`Pikuri::Slash::Menu` façade earns its place.


## Prior art: Claude Code, and what to copy

`~/.claude/commands/*.md` (user) and `.claude/commands/*.md` (project).
Subdirectories namespace: `commands/frontend/foo.md` → `/frontend:foo`.
Frontmatter: `description`, `argument-hint`, `allowed-tools`, `model`,
`disable-model-invocation`. Body interpolates `$ARGUMENTS` (all args
verbatim) and `$1`…`$9` (positional); `` !`cmd` `` runs bash at expansion
time and inlines the output; `@path` inlines a file.

Copy:

- **`description` + `argument-hint`.** Both are pure UI metadata for the
  `/` popup — `wh.md` carries
  `argument-hint: <project-label> [--since YYYY-MM-DD]` and that is
  exactly what the menu should render.
- **Namespacing.** Three lines, and a flat scanner would *silently miss*
  namespaced commands rather than degrade — worse than not supporting
  them.
- **`$ARGUMENTS` / `$n`.** Trivial, and the only interpolation that
  can't be replaced by prose.
- **Lenient validation**, matching the catalog: unknown keys ignored, a
  missing `description` the only hard failure.

Drop:

- **`` !`cmd` `` bash pre-execution — settled: never.** (Decided
  2026-08-16, on confirming Claude Code really does this: a body line
  like ``- Current status: !`git status` `` runs the command *before the
  prompt is sent* and inlines its stdout, gated only by the command
  file's own `allowed-tools:` frontmatter — i.e. gated by the untrusted
  file itself.) This is the whole threat model of the feature. With it,
  a `.md` in a scanned directory is arbitrary code execution triggered
  by typing a slash: no confirmer, no sandbox, no `Subprocess` seam, and
  a `.claude/commands/` dir that travels with a cloned repo. Without it
  a command is *text*, and its worst case is prompt injection into a
  turn the human deliberately typed — which is also what keeps the
  feature inside `pikuri-skills` rather than earning its own gem.

  Note this is not merely "unimplemented": the `!` line must be
  **inert**, and `allowed-tools:` must stay an ignored key. Silently
  dropping a `!`-line's *output* while leaving its text in the prompt is
  the quiet failure — the model then reasons about a `git status` it
  never saw. Preferred handling is to pass the line through verbatim as
  literal text, so the human can see why the command misbehaved.
- **`allowed-tools` / `model`.** pikuri fixes tools at `configure` time
  and the model at transport construction. Neither is amendable
  mid-conversation, and inventing a seam for it is far more than this
  feature is worth. Ignore the keys.
- **`disable-model-invocation`.** Inverted by default: pikuri never
  exposes commands to the model, so every command behaves as if this
  were set. That's the deliberate divergence, and it's what makes the
  feature cost zero tokens.

### Unreferenced arguments: a near-miss, now closed at the source

`wh.md` originally contained no `$ARGUMENTS` and no `$1` — it asked for
its argument in *prose* ("the first argument, e.g. `/wh swingai`"), and
so depended on Claude Code making the raw argument text visible without
a placeholder, presumably by appending it. That would have made "append
unreferenced arguments" load-bearing for the very file that motivated
this note.

Fixed at the source instead (2026-08-16): `wh.md` now interpolates
explicitly — `$1` for the label, `$ARGUMENTS` for the `--since` flag it
can't address positionally. So no *known* command depends on the append
behaviour.

That downgrades open question 1 from a prerequisite to a compatibility
question — but doesn't delete it. The whole point of reading
`.claude/commands` is that bundles travel, and a hand-written command
that names its arguments in prose is clearly a shape people write (we
just wrote one). Whether pikuri appends unreferenced arguments decides
whether those files work or silently ignore what the human typed —
silently, because a command body has no way to signal it didn't see an
argument. Lean: append, as a trailing
`(arguments: <raw>)` line, when the body references neither placeholder.


## What pikuri already has

| need | today |
|---|---|
| frontmatter parse + lenient validation | `Catalog::Bundled#split_frontmatter` / `#parse_skill` — extract and reuse (P1) |
| search-base precedence, first-wins, shadow warning | `Catalog::Bundled#scan_root` — same shape, mirror it |
| deliver a user turn mid-loop | `Control::Interloper#inject_user_message` — already the right kind, already thread-safe |
| deliver a user turn synchronously | `Agent#run_loop(user_message:)` |
| let the model read files a command body points at | wire `Registry#roots` into `Workspace::Filesystem`'s `readable:`, exactly as hosts already do with `catalog.roots` |
| a home for the code | `pikuri-skills`' Zeitwerk loader is rooted at its `lib/`, so `lib/pikuri/command/registry.rb` → `Pikuri::Command::Registry` needs no loader change |

Note the namespace: `Pikuri::Command::*`, not `Pikuri::Skill::Command*`
— a command is not a skill. The gem keeps its name and its README grows
a second section; renaming `pikuri-skills` to cover both is churn for a
cosmetic gain.


## No host today — say it out loud

`bin/pikuri-*` are demos with synchronous stdin and no interloper, and
`pikuri-tui` doesn't exist. So this would be a **second unconsumed API**,
after the interloper itself (whose yardoc already says "groundwork for
downstream TUI/web hosts"). That's a legitimate precedent but not a free
one.

The mitigation falls out of P3: because expansion needs no interloper, a
`bin/` demo can dispatch a command synchronously — parse the typed line,
`Registry#get`, `Renderer.expand`, pass the result as `user_message:`.
`bin/pikuri-code` already special-cases `/plan` and `/impl` in exactly
that spot (`pikuri-code/bin/pikuri-code:526`), so the wiring is one
`else` branch. That's a real consumer, it proves the API, and it stays
within "a `bin/` script takes the crudest handling that works".

If we're not willing to add even that, the feature is speculative and
should wait for the TUI.


## Open questions

1. **What does Claude Code do with arguments a body never references,
   and should pikuri match it?** No longer load-bearing for `wh.md`
   (see above), but still a compatibility question for imported
   bundles. Testable in five minutes: a command whose body is
   `print the word FOO only`, invoked as `/that bar`, and see whether
   `bar` shows up.
2. **Which directories does the registry scan?** `.pikuri/commands` and
   `.claude/commands` are obvious. Is there an `.agents/commands`
   convention in PI, mirroring `.agents/skills`? Don't add the third
   until someone confirms it exists — an invented convention is worse
   than a missing one.
3. **Name collision between a command and a skill.** `/wh` when both
   exist. Options: commands win in the slash namespace (they're the
   human-invoked one) with a warning; or the menu shows both with
   distinct affordances. Only bites once there's a merged menu (P4), so
   it can be decided by the host that first hits it.
4. **Does a command body get the `<command>`-wrapper treatment?**
   `Renderer.format_skill` wraps a skill in `<skill name= location=>`
   with a sidecar-path preamble. A command lands as a *user* turn, where
   an XML wrapper reads oddly — the human "said" this. But without one,
   a body pointing at a sidecar file has no base directory to resolve
   against. Lean: no wrapper; append a one-line
   `(this command lives in <dir>)` footer only when the registry sees a
   sibling file. Unsettled.
5. **Is the expansion trusted or untrusted text?** `SkillTool` declares
   `untrusted: :hard` precisely because a skill is a file someone else
   wrote. A command file is the same bytes with the same provenance —
   but it arrives as a *user* turn, the most-trusted role, on the
   human's deliberate keystroke. Is that a downgrade we're comfortable
   with? Probably yes (the human typed `/wh`, which is consent in a way
   a model's `skill(name:)` is not), but it should be an explicit
   sentence somewhere, not an accident of the injection kind.
6. **Should `argument_hint` be parsed or passed through?** Claude Code
   treats it as an opaque display string. Parsing it into required /
   optional slots would let the TUI validate before dispatch, and would
   let the library reject `/wh` with no args. Almost certainly not worth
   it — pass the string through, let the model handle a missing
   argument the way `wh.md` already does ("if no label was given, use
   'swingai'").


## Graduation plan (when this settles)

- **Built** → `Pikuri::Command::Registry` / `Renderer` yardoc owns the
  per-symbol truth (scan order, precedence, interpolation rules, the
  `:user`-kind contract). `pikuri-skills`' README grows a commands
  section. The book's skills chapter gains the human-invoked-vs-
  model-invoked distinction — that's the concept, and it's taught once.
- **The invariant for CLAUDE.md** is one line, and it's P1: *a command is
  never advertised to the model; `Command::Registry` contributes no
  system-prompt snippet and no tool.* Grep tripwire:
  `grep -rn 'Command::Registry' pikuri-*/lib/` never appears in a
  `system_prompt_snippets` or `add_tool` neighbourhood. Worth an entry
  next to the Capability seam only if a host actually wires it.
- **`DECISIONS.md`** gets the real forks, which are P1–P3: one catalog
  vs. two registries; `:user` vs. `:system` injection; and the dropped
  `` !`cmd` `` leg with its threat-model reasoning. That last one
  graduates **whether or not this feature is built** — it is the entry a
  future reader is most likely to need, since "just add bash
  preexecution, Claude Code has it" is the obvious recurring temptation,
  and the answer (`allowed-tools:` in the untrusted file is not a gate)
  is not reconstructible from code that never grew the feature. These
  are separate from the skill notes' shared advertise-and-when entry —
  different axis, different decision.
- **Rejected** → a one-line why-not in `Pikuri::Skill::Catalog`'s
  yardoc, since "why doesn't pikuri see my `.claude/commands`?" is the
  question that lands there.
