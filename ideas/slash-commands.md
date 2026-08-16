# Slash commands — human-invoked prompt templates, alongside skills

Status: **proposal, agreed in direction, unbuilt.** Prompted 2026-08-16
by moving the `wh` skill from `~/.claude/skills/wh/SKILL.md` to
`~/.claude/commands/wh.md`, which makes it invisible to pikuri: the
catalog scans `.pikuri/skills` / `.claude/skills` / `.agents/skills` and
requires a *directory* containing `SKILL.md`, so a bare `.md` in an
unscanned dir misses twice over. Nothing in pikuri parses a typed
`/name` either — the only slash handling anywhere is the hardcoded
`/plan` / `/impl` case in three `bin/` demos.

**Reviewed against the code, 2026-08-16.** P1–P4 stand and every claim
about pikuri's internals checked out. Open questions 2 and 4 closed in
that pass, and three things the note didn't record were found and folded
into the sections they belong to: `@path` fell through both the Copy and
the Drop list, the catalog's *missing-`description`* hard failure was
borrowed without the rationale that justifies it, and `Registry#get`
turned out to carry two contracts that P3's sample only showed one of.
The `allowed-tools:` refusal also grew the paragraph reconciling it with
how pikuri treats the same key on a skill.

**Question 1 closed the same day, by measurement** against Claude Code
2.1.233 — see *Unreferenced arguments*. It confirmed the lean (arguments
a body never references are appended) and turned up three things nobody
was looking for: the expansion is XML-wrapped, `$n` is off by one, and
`wh.md`'s `$1` did not work.

**Second review pass, 2026-08-16 — the mechanics, not the forks.** The
two earlier passes audited the *security and API* forks, and all of it
held. This one asked instead what an implementer would still have to
invent, and found that the **interpolation contract had never been
written down** — every pass had walked past it. Settled here: argument
tokenization, the `$n` range, out-of-range handling (flipped, see
finding 3), where a command's name comes from, the no-frontmatter file,
and the question-4 footer gate, which as written gated nothing. The pass
also caught two rotted cross-references and one finding that the file it
described had outrun.

**Question 3 settled 2026-08-16**, pulled forward by the decision to
wire commands into the `bin/` demos, which need typed-`/name` resolution
before any menu exists. Answer: **host built-in > command > skill**,
warn on a collision, never raise — the house style, confirmed against
`Catalog::Bundled`, which does not raise either (it keeps the
first-listed base and warns). That pass also found a **third kind** in
the namespace the note had only ever counted two of — `/plan` and
`/impl` are host built-ins, not commands — and with it a real hijack: a
cloned repo shipping `.claude/commands/plan.md` would otherwise capture
the read-only plan-mode toggle, silently.

**Question 5 turned out not to be a sentence of yardoc.** Asked properly
(2026-08-16) it is a **detector blind spot**: a command contributes no
tool and — under P3 as written — no extension, so a wired command
surface lands nowhere in the `Pikuri::Trifecta` tree, and an agent
holding all three legs reports two. The proposal is `untrusted: :hard`,
declared through `Extension#trifecta_contribution`, which costs P3 a
narrow amendment (a declaration-only `Command::Extension`). `:hard` is
the *default*, not the answer: trust is graded **per source** —
project-base bundles inherit `Workspace::Filesystem#trusted?`, home-base
ones take a declared flag defaulting `false`. That grading channel does
not exist yet and reaches skills too (`SkillTool` is unconditionally
`:hard`), so it is **its own note and its own `DECISIONS.md` entry**;
commands ship at `:hard` and adopt it when it lands.

**Question 7 settled 2026-08-16 — rule C, fence- and span-aware for
both tokens** (author's call, on the lean the second pass had reached).
Settling it turned up the consequence nobody had traced: the *append*
gate has to read the same way, and under C the file that motivated this
whole note interpolates nothing at all. See there.

**Question 5 settled 2026-08-16, and question 2's second axis with it** —
the untrusted leg is declared, and *graded per command source* by the
algorithm skills already got: a trust flag on every search base, unioned
over what the registry stored, `:hard` still what silence buys. Settling
it turned up a payoff (the file that motivated this note comes out
**trusted**, so the banner stays quiet over it) and a prerequisite whose
window is closing (the shared `Base` record). See there.

What is left is one unstamped lean (question 6), the build-or-wait call
in *No host today*, and the `DECISIONS.md` entries that graduate whether
or not this is ever built.

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
  **zero prompt tokens**, so none of it applies. Its **question 8** is
  where the two surfaces cross: it counts `disable-model-invocation:`
  among the three dependents of the host-driven load path, and this note
  is the argument that it is not one of them.
- [`skill-cost-model.md`](skill-cost-model.md) — the 12-skill catalog
  measurement, and **this note's second motive** (its deferred item 6).
  See below; read that item and this note together, they answer each
  other.
- `DECISIONS.md` `D-bundle-trust-grading` — question 5's spin-off,
  **shipped 2026-08-16**: a catalog declares its skills user-authored per
  search base (`Bundle::Base`), so the untrusted leg is graded
  over what was actually loaded instead of pinned at `:hard`. Commands
  adopt that channel rather than inventing one — **settled 2026-08-16**
  (question 5), which makes the `Base` record shared rather than
  skill-owned and hands that entry an amendment to carry.
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

### The second motive: it's also the fix for a measured resident cost

This note started as "pikuri can't see my commands dir".
`skill-cost-model.md`'s catalog measurement (2026-08-16) supplies an
independent second reason, and it's the stronger one.

Two of the 12 skills measured — `wh` and `grill-me` — were
slash-commands filed as skills. `wh` even carried `argument-hint:`, a
command frontmatter key. Their descriptions were resident tokens spent
**telling the model to ignore them**, on every turn, forever (`wh`'s
read *"Only invoked manually."*). The sister notes' mechanism for
withholding such a bundle is a `disable-model-invocation:` frontmatter
key — recorded in `skill-cost-model.md`'s deferred item 6 as *noted, not
proposed*, and counted in `skill-catalog-in-context.md`'s question 8 as
one dependent of the host-driven load path. Neither note argues *for*
it, which is the opening this one takes: they aren't skills at all. A
bundle the human invokes belongs on the human-invoked surface, where it
costs nothing resident because it was never advertised in the first
place.

Both moved to `~/.claude/commands/` the same day — **and thereby became
invisible to pikuri**, which is the regression this note closes. So the
two notes answer each other: theirs is "how do we stop paying for a
human-only bundle?", ours is "stop filing it as a skill", and that only
works once pikuri reads the other directory.

Worth stating plainly because it changes the priority. As "read my
commands dir" this is a convenience with no in-repo consumer (see "No
host today"). As "the surface that makes a whole category of skill cost
zero", it's the cheapest of the three mechanisms that note is weighing —
no matcher, no listener, no path-args map, no injection channel, no
per-activation cache invalidation.


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
cmd = registry.get('wh') or return warn_unknown   # …and rescue Refused
text = Pikuri::Command::Renderer.expand(cmd, arguments: 'swingai')

agent.run_loop(user_message: text)          # synchronous host
interloper.inject_user_message(text)        # async host, mid-loop
```

Two consequences worth having:

- **It's testable and usable with zero agent integration** — registry +
  renderer are pure functions over disk. `Command::Registry.new(...)`,
  `#list`, `#get`, `#roots`, `#expand(name, arguments:)` (the one-call
  form argued at the end of this section), and `Renderer.expand`. That's
  the whole gem surface — six entries, and the `#expand` pair is one
  delegation, not two implementations.
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
- **Namespacing — and with it, the name.** A command's name *is* its
  path: the `.md` stem, prefixed by whatever subdirectories it sits
  under within the scanned dir, `:`-joined —
  `commands/frontend/foo.md` → `frontend:foo`. Three lines, and a flat
  scanner would *silently miss* namespaced commands rather than degrade
  — worse than not supporting them.

  **A frontmatter `name:` is ignored** (settled 2026-08-16; the note
  named the namespacing rule and never said where the *name* came from).
  This is the one place the command record deliberately diverges from
  `Catalog::Skill`, where `name:` overrides the parent directory. For a
  skill the name is a label the model reads; for a command it is the
  **address the human types**, and an address that its location doesn't
  predict is not an address. Warn on a mismatch, load under the path.
