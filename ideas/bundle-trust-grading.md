# Bundle trust grading — let a catalog say its skills are user-authored

Status: **proposal, unbuilt.** Split out 2026-08-16 from
[`slash-commands.md`](slash-commands.md) question 5, which needed this
and correctly refused to invent a private answer for commands to a
question skills already answer pessimistically. Rewritten the same day
once the project half turned out to need no decision at all.

**One line:** `SkillTool` declares `untrusted: :hard` unconditionally
because `Catalog::Bundled` has no way to be told otherwise. Give it one
— and for the project root, the host has already said it.


## A skill is prose, so it is a source file

This is the whole argument, and it collapses most of what an earlier
draft treated as open.

`Filesystem#trusted?` already splits the axis that matters, in its own
yardoc:

> Distinct from the trust-this-directory question a host may ask at
> boot: that one asks whether a hostile `.gitattributes` can *execute
> code*, this one whether the repo's *bytes* are attacker-authored.

A git hook, a `diff.external` driver, a repo-local `core.fsmonitor` —
those *run*. A `SKILL.md` body does not. It is Markdown rendered into
the model's context, exactly like a README the model `read`. Same bytes,
same channel, same injection surface, no added privilege. So `skill` and
`read` over one project root are **the same question**, and today they
give different answers:

> Hard untrusted, no egress. […] The host may well trust its own
> catalogue, but the tool cannot tell a hand-written skill from a
> downloaded `.agents/` bundle.

That is `SkillTool`'s own comment naming the gap. A workspace declared
`trusted: true` reports `:none` for `read` and `:hard` for `skill` — on
bytes that may be the same file, since `.pikuri/skills/` lives under the
project root.

Two things that could have broken the equivalence, and neither does:

- **Skills may ship executable sidecars.** A sidecar runs only when the
  model invokes it through bash, gated by the sandbox and the confirmer.
  That is the executes-code axis, already handled by other machinery.
- **`.agents/skills` is the cross-harness travel convention**, so it is
  the likeliest home for a vendored foreign bundle. True — and so are
  `vendor/`, `node_modules/` and a submodule, for sources. That is not
  "skills differ from sources", it is the flag's existing rider: don't
  claim `trusted:` over a root holding other people's bytes.


## This is a warn-less change, and that is the security argument

Worth being explicit, because "port the security mechanism" could be
misread as adding a defense. It adds none. `untrusted` is consumed by
`Trifecta::Report` and nothing else; the trifecta never blocks. This
only changes what a boot banner prints, and it changes it in the
*quieter* direction.

The argument for doing it anyway is in `Pikuri::Trifecta`'s own header —
a false alarm is the failure mode that gets the whole advisory muted:

> crediting the parent with them reports the sub-agent quarantine as
> broken, which is **the one false alarm guaranteed to get this advisory
> muted**

An agent that is genuinely two-legged but prints three legs teaches its
operator that the map is wrong. That is the cost being paid today by
anyone whose skills really are their own.


## What to build

A per-search-base trust value, consumed by `Catalog` and (when it
exists) `Command::Registry`. **Only one of the two bases is a
decision.**

- **Project base — inherits `Filesystem#trusted?`. Not a declaration, a
  copy.** Same bytes `read` returns, from the same root, with the fact
  already declared once. There is nothing here for a host to think
  about; a host that thinks about it separately can only get it wrong.
- **Home base — a declaration, defaulting `false`.** `~/.claude/skills`
  is *not* automatically user-authored: marketplace plugins, cloned
  collections and pasted files land there routinely, and it sits outside
  `project_root`, so `filesystem.trusted?` never made a claim about it.
  Like `trusted:` and `private:`, the framework cannot verify it, so
  silence buys the pessimistic value.

### The gem boundary forces the shape

`pikuri-skills.gemspec` depends on **`pikuri-core` only** — not
`pikuri-workspace`. So `Catalog::Bundled` cannot ask a `Filesystem`
anything, and the inheritance must be **the host bridging two objects it
already holds**, not a dependency:

```ruby
catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [
  Pikuri::Skill::Catalog::Base.new(project_root, trusted: filesystem.trusted?),
  Pikuri::Skill::Catalog::Base.new(Dir.home,     trusted: home_skills_are_mine)
])
```

The catalog cannot tell which base is "the project" one, so the shape
stays symmetric even though the semantics aren't: the first line is a
copy, the second is a judgment.

A bare path keeps working and means `trusted: false`, so every existing
call site stays correct without an edit and the unsafe value is the one
you get by saying nothing. That needs a real coercion step, not duck
typing — `catalog.rb:116` currently does `File.join(base.to_s, sub)`,
and a `Data.define` `Base` would `to_s` into `#<data …>`.

Then one reader — `#untrusted_level`, returning `:none` or `:hard` — and
`SkillTool` consumes it instead of the literal. The abstract `Catalog`
defaults it to `:hard` (hosts subclass `Catalog` directly, and silence
buys the pessimistic value there too); `Catalog::Empty` returns `:none`.

### Two properties to write into the yardoc

