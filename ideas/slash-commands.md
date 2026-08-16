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
`wh.md`'s `$1` has never worked. **Nothing open now blocks
implementation** — questions 3, 5 and 6 are a host's call, a sentence of
yardoc, and a settled lean.

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
  **zero prompt tokens**, so none of it applies. Its **question 6 is
  this note's second motive** — see below; read that question and this
  note together, they answer each other.
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

This note started as "pikuri can't see my commands dir". The sister
note's catalog measurement (2026-08-16) supplies an independent second
reason, and it's the stronger one.

Two of the 12 skills measured — `wh` and `grill-me` — were
slash-commands filed as skills. `wh` even carried `argument-hint:`, a
command frontmatter key. Their descriptions were resident tokens spent
**telling the model to ignore them**, on every turn, forever (`wh`'s
read *"Only invoked manually."*). That note reaches for a
`disable-model-invocation:` frontmatter key to withhold them. The real
answer is that they aren't skills: a bundle the human invokes belongs on
the human-invoked surface, where it costs nothing resident because it
was never advertised in the first place.

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
- **Namespacing.** Three lines, and a flat scanner would *silently miss*
  namespaced commands rather than degrade — worse than not supporting
  them.
- **`$ARGUMENTS` / `$n`.** Trivial, and the only interpolation that
  can't be replaced by prose. Two riders from the 2026-08-16
  measurement: append `ARGUMENTS: <raw>` — that exact spelling — when
  the body references neither, and implement `$n` **1-based**, blanking
  an out-of-range index. Claude Code 2.1.233 is 0-based there and leaves
  an out-of-range `$n` as literal text; that is its bug, and the one
  place this note knowingly diverges from observed behaviour. Reasoning
  and the probe transcript live in *Unreferenced arguments* below.
- **Lenient validation**, matching the catalog on unknown keys — ignored.
  **But not its hard failure** (revised 2026-08-16): `Catalog::Bundled`
  drops a skill with no `description` because for a *skill* the
  description **is** the activation surface — the model never sees the
  body, so a description-less skill is unusable by construction. A
  command has no activation surface: the human types `/wh` by name, and
  the description is chrome for the popup. Inheriting the hard failure
  would make an imported command *silently absent from the menu* for a
  reason that stopped applying at the surface boundary. So: warn, fall
  back to the name as its own display string, and load it. That leaves
  the registry with **no hard failure at all** except the two refusals
  below — which is the right shape, since a command that parses is a
  command the human can invoke.

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
  documented `allowed-tools`.
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
- Later, if a host wants to grey the entry out rather than let the
  invoke raise, that's a predicate on the record (`#refused?` plus a
  reason), not a change to this behaviour.

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
   writes it**, and blank an out-of-range `$n` rather than leaking the
   placeholder. This is the one place to knowingly diverge from observed
   Claude Code behaviour: matching the bug would mean matching it
   forever, and nobody authored *against* it — the shape it produces is
   a body that silently reads the wrong word, which an author is far
   likelier to have papered over than noticed.
4. **`wh.md`'s fix does not actually work** — the file that motivated
   this note, checked as a consequence of finding 3. `/wh swingai` is a
   single-argument invocation, so its `$1` is out of range: the label
   never lands in the placeholder, the literal `$1` survives into the
   prompt, and the command works only because the body says *"If that is
   empty, use 'swingai'"* and 'swingai' is also the intended default.
   The `$ARGUMENTS` mention on its own line is what actually conveys the
   label today.

   So the paragraph above — "no *known* command depends on the append
   behaviour" — holds for the wrong reason: `wh.md` doesn't depend on the
   append because it references `$ARGUMENTS`, not because its `$1` works.
   Under pikuri's 1-based rule the file behaves as its author intended,
   with no edit. That is a small piece of evidence for finding 3's
   divergence: the *fix* for the bug is what makes the existing bundle
   correct.


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
3. **Name collision between a command and a skill.** `/wh` when both
   exist. Options: commands win in the slash namespace (they're the
   human-invoked one) with a warning; or the menu shows both with
   distinct affordances. Only bites once there's a merged menu (P4), so
   it can be decided by the host that first hits it.
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
   wrapper; a `(this command lives in <dir>)` footer, appended only when
   the registry sees a sibling file** next to the `.md`. Three pieces
   that only work together, and the third is the wiring already in the
   "What pikuri already has" table — `Registry#roots` into
   `Workspace::Filesystem`'s `readable:`, or the model resolves the path
   and is then denied the read.
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
  vs. two registries; `:user` vs. `:system` injection; and the two
  dropped inlining legs — `` !`cmd` `` and `@path` — with their
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
- **Rejected** → a one-line why-not in `Pikuri::Skill::Catalog`'s
  yardoc, since "why doesn't pikuri see my `.claude/commands`?" is the
  question that lands there.