- **`$ARGUMENTS` / `$n`.** Trivial, and the only interpolation that
  can't be replaced by prose. Riders from the 2026-08-16 measurement:
  append `ARGUMENTS: <raw>` — that exact spelling — when the body
  references neither, and implement `$n` **1-based**, the one place this
  note knowingly diverges from Claude Code 2.1.233 (0-based in the
  binary, 1-based in its own docs and in every body anyone writes). An
  out-of-range `$n` stays **literal text**, matching Claude Code — this
  reversed on the second review pass; see finding 3. Reasoning and the
  probe transcript live in *Unreferenced arguments* below.

  **Both halves skip fenced blocks and inline code spans** (question 7,
  settled): the substitution *and* the "references neither" check that
  gates the append. One function, or a body that merely *mentions* a
  token in backticks gets neither substitution nor append, and the
  argument the human typed is silently gone.
- **The tokenizer, spelled out** (settled 2026-08-16 — the note wrote
  `$n` throughout and never said what *n* indexes, which is the first
  thing an implementer needs). `$ARGUMENTS` is the raw argument string,
  verbatim, exactly as typed after the command name. `$1`…`$9` index
  that string **split on whitespace** — no quote handling, no flag
  awareness. `/wh swingai --since 2026-08-10` gives `$1 = swingai`,
  `$2 = --since`, `$3 = 2026-08-10`. Three deliberate non-features:

  - **No shell quoting.** `/foo "two words"` is three tokens, one of
    them `"two`. Supporting quotes means picking a quoting dialect and
    then owning its escapes forever; a body that wants a multi-word
    argument should read `$ARGUMENTS`, which is what it meant.
  - **Nine, not unbounded.** `$1`…`$9` is what the prior art documents,
    so it is the range authors write against. A body wanting a tenth
    positional is a body that should be parsing `$ARGUMENTS`.
  - **No flag parsing.** A command mixing flags with positionals reads
    them off `$ARGUMENTS` — which is the shape `wh.md` arrived at on its
    own, unprompted, for exactly this reason.
- **Lenient validation**, matching the catalog on unknown keys — ignored.
  **But not its hard failure** (revised 2026-08-16): `Catalog::Bundled`
  drops a skill with no `description` because for a *skill* the
  description **is** the activation surface — the model never sees the
  body, so a description-less skill is unusable by construction. A
  command has no activation surface: the human types `/wh` by name, and
  the description is chrome for the popup. Inheriting the hard failure
  would make an imported command *silently absent from the menu* for a
  reason that stopped applying at the surface boundary. So: warn, fall
  back to the name as its own display string, and load it.

  **Nor its *other* silent drop** (spotted 2026-08-16, one layer along
  from the same trap): `parse_skill` also returns nil when
  `split_frontmatter` finds no frontmatter block at all, reasoning that
  such a file was *"not meant as a skill"*. That is a fair inference
  about a stray `.md` sitting inside a skill *directory*, and the wrong
  one here — under `commands/`, a frontmatter-less `.md` is an ordinary
  command. Frontmatter is optional in the prior art and every key in it
  is UI chrome; the body is the whole point and it is right there. So:
  no frontmatter ⇒ the entire file is the body, the name comes from the
  path as always, the description falls back to the name. Nothing on
  disk would have caught this — both files in the directory that
  motivated this note happen to carry frontmatter.

  Accepted consequence: with no frontmatter requirement left, *every*
  `.md` under a scanned `commands/` dir is a command, a stray
  `README.md` included. That is what the prior art does, and the failure
  mode is a junk entry in a menu the human is looking at — recoverable
  by eye, unlike a real command silently missing from it.

  Together these leave the registry with **no hard failure at all**
  except the two refusals below — which is the right shape, since a
  command that parses is a command the human can invoke.

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

- **`allowed-tools:`, on its own merits.** Independent of `!`, this key
  is a *restriction* the author asked for. pikuri fixes tools at
  `configure` time and cannot narrow them mid-conversation, so honouring
  it is out of reach — but **ignoring** it runs the command with the
  full toolset when the author asked for a fenced one. That's a
  widening, not a no-op, and it's why this key doesn't get the
  ignore-unknown-keys treatment the rest of the frontmatter does.

  **The asymmetry this creates, and why it stands** (spotted 2026-08-16,
  reviewing against `COMPARISON.md`'s frontmatter table): `allowed-tools`
  is **one of the six official Agent Skills fields**, and pikuri's row in
  that table reads a flat *"no"* — `Catalog::Bundled#parse_skill` reads
  `description` and `name` and drops everything else. So under this
  proposal pikuri would **hard-refuse** the key on a command while
  **silently ignoring** the identical key on a skill, where the same
  widening argument applies word for word. Worth stating out loud,
  because the widening argument alone does *not* justify the split — it
  reaches both surfaces. What justifies it is compatibility asymmetry:

  - the *skill* surface is shipped, and the key is **spec-sanctioned**,
    so refusing it would break catalogs that are doing nothing wrong by
    carrying a field the standard defines. `COMPARISON.md`'s finding 3
    is the general form of the same posture — a key the host doesn't
    implement is advertised unconditionally, everywhere — so pikuri
    failing open on it is the herd behaviour, not an oversight.
  - the *command* surface does not exist yet, and the key is **not
    spec** — it is Claude Code's own, where its documented role is
    gating `` !`cmd` `` pre-execution. Refusing costs nobody a working
    bundle today, and refusing a gate for a feature we don't implement
    is the coherent position.

  So the rule is: refuse on the new surface, where it is free; fail open
  on the established one, where the field is standard. If someone later
  wants the skill side tightened, that is the sister notes' axis (what
  the catalog does with frontmatter), not this one — but it should cite
  this paragraph, because the two decisions are only defensible together.