- **It is a boot-time union over the skills actually *stored*.** One
  untrusted-base skill takes the whole catalog to `:hard`, however many
  trusted ones sit beside it — consistent with `TrifectaLegs#|`
  everywhere else. Say it, so it does not read as a bug. Union at the
  point a skill wins its name, not at scan: a skill *shadowed* by an
  earlier base is never loaded and must not count.
- **The "entire reachable set" rider is what earns the home base its
  grading.** `Filesystem#trusted?` warns: *"claim it only when the
  trusted area is the tool's entire reachable set — a vouched-for island
  inside a broad root buys nothing."* This is the argument for the
  *home* half specifically — home skills are the only bytes the catalog
  reaches that `read`'s root does not govern, and a catalog's reachable
  set is the enumerable list of files it loaded at scan time, so grading
  them separately is honest. The project half needs no such argument; it
  is just `read`'s answer, repeated.

Precedent that a derived (not merely declared) leg is normal:
`Code::Bash` already composes trust with the sandbox —
`bash(sandbox: none, trusted: true)` is `:hard`, `bash(sandbox:
confined, trusted: true)` is `:none` (`bash/trifecta_legs_spec.rb`).


## The one open question

**Does wiring home-base skill roots into `readable:` break `read`'s
trust claim?** `Catalog#roots` is documented for exactly that, and
`pikuri-code/bin/pikuri-code:206` does it. Appending `~/.claude/skills`
to a *trusted* project workspace's readable set means `read` now reaches
bytes outside the root whose trust was declared — the vouched-for-island
problem, arriving through the back door. `filesystem.rb:392` already
raises on `AllowAll` + `trusted:` for the same reason; a `readable:`
root outside `project_root` combined with `trusted: true` is the same
incoherence in miniature and probably deserves the same treatment.

**Latent today, and independent of this note.** It goes live the moment
any `bin/` declares `Filesystem(trusted: true)`, which needs nothing
from here — no `bin/` does today, so `read` is `:hard` everywhere and
nothing is currently wrong. What this note adds is the *motive* to
declare it. Fix the two together.

### Settled, for the record

- **Per base, not per subdir.** Grading `.pikuri/skills` apart from
  `.agents/skills` under one project root is not merely more work, it is
  unrepresentable: `trusted?` is all-or-nothing over that root, so
  splitting them recreates the same-bytes asymmetry this note exists to
  remove. The `.agents/` worry is an argument about the home base.
- **`trusted:` is a declaration nobody can enforce.** Same posture as
  `private:`; the yardoc says so plainly.
- **`bin/pikuri-code`'s `trusted_repo` is not this flag.** It is the
  answer to a prompt about whether a hostile `.gitattributes` can
  *execute code* — the other axis, by the yardoc's own words. Reusing it
  would claim `vendor/` is user-authored on the strength of the user
  controlling `.git/config`. A host that wants a trusted workspace asks
  its own question.
- **Nothing turns this on yet.** No `bin/` sets `trusted:`; this ships
  as a channel nobody uses until one declares a trusted repo — the same
  "second unconsumed API" caveat `slash-commands.md` raises about
  itself. Note also that the leg only *changes* a banner in a wiring
  where nothing else contributes an untrusted leg, which in practice
  means the same wiring that declared `trusted: true`.


## Relation to `slash-commands.md`

That note's question 5 lands on `untrusted: :hard` for commands, via a
declaration-only `Command::Extension`, and explicitly defers grading to
here. If commands ship first they ship at `:hard` and adopt this channel
when it lands — no private spelling of the same fact.

Its "Accepted refinement" block used to restate the whole per-source
rule; trimmed to a pointer here (2026-08-16), because it had already
drifted — it framed the project base as a rule to be declared rather
than a value to be copied, and leaned on the reachable-set rider for
both halves. What stayed there is the half that is genuinely about
commands: they ship at `:hard` if they ship first, and a command file is
prose on the same terms a skill body is.


## Graduation plan

- **Built** → `Catalog` / `Catalog::Base` / `SkillTool` yardoc owns the
  per-symbol truth (what `trusted:` claims, the union rule, the
  project-inherits-`read` rule and why the rider only concerns home).
  One `CHANGELOG` sentence; **breaking only if** the bare-path form
  stops working, which it should not.
- **`DECISIONS.md`** gets the fork: *declared per-base trust* vs. three
  roads not taken — keep the unconditional `:hard` (rejected: it
  over-warns exactly the operator who did the work to deserve a quiet
  banner, and an ignored smoke alarm is the failure mode the module's
  own header names); *derive* trust by having the catalog inspect a
  `Filesystem` (rejected: `pikuri-skills` depends on `pikuri-core` only,
  and reaching for `pikuri-workspace` to answer a question the host can
  answer in one kwarg inverts the dependency for nothing); and a single
  catalog-wide flag instead of per-base (rejected: the common wiring is
  a trusted project plus an unvouched `~/.claude/skills`, and one flag
  forces that case to `:hard`, which is the whole benefit gone).
- **Rejected** → a one-line why-not in `SkillTool`'s existing comment,
  which is already where a reader meets the question.