- **`@path` file inlining — dropped, and *not* by refusing it.** (Added
  2026-08-16; the note previously listed this in the prior-art paragraph
  and then decided neither way.) Unlike `` !` ``, it executes nothing —
  but it *reads a file the untrusted `.md` chose* and inlines the bytes
  into a user turn, at expansion time, in-process, reaching no
  `resolve_for_read` and consulting no denylist. That is the Workspace
  seam bypassed by a file that travels with a cloned repo: a line
  reading `@~/.ssh/id_rsa` in a `.md` nobody opens puts the key in the
  prompt — a leak to the provider on its own, and a handed-over payload
  for whatever egress leg the wiring happens to have.

  But the handling differs from the other two, deliberately. `!` earns a
  raise because a literal `` !`git status` `` left in the prompt reads
  to the model as an instruction (see below). `@path` has no such second
  reading: a literal `@docs/style.md` sitting in the text reads as *a
  path mention*, and the worst case is the model deciding to `read` it —
  through the gated tool, against the workspace, exactly as we'd want.
  So `@path` is simply **not interpolated**; it passes through as
  literal text, with no scan-time warning and no refusal.

  Which is also why detection must **not** be over-eager here, inverting
  the rule stated below for `!`: `wh.md` contains `mavi@vaadin.com` and
  `martin@vysny.me`, so anything hunting `@`-shapes false-positives on
  the file that motivated this note. There is nothing to hunt — leaving
  the character alone is the whole implementation.

  This closes open question 4 as a side effect; see there.

- **`disable-model-invocation`.** Inverted by default: pikuri never
  exposes commands to the model, so every command behaves as if this
  were set. That's the deliberate divergence, and it's what makes the
  feature cost zero tokens.

### Refusing the two, and why fail-closed beats pass-through

Settled 2026-08-16: **`Registry#get` raises** when a command declares
`allowed-tools:` or its body contains a `` !`…` `` directive. Not
"ignored", not "rendered inert" — unavailable, with an exception naming
the file and the trigger. Reverting is a feature request, which is
exactly the signal we'd want before building the confirmer-gated version.

This replaces an earlier proposal in this note to pass the `!` line
through as literal text so the human could see it. That was wrong: a
literal `` !`git status` `` sitting in the prompt reads to the model as
an *instruction*, so the likely outcome isn't "visibly misbehaves", it's
"the model runs `git status` through the real `bash` tool a beat later".
Which is more or less the behaviour we refused, arrived at
unpredictably. An exception has no such second reading.

Design notes for whoever builds it:

- **Raise at retrieval, warn at scan.** Keeping the entry in `#list`
  means the human types `/foo` and learns *why* it's unavailable;
  skipping it at scan time (the catalog's handling for a missing
  `description`) makes it silently absent from the menu, which is the
  same discoverability failure one layer up. A scan-time warning covers
  the host that never renders the exception.
- **A dedicated error class** — a host needs to rescue this precisely
  and turn it into a message, not a backtrace. It is host-facing: it
  never reaches a tool, so the `"Error: …"`-string convention for
  model-visible failures doesn't apply.
- **Be over-eager on detection, deliberately.** A false positive
  (a command body that merely *discusses* the syntax, or carries one
  inside a fenced block) is a loud exception on a file the author can
  trivially edit. A false negative is silent semantic drift. Don't try
  to skip fenced code blocks. Also match `allowed_tools` alongside the
  documented `allowed-tools`. **This rule is about *detection* and does
  not carry over to *substitution*,** where the polarity inverts and a
  false positive is silent — see question 7, which is where that got
  noticed and which settled the opposite way (rule C).
- **Only these two.** `model:` stays an ignored key — running the right
  prompt on the wrong model is a quality issue, not a widening. `@path`
  is dropped by *not interpolating it*, which is a third handling, not a
  third refusal — see the Drop list.
- **Say both of `#get`'s contracts in one sentence, because there are
  two** (spotted 2026-08-16): it returns **nil** for a name that isn't
  there, and **raises** for a name that is there but refused. P3's
  sample (`registry.get('wh') or return warn_unknown`) only shows the
  first, so a host written from it dies on the second — and the demo
  host in "No host today" is exactly such a host. The yardoc gets both,
  the `bin/` branch gets the rescue, and the pair is worth a spec each.
  The shape is deliberate rather than awkward: *absent* is an ordinary
  outcome the human caused by typo, *refused* is a fact about a file on
  disk that the human can't fix by retyping.
- **The record carries the refusal, from scan time** (spotted
  2026-08-16). "Raise at retrieval, warn at scan" means detection has
  *already run* during the scan — so the refusal and its trigger are a
  field on the stored record, not something `#get` re-derives by
  re-reading the file. Which means `#refused?` plus its reason string is
  free the day this ships; there is nothing to store later. What is
  actually deferred is only the host-side affordance — whether a `/`
  menu greys the entry out instead of letting the invoke raise is the
  host's call, and it changes nothing here.

### Unreferenced arguments: a near-miss, now closed at the source

`wh.md` originally contained no `$ARGUMENTS` and no `$1` — it asked for
its argument in *prose* ("the first argument, e.g. `/wh swingai`"), and
so depended on Claude Code making the raw argument text visible without
a placeholder, presumably by appending it. That would have made "append
unreferenced arguments" load-bearing for the very file that motivated
this note.

Fixed at the source instead (2026-08-16): `wh.md` now interpolates
explicitly rather than asking in prose. It settled — after an
intermediate version that used `$1`, see finding 4 — on `$ARGUMENTS`
alone, reading both the label and the `--since` flag off the raw string.
So no *known* command depends on the append behaviour. `grill-me.md`,
the only other file in that directory, references neither placeholder
and takes no arguments, so the rule is unobservable there too.

That downgrades open question 1 from a prerequisite to a compatibility
question — but doesn't delete it. The whole point of reading
`.claude/commands` is that bundles travel, and a hand-written command
that names its arguments in prose is clearly a shape people write (we
just wrote one). Whether pikuri appends unreferenced arguments decides
whether those files work or silently ignore what the human typed —
silently, because a command body has no way to signal it didn't see an
argument. Lean was: append, as a trailing `(arguments: <raw>)` line,
when the body references neither placeholder.

### Measured, 2026-08-16 — and the lean was right about the *what*

Run against **Claude Code 2.1.233**, headless (`claude -p "/probe ALPHA
BRAVO"`) in a throwaway project holding nothing but
`.claude/commands/*.md`. Each probe body asked the model to echo its own
user message verbatim in a fenced block; every result below reproduced
on two models (haiku and sonnet), which is what rules out the model
paraphrasing rather than reporting. The expansion is:

```
<command-message>probe</command-message>
<command-name>/probe</command-name>
<command-args>ALPHA BRAVO</command-args>      ← only when args were typed
<body, with $ARGUMENTS / $n substituted>


ARGUMENTS: ALPHA BRAVO                        ← only when the body referenced neither
```

Four findings, in ascending order of how much they change:

1. **Yes, it appends** — as a trailing `ARGUMENTS: <raw>` block after two
   blank lines, and only when the body references neither `$ARGUMENTS`
   nor a `$n`. With no arguments typed, neither the tag nor the block
   appears. So the lean was right, and pikuri should **copy the spelling
   verbatim** rather than invent `(arguments: …)`: a body authored
   against Claude Code then reads identically here, which is the entire
   point of scanning someone else's directory.
2. **It wraps** — see open question 4, which this partly re-opens and
   then closes the same way.
3. **`$n` is off by one, and it is Claude Code's bug, not a convention.**
   `/probed AAA BBB CCC` against a body reading
   `one=[$1] two=[$2] three=[$3] all=[$ARGUMENTS]` expands to
   `one=[BBB] two=[CCC] three=[$3] all=[AAA BBB CCC]`. `$ARGUMENTS` is
   correct; `$n` indexes the argument list **0-based** while being
   documented and universally written as 1-based, so `$1` yields the
   *second* word. An out-of-range `$n` is left as **literal text**, not
   emptied — so a one-argument invocation leaves the characters `$1`
   sitting in the prompt.

   pikuri should implement **1-based, as documented and as every author
   writes it**. This is the one place to knowingly diverge from observed
   Claude Code behaviour: matching the bug would mean matching it
   forever, and nobody authored *against* it — the shape it produces is
   a body that silently reads the wrong word, which an author is far
   likelier to have papered over than noticed.

   **The out-of-range half is *not* a divergence — reversed 2026-08-16**
   on the second review pass. This finding originally bundled two
   changes: 1-based indexing *and* "blank an out-of-range `$n` rather
   than leaking the placeholder". The second is wrong. Blanking makes a
   `$1` the author never meant as a placeholder silently *vanish*;
   leaving it literal leaves the mistake visible in the prompt, where a
   human reading the transcript can see it. Every other call in this
   note leans the same way — raise at retrieval, be over-eager on
   detection, errors are loud — and the counter-evidence arrived within
   the day: see finding 4, whose file now carries a `$1` in prose that
   means nothing of the sort. So: **1-based, and an out-of-range index
   passes through untouched**, exactly as Claude Code does it.
4. **`wh.md`'s `$1` did not work** — the file that motivated this note,
   checked as a consequence of finding 3. `/wh swingai` is a
   single-argument invocation, so its `$1` was out of range: the label
   never landed in the placeholder and the literal `$1` survived into
   the prompt.

   **Superseded the same day — the author routed around the bug rather
   than waiting for us to fix it.** (Recorded on the second review pass,
   2026-08-16, from the file on disk rather than this note's account of
   it.) `wh.md` no longer uses `$1` as a placeholder at all: it reads
   the label off `$ARGUMENTS`, and carries a parenthetical saying why —
   *"positional expansion is off by one in Claude Code 2.1.233, so `$1`
   yields the second word."*

   Two consequences, pulling opposite ways:

   - The note argued that under pikuri's 1-based rule "the file behaves
     as its author intended, with no edit", and offered that as evidence
     for the divergence. **That evidence is gone** — there was an edit,
     and it went the other way. Finding 3's divergence now rests on its
     own argument (nobody authored *against* the bug), which is still
     the right one, but it stands alone.
   - The file is now evidence for something sharper. It contains the
     characters `$1` in **prose**, inside backticks, meaning nothing but
     themselves — plus a fenced bash block using `$(…)` and `$monday`. A
     renderer that substitutes blindly eats them. That is **question
     7**, and the file that motivated this whole note trips it on day
     one.


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
should wait for the TUI — but note that the second motive above raises
the stakes on waiting: every day this isn't built, two bundles that used
to be reachable from pikuri aren't.


## Open questions

1. ~~**What does Claude Code do with arguments a body never references,
   and should pikuri match it?**~~ **Closed 2026-08-16 by measurement**
   — it appends `ARGUMENTS: <raw>`, and pikuri copies the spelling. The
   probe also turned up the `$n` off-by-one and the expansion wrapper;
   all four findings are in *Unreferenced arguments* above, and the two
   that changed a decision are folded into the Copy list and question 4.
2. **Which directories does the registry scan?** `.pikuri/commands` and
   `.claude/commands` are obvious. Is there an `.agents/commands`
   convention in PI, mirroring `.agents/skills`? Don't add the third
   until someone confirms it exists — an invented convention is worse
   than a missing one.

   **Half-answered 2026-08-16** by the survey already in `COMPARISON.md`:
   grok-build — the harness with the widest discovery net of anyone,
   scanning four vendors' skill dirs — grows commands from *flat `*.md`
   under a `commands/` directory*, and nothing in that survey names an
   `.agents/commands` anywhere. So the two-subdir answer stands with
   evidence behind it rather than as a shrug, and the third stays
   unbuilt.

   **The half the survey can't answer is the other axis: which *search
   bases*** — and the note never asked it. `Catalog::Bundled` takes `search_bases:` (project root,
   `Dir.home`, …) and crosses them with its subdir list; this note names
   subdirs everywhere and bases nowhere. It matters more here than for
   skills, because the file that motivated the whole note lives at
   `~/.claude/commands/wh.md` — under the **home** base, with nothing
   project-local involved. Mirror the kwarg rather than hardcoding a
   root: same shape, same left-to-right first-wins precedence, and the
   motivating file is reachable on day one.

   **Settled 2026-08-16, as part of question 5** — and it is not merely
   the same kwarg but the same *records*: `search_bases:` takes
   `Base(dir:, trusted:)`, so a host builds one base list and hands it
   to both surfaces. Precedence, first-wins and the bare-path-means-
   untrusted fallback all come along unchanged.
3. **Name collision in the typed slash namespace.** ~~Only bites once
   there's a merged menu (P4), so it can be decided by the host that
   first hits it.~~ **Settled 2026-08-16**, pulled forward because the
   `bin/` wiring needs an answer before any menu exists.

   **First, the precedent — which is not a raise.** The question isn't
   novel: `Catalog::Bundled` already answers the *skill-vs-skill* form.
   `scan_root` keeps the first entry seen and logs `"… is shadowed by
   earlier entry at …"` for the loser (spec: *"on a name collision keeps
   the first-listed base and logs a warning"*), and `bin/pikuri-code`
   passes `search_bases: [project_root, Dir.home]`, so a project skill
   beats a global one of the same name. No exception anywhere on that
   path. So the house style for a name collision is **deterministic
   winner plus a warning**, and this decision inherits it rather than
   inventing a stricter one.

   **Second — there are three kinds in that namespace, not two.**
   `/plan` and `/impl` in `bin/pikuri-code` are neither commands nor
   skills: they are **host built-ins**, handled by the REPL and never
   sent to the model (they flip the shared `ReadOnly` flag). Any host
   that grows a command registry has all three, and the note had only
   ever considered two.

   Precedence, highest first: **host built-in > command > skill.**

   - **Host built-in beats a command, and this leg is load-bearing
     rather than cosmetic.** Commands are scanned from the project root
     (question 2), so a cloned repo carrying `.claude/commands/plan.md`
     would otherwise capture `/plan` — and `/plan` is the read-only
     plan-mode toggle. A repo that shadows it silently disables the gate
     the human believes they just switched on, and the failure is
     invisible: the agent answers a prompt instead of entering plan
     mode, which reads as the model being chatty, not as a hijack.
     Built-ins are a fixed, host-authored list, so they are matched
     first and no scanned file ever enters that set. Warn at scan time
     when a command file's name collides with one — the file is inert
     and its author should hear about it.
   - **Command beats a skill, on asymmetric reachability.** If `/wh`
     resolves to the skill, the *command* becomes unreachable by
     anything: nothing else can invoke it, by design — that is the whole
     "costs zero prompt tokens" property. If `/wh` resolves to the
     command, the *skill* loses nothing: it stays in
     `<available_skills>`, the model can still load it with the `skill`
     tool on any turn, and a merged menu still lists it. One side of
     this fork drops a capability on the floor; the other drops nothing.

   Two riders that keep the scope honest:

   - **It is a precedence, not a shadow.** Unlike the catalog's
     skill-vs-skill case, the loser here is not dropped from anything —
     the skill is untouched and stays fully model-invocable, and only
     its typed-slash affordance is taken. The warning has to say that,
     or it reads as "your skill was discarded", which would be false.
   - **This governs *typed* resolution only.** A merged `/` menu (P4) is
     unaffected: a row already carries its own kind, so picking the
     skill row loads the skill no matter how many commands share its
     name. The collision exists in exactly the one place where all the
     human handed you is a string.

   Where the check lives: the host, necessarily — P1 keeps the two
   registries apart, so nothing in the library sees both. In a `bin/`
   script it is the existing `case` for the built-ins, then a command
   lookup, then the catalog. If a second host writes the same three-way
   resolution, it graduates into the `Pikuri::Slash::Menu` façade
   alongside P4's merge — same trigger, same home.
4. **Does a command body get the `<command>`-wrapper treatment?**
   ~~Unsettled.~~ **Settled 2026-08-16, by the `@path` decision.**
   `Renderer.format_skill` wraps a skill in `<skill name= location=>`
   with a sidecar-path preamble. A command lands as a *user* turn, where
   an XML wrapper reads oddly — the human "said" this. But without one,
   a body pointing at a sidecar file has no base directory to resolve
   against.

   **Prior art, measured 2026-08-16: Claude Code *does* wrap** — three
   tags, `<command-message>` / `<command-name>` / `<command-args>`, the
   last omitted when no arguments were typed. So the "an XML wrapper
   reads oddly in a user turn" half of the argument above is this note's
   aesthetic judgement and not a shared one; drop it as a reason. What
   survives the measurement is the decisive part: **that wrapper carries
   no location**, so it does not solve the base-directory problem that
   was the only *functional* argument for having one. A wrapper pikuri
   would have to extend anyway, to carry the one field the prior art
   omits, is a wrapper worth not having.

   That functional half was the only real argument for one, and
   dropping `@path` is what answers it: a sidecar reference stays
   literal text, the model resolves it by calling `read`, and `read`
   needs a base directory — which the one-line footer supplies. So: **no
   wrapper; a `(this command lives in <dir>)` footer.** Three pieces
   that only work together, and the third is the wiring already in the
   "What pikuri already has" table — `Registry#roots` into
   `Workspace::Filesystem`'s `readable:`, or the model resolves the path
   and is then denied the read.

   **The gate on that footer, corrected** (second review pass,
   2026-08-16). It read "appended only when the registry sees a sibling
   file next to the `.md`" — which gates nothing, because in a flat
   `commands/` directory *every command is a sibling of every other*.
   `~/.claude/commands/` holds exactly `wh.md` and `grill-me.md`, so the
   condition fires for both and the footer is unconditional in practice.
   The intent was **sidecar** siblings, so say that: append the footer
   only when the command's directory holds an entry the registry did
   *not* load as a command — a subdirectory, or a file that isn't one of
   the `.md`s it scanned. A directory of nothing but commands gets no
   footer, which is the common case and the one worth keeping quiet.
5. **Is the expansion trusted or untrusted text?** ~~Probably a
   downgrade we're comfortable with — the human typed `/wh`, which is
   consent in a way a model's `skill(name:)` is not.~~ **Proposed
   2026-08-16 — the old lean was backwards — and settled the same day,
   graded per source (see the end of this entry).** Untrusted, and it
   has to be *declared* — silence buys `:hard`, the same
   `TrifectaLegs.new(private: false, untrusted: :hard,
   egress_payload_review: :no_egress)` that `SkillTool` carries, arrived
   at independently and landing on the identical value.

   **This was never an aesthetic question — it is a detector blind
   spot.** `Pikuri::Trifecta` builds its tree from an agent's *tools*
   plus whatever its *extensions* contribute. A command is neither: P3
   established that it contributes no tool, no prompt snippet and no
   extension. So under P3 as written, a wired command surface lands in
   that tree **nowhere**. Wire skills and the untrusted leg lights;
   wire commands — same bytes, same `~/.claude` directory, frequently
   the same third-party author — and nothing lights at all. An agent
   that really holds all three legs reports two. That is precisely the
   *under-warn* failure `Pikuri::Trifecta`'s own header owns up to, and
   the one thing a smoke alarm may never do quietly.

   The three arguments, now that the axis is the right one:

   - **Provenance is identical.** `SkillTool` declares `:hard` "because
     a skill is a file someone else wrote". A command file is a file
     someone else wrote. Nothing about the *bytes* changed.
   - **Consent to invoke is not evidence of having read.** The note's
     old lean leaned on the human's keystroke. But typing `/deploy`
     means the human chose to *run* the bundle, not that they opened it
     — and the entire premise of scanning `.claude/commands` is that
     bundles **travel**, arriving with a cloned repo. Nor does the
     comparison favour commands: a skill's catalog was also assembled by
     a human at wiring time, and that human didn't read the bodies
     either. The distinction the lean rested on doesn't survive contact
     with what the `untrusted` axis actually measures.
   - **The `:user` role does not make it safer.** P2 is right that a
     command must land as `:user` — that's the mechanics
     (`on_user_message` fires, no Anthropic stickiness, no
     `EmptyTurnError`). But `:user` is the **most-trusted role in the
     conversation**, the one the model is trained to read as its
     principal speaking. The same injected sentence carries *more*
     authority in a command body than in a skill body, which arrives as
     reference text. The injection kind P2 chose for good reasons is
     what raises the taint; it cannot also be what excuses it.

   **The counter-argument, which is real and does not get zeroed out**
   (raised 2026-08-16, and it improves the note): *only a human can fire
   a command — the model cannot — so an injection cannot reach one.*
   True, and it is a genuine asymmetry with skills that the note had not
   articulated. A skill is **model-selected**: the catalog is in the
   prompt, so poisoned content already in context can steer the
   `skill(name:)` call and cause a load. That amplification loop —
   injection begets injection — is real for skills and **structurally
   absent for commands**. Nothing the model can emit pulls a command
   body into context.

   It does not follow that the bytes are trusted. The axis asks whether
   attacker-influenceable content entered the context, not who chose to
   load it. Human-only triggering removes the attacker-steered
   *trigger*; the *content* is still whatever the file's author wrote,
   and the whole reason to scan `.claude/commands` is that bundles
   arrive with a cloned repo. pikuri already refuses this inference one
   axis over: `:human_reviewed` is declarable only when "the payload
   *is* the reviewed artifact", because *"approving `curl` approves a
   program, and the bytes it sends are computed after the click."*
   Typing `/deploy` approves a program.

   What settles it is that the two errors don't cost the same. The
   trifecta never blocks — declaring `:hard` gates nothing, adds no
   confirmer, changes no injection kind; it lights one leg in a printed
   banner. Declaring `:none` and being wrong is a silent under-warn on
   an agent that genuinely holds all three. `TrifectaLegs`' own yardoc
   names over-warning as the declared bias, so the tie goes to `:hard`.

   **`:hard` is the default, not the answer — and the graded answer
   shipped for skills on 2026-08-16** as `Pikuri::Bundle::Base` (see
   `DECISIONS.md` `D-bundle-trust-grading`). A bundle the human wrote is
   trusted in fact; that entry owns what a base declares, the union over
   the skills a catalog actually stored, why a skill or command body is
   prose rather than an executable, and why the answer is a value the
   host passes rather than a reach into the workspace.

   Two consequences for *this* note, which is all that's needed here:

   - **Commands take the same channel**, per source rather than per
     harness — `Command::Registry` gets a `trusted:` per search base and
     unions it the way the catalog does. No private spelling of a fact
     skills already own; `:hard` remains what silence buys.
   - **A command file is prose, exactly as a skill body is.** So the
     provenance argument above needs no command-specific escape hatch:
     whatever makes project sources trustworthy makes the project's
     command files trustworthy, and neither claim reaches `~/.claude`.

   **Mechanism, and the narrow amendment to P3.** The hook already
   exists and is documented for this exact shape:
   `Agent::Extension#trifecta_contribution`, whose `Contribution` yardoc
   calls it *"legs no tool can declare"* — `Pikuri::Mcp::Extension` uses
   it for the analogous case (a foreign tool surface with no leg surface
   of its own). It defaults to `nil` on the protocol, so an extension may
   implement that method and nothing else.

   So commands do want an `Extension` after all — a **declaration-only**
   one, which P3 didn't foresee because it enumerated *configure*,
   *bind*, *tool* and *prompt snippet* and stopped one short. P3's actual
   payload is untouched: `Registry` and `Renderer` stay pure functions
   over disk, testable with zero agent integration, and there is still no
   scheduling function. What changes is that a host wiring commands adds
   a `Command::Extension` that registers nothing, renders nothing and
   binds nothing — it exists to light one leg, so the boot banner
   `bin/pikuri-code` already prints tells the truth. Making it an object
   rather than a host-supplied kwarg is the P1 principle again: the
   mistake should be unrepresentable, not something each host remembers.

   **What the mechanism actually costs, which the note had not priced**
   (found 2026-08-16, reading `Trifecta.build`). Every extension's legs
   are unioned into **one pseudo-tool row with a hardcoded label**:
   `tool_legs['(mcp)'] = extra unless extra == NONE`
   (`pikuri-core/lib/pikuri/trifecta.rb:80`). That is honest today only
   because `Mcp::Extension` is the sole legs-contributing extension in
   the tree — `SubAgent::Extension` returns children with
   `legs: NONE`. A `Command::Extension` is the **second**, so the boot
   banner would report the untrusted leg as `untrusted((mcp))` on an
   agent with no MCP server wired, and `Report#attribution`'s own yardoc
   is the indictment: *"Which tool contributed each leg, so the line
   names something the reader can actually go and change."* It would
   name something that isn't there — and it misfires in exactly the
   default case, since a fully-trusted registry contributes `NONE` and
   creates no row at all.

   So question 5 is really two decisions, and the second is a small
   `pikuri-core` change: **`Contribution` carries its own row label**
   (or `build` keys rows per contributing extension). Commands are
   merely the forcing function — the hardcoded string is a latent
   single-contributor shortcut, and any second contributor trips it.
   Worth doing with the declaration rather than after it: a banner that
   blames MCP for a command surface is a worse under-warn than the
   missing leg it was meant to fix, because it reads as informative.

   **Cheaper than the note implies, on the other side.** The grading
   channel needs no new human input: `bin/pikuri-code` already asks
   `repo_sources_are_mine` and feeds it to the catalog's project
   `Base`, so a `Command::Registry` taking the same `Base` records
   reuses that answer verbatim — one more argument at the wiring site,
   no third trust question. And the contribution computes itself from
   the registry exactly as MCP's does from `@registry.private?`,
   including the `return nil` when there is nothing to declare.

   ### The grading, settled — one base list, both surfaces

   Author's call, 2026-08-16: **command sources plus a trust flag on
   every source** — `Skill::Catalog::Bundled`'s algorithm applied
   verbatim. `search_bases:` takes `Base(dir:, trusted:)`, the union
   runs at scan time over what the registry actually *stored*, and
   `:hard` is what a base that says nothing buys. This closes question
   2's second axis too; the two were one decision wearing two numbers.

   **The payoff, which a flat `:hard` would have thrown away.**
   `bin/pikuri-code` vouches for the home base without asking anyone —
   `home_skills_are_mine = sandbox_enabled || confirm_enabled` — because
   skill roots ride in the workspace's `readable:` and never its
   `writable:`, so nothing but the user's own hand puts a file there.
   That argument transfers to `~/.claude/commands/` unchanged: same
   tree, same read-only wiring. So the graded registry answers `:none`
   over `wh.md` and the banner stays quiet about the user's own work,
   where a flat `:hard` would have lit a leg over it — the over-warn
   that gets a detector muted. Two conditions ride along, both already
   true of skills: command roots go into `readable:` only, and the vouch
   dies under `--yolo` / `--no-sandbox --no-confirm`, where bash can
   write that directory for real and the next session would load bytes
   the agent authored. Reuse that boolean rather than computing a second
   one — it wants renaming to `home_bundles_are_mine`.

   **The one place the mirror is not literal: a refused command must
   not taint.** The catalog unions at the point a skill *wins its name*,
   so an untrusted base costs nothing when its entries all lost a
   collision. Commands have a state skills lack — the refused record
   (`allowed-tools:`, `` !`…` ``), kept in `#list` so `/foo` can explain
   itself, never expandable. Its bytes cannot reach the context, so it
   does not taint. That is the catalog's own rule applied to a state the
   catalog doesn't have, not a divergence from it — but it is a line
   someone will otherwise write the obvious way.

   **The prerequisite — done 2026-08-16, ahead of any command code.**
   Both surfaces want the same record, and there were three ways to have
   it: duplicate it as `Command::Registry::Base`, and a host builds two
   parallel arrays out of the same two booleans with nothing keeping
   them in step; have `Command::Registry` accept `Skill::Catalog::Base`,
   which works — both surfaces live in `pikuri-skills`, so no dependency
   appears — but reads as a command being a kind of skill, the one thing
   P1 exists to deny; or relocate the record to a shared home. The third
   shipped: **`Pikuri::Bundle::Base`**, under `pikuri-skills`, in the
   home the frontmatter splitter P1 requires extracting will share. The
   vocabulary was already in the repo — the
   decision entry is `D-bundle-trust-grading`, not
   `D-skill-trust-grading`. Done now because the window was closing:
   `Skill::Catalog::Base` had never been tagged, so the move cost one
   edit to an existing `[Unreleased]` CHANGELOG line, where after the
   next release it would have cost a breaking entry plus a migration
   sentence for a cosmetic gain.

   **The rest mirrors straight across.** `Registry#untrusted_level`,
   with an empty registry answering `:none` the way `Catalog::Empty`
   does; `Command::Extension#trifecta_contribution` reads it and returns
   `nil` when it is `:none`, exactly as `Mcp::Extension` returns `nil`
   on an empty server registry. Plus one sentence of yardoc saying the
   flag changes what the report *says* and gates no expansion — the same
   non-promise the skill side makes.
6. **Should `argument_hint` be parsed or passed through?** Claude Code
   treats it as an opaque display string. Parsing it into required /
   optional slots would let the TUI validate before dispatch, and would
   let the library reject `/wh` with no args. Almost certainly not worth
   it — pass the string through, let the model handle a missing
   argument the way `wh.md` already does ("if no label was given, use
   'swingai'").
7. **Does substitution respect fenced blocks and code spans?** *(Opened
   on the second review pass, 2026-08-16.)* **Settled the same day: yes
   — rule C, both tokens, fenced blocks and inline spans alike.**

   The note settled fence-awareness once already, in the opposite
   direction: *"Be over-eager on detection, deliberately. Don't try to
   skip fenced code blocks."* That was decided for `` !`…` ``
   **detection**, and it is right there, because a false positive is a
   loud exception on a file the author can trivially edit. **For `$n`
   substitution the polarity inverts** — a false positive is not an
   exception, it is silent corruption of the prompt. Nothing in the note
   noticed that the same rule was being carried across a sign change.

   ### Worked, against the real file (2026-08-16)

   Two claims in an earlier draft of this question did not survive
   contact with actual invocations. Both are corrected below.

   **The corpus.** `wh.md` carries both tokens as *placeholders* and as
   *mentions*:

   ```
   line 12   Invoked as `/wh $ARGUMENTS`.
   line 14   (Read it off `$ARGUMENTS` rather than `$1` — positional expansion
             is off by one …, so `$1` yields the *second* word and is left as
             the literal text `$1` when only one argument was given.)
   line 22   ```bash
             monday=$(date -d "-$(( $(date +%u) - 1 )) days" +%Y-%m-%d)
   ```

   **Correction 1 — the out-of-range rule saves nothing here.** The
   draft claimed literal pass-through means "the single-argument
   `/wh swingai` leaves the prose alone by itself". False. That was true
   of Claude Code's *0-based* scheme, where `$1` needs two arguments to
   be in range. We chose **1-based** (finding 3), so `$1` is in range on
   every invocation carrying at least one argument. The rule protects
   `$2`…`$9` and **never `$1`** — which is precisely the one authors
   write in prose. `/wh swingai` renders line 14 as:

   > (Read it off `swingai` rather than `swingai` — positional expansion
   > is off by one …, so `swingai` yields the *second* word and is left
   > as the literal text `swingai` when only one argument was given.)

   Four hits, sentence destroyed, and it now asserts something false to
   the model — on the most common invocation of the only command file we
   have.

   **Correction 2 — the exposure is code *spans*, not fences, and
   `$ARGUMENTS` is not safe.** Note what the bash block does *not*
   contain: `$(`, `$((`, `$monday` — no `$1`…`$9` at all. A `$n`
   substituter never touches it. Meanwhile line 14 shows an author
   writing *about* commands backticking **both** tokens, which kills the
   draft's "`$ARGUMENTS` is distinctive, where it appears the author
   meant it". Sometimes they meant to talk about it.

   The fence risk is real but needs an ordinary *other* file — a command
   that emits a script, whose body holds a bash fence containing
   `deploy_to "$1" --tag "$2"`.

   `/mkdeploy staging v3` hardcodes the template to one invocation,
   silently. The author meant shell positionals.

   And the irreducibly ambiguous case, which no rule gets right:
   `` Run: `git log --author=$1` `` — same characters, same backticks,
   opposite intent.

   **The four rules on that corpus:**

   | | line 12 | line 14 | bash fence | `deploy_to "$1"` |
   |---|---|---|---|---|
   | A. blind | fine | **destroyed** | fine | **destroyed** |
   | B. `$n` fence-aware, `$ARGUMENTS` blind | fine | **still damaged** | fine | fixed |
   | C. both fence-aware | unchanged | **fixed** | fine | fixed |
   | D. blind + `$$` escape | fine | fixed *if edited* | fine | fixed *if edited* |

   **Settled: C — skip inline code spans and fenced blocks for both
   tokens.** The draft's asymmetric B is wrong, and line 14 is the
   counterexample sitting in the motivating file. D fails on the case
   that matters most — imported bundles nobody will edit, which is the
   whole reason to scan someone else's directory.

   The residual cost of C is the ambiguous case above: a fenced `$1` the
   author *did* mean stays literal. That failure is visible in the
   transcript and an author can fix it by unbackticking. A's failure is
   silent corruption of an instruction, which is the asymmetry this
   whole question turns on.

   Note that fence-**aware** substitution and fence-**blind** `!`
   detection can coexist without contradiction — they answer different
   questions about the same characters, and that difference is the
   point, not an inconsistency. Whoever builds this should write the
   sentence into the yardoc, or the next reader will "fix" one of them
   to match the other.

   ### What C costs the motivating file — found while settling it

   Every `$ARGUMENTS` in `wh.md` is backticked: lines 12, 14 and 16, and
   there are no others. So under C the file that motivated this note has
   **zero substitutable placeholders**, and `/wh swingai` delivers its
   argument only if the *append* fires.

   Which makes the append gate part of this decision rather than a
   neighbouring rule: **"the body references neither placeholder" must
   be evaluated with the same span- and fence-awareness as
   substitution.** Read it blind and `wh.md` counts as referencing
   `$ARGUMENTS`, so nothing is appended; substitute under C and nothing
   is interpolated either — and the word the human typed is gone, with
   no error, on the most common invocation of the only command file we
   have. Two rules that are individually defensible and jointly a
   data-loss bug. Write them as one function over one tokenization of
   the body, not two passes that can disagree.

   With the gate span-aware, `wh.md` lands as its own prose plus a
   trailing `ARGUMENTS: swingai` — line 14's warning about `$1` survives
   intact, and the label arrives in the block. Right outcome, reached by
   the two halves agreeing rather than by either alone.

   It also moves the irreducibly ambiguous case from hypothetical to
   line 12. ``Invoked as `/wh $ARGUMENTS`.`` is a placeholder the author
   *did* mean — Claude Code renders it ``Invoked as `/wh swingai`.`` —
   sitting two lines above a mention they did not. Same file, same
   backticks, opposite intent, which is the residual cost priced in
   above: C leaves line 12 literal, and the append is what keeps that
   harmless. So the table's "unchanged" for that cell is accurate but
   reads better as *un-substituted, and carried by the append instead*.


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
- **`DECISIONS.md`** gets the real forks, which are P1–P3 plus questions
  3 and 7: one catalog vs. two registries; `:user` vs. `:system` injection;
  **fence- and span-aware substitution** (roads not taken: substitute
  blindly as Claude Code does, or ask authors for a `$$` escape — both
  rejected on imported bundles nobody will edit; and the rider that the
  append gate reads the body the same way, which is what keeps the
  motivating file from losing its argument);
  the **host built-in > command > skill** precedence (roads not taken:
  skill wins, or raise on collision — the latter rejected because
  `Catalog::Bundled` already answers the same question with a warning,
  and two collision policies in one codebase is worse than either); and
  the two dropped inlining legs — `` !`cmd` `` and `@path` — with their
  threat-model reasoning, including why they get *different* handlings
  (a raise vs. a literal pass-through) from the same "the file is
  untrusted" premise. That last entry graduates **whether or not this
  feature is built** — it is the one a future reader is most likely to
  need, since "just add bash preexecution, Claude Code has it" is the
  obvious recurring temptation, and the answer (`allowed-tools:` in the
  untrusted file is not a gate) is not reconstructible from code that
  never grew the feature. It should also carry the
  refuse-on-commands / fail-open-on-skills asymmetry for
  `allowed-tools:`, which is a genuine fork with a real road not taken
  (refuse on both, and break shipped catalogs over a spec-sanctioned
  field). These
  are separate from the skill notes' shared advertise-and-when entry —
  different axis (*which surface a bundle belongs on*, not *what the
  catalog advertises*), so separate entries that **cite each other**.
  The crossing point is that note's question 6, and the sentence worth
  carrying across is the one the measurement produced: a skill whose
  description tells the model to ignore it is a bundle filed on the
  wrong surface.
- **Question 5 needs no entry of its own** — it is an *adoption* of
  `D-bundle-trust-grading`, so that entry gains a sentence saying the
  channel serves both bundle surfaces, and the `Base` record moves to a
  shared home under the name the entry already uses. Two riders belong
  there rather than here, because they are facts about the grading and
  not about commands: a *refused* command never taints (its bytes cannot
  reach the context), and the home-base vouch covers `commands/` for the
  same reason it covers `skills/` — read-only roots, void under `--yolo`.
  Do the relocation **before the next release**, while it is still a
  CHANGELOG edit rather than a breaking change.
- **Rejected** → a one-line why-not in `Pikuri::Skill::Catalog`'s
  yardoc, since "why doesn't pikuri see my `.claude/commands`?" is the
  question that lands there.
