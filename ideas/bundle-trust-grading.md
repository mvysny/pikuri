# Bundle trust grading — let a catalog say its skills are user-authored

Status: **proposal, unbuilt.** Split out 2026-08-16 from
[`slash-commands.md`](slash-commands.md) question 5, which needed this
and correctly refused to invent a private answer for commands to a
question skills already answer pessimistically.

**One line:** `SkillTool` declares `untrusted: :hard` unconditionally
because `Catalog::Bundled` has no way to be told otherwise. Give it one.


## The gap is already documented — in the shipped code

`SkillTool`'s own comment states the problem and stops one step short of
the fix:

> Hard untrusted, no egress. […] **The host may well trust its own
> catalogue, but the tool cannot tell a hand-written skill from a
> downloaded `.agents/` bundle.**

So the pessimism is not a belief that skills are hostile. It is the
absence of a signal, correctly defaulted. Meanwhile the *concept* exists
one gem over, in `Workspace::Filesystem#trusted?`:

> Whether every byte reachable here is user-authored — the opt-out from
> the file tools' default `:hard` untrusted leg. Default `false`,
> because broad disk access means cloned dependencies, fetched PR
> branches, saved downloads and package caches.

Two surfaces, one question, and only one of them can be answered.
Today that means a workspace declared `trusted: true` reports `:none`
for `read` and `:hard` for `skill` — **on bytes that may be the same
file**, since `.pikuri/skills/` lives under the project root.


## This is a warn-less change, and that is the security argument

Worth being explicit, because "port the security mechanism" could be
misread as adding a defense. It adds none. The trifecta never blocks;
this only changes what a boot banner prints, and it changes it in the
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

A **declared, per-search-base** trust flag, consumed by `Catalog` and
(when it exists) `Command::Registry`, defaulting `false`.

Per source, because the bases differ in kind:

- **Project base** — should inherit the host's `Filesystem#trusted?`.
  Same bytes `read` would return, from the same root, with the fact
  already declared once. Declaring them differently is incoherent.
- **Home base** — a separate declaration, also defaulting `false`.
  `~/.claude/skills` and `~/.claude/commands` are *not* automatically
  user-authored: marketplace plugins, cloned collections and pasted
  files land there routinely. Like `trusted:` and `private:`, the
  framework cannot verify it, so silence buys the pessimistic value.

### The gem boundary forces the shape

`pikuri-skills.gemspec` depends on **`pikuri-core` only** — not
`pikuri-workspace`. So `Catalog::Bundled` cannot ask a `Filesystem`
anything, and the "inherit `fs.trusted?`" rule must be **the host
bridging two objects it already holds**, not a dependency:

```ruby
catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [
  Pikuri::Skill::Catalog::Base.new(project_root, trusted: filesystem.trusted?),
  Pikuri::Skill::Catalog::Base.new(Dir.home,     trusted: true)
])
```

A bare path should keep working and mean `trusted: false`, so every
existing call site stays correct without an edit and the unsafe value is
the one you get by saying nothing.

Then one reader on the catalog — `#untrusted_level` returning `:none` or
`:hard`, the union over the skills actually loaded — and `SkillTool`
consumes that instead of the literal. `Catalog::Empty` returns `:none`.

### Two properties to write into the yardoc

- **The "entire reachable set" rider is satisfiable here, unlike for
  `read`.** `Filesystem#trusted?` warns: *"claim it only when the
  trusted area is the tool's entire reachable set — a vouched-for island
  inside a broad root buys nothing."* `read` reaches the whole project
  root, so its trust is all-or-nothing. A catalog's reachable set **is**
  the enumerable list of files it loaded at scan time, so per-source
  grading is honest on this surface and would not be on that one. This
  is the load-bearing difference and the reason the feature is sound.
- **It is a boot-time union.** One untrusted-base skill takes the whole
  catalog to `:hard`, however many trusted ones sit beside it —
  consistent with `TrifectaLegs#|` everywhere else. Say it, so it does
  not read as a bug.

Precedent that a derived (not merely declared) leg is normal:
`Code::Bash` already composes trust with the sandbox —
`bash(sandbox: none, trusted: true)` is `:hard`, `bash(sandbox:
confined, trusted: true)` is `:none` (`bash/trifecta_legs_spec.rb`).


## Open questions

1. **Does a skill's *sidecar* inherit the skill's trust?** Sidecars are
   read through the ordinary `read` tool, so they are already accounted
   under the workspace's own leg. Probably nothing to do — but the
   catalog wires `roots` into `Filesystem#readable:`, which *adds* those
   roots to what `read` reaches. If a home-base skill dir is appended to
   a trusted project workspace's readable set, `read`'s "entire
   reachable set" claim quietly stops holding. **Latent, not live**: no
   `bin/` declares `trusted:` today, so `read` is `:hard` everywhere and
   nothing is currently wrong. It goes live the moment someone declares
   a trusted repo *and* wires `catalog.roots` into `readable:` — which
   `bin/pikuri-code:206` already does. So this note's feature is what
   makes the latent bug reachable; fix the two together.
2. **Is `trusted:` per base, or per subdir?** A base crosses
   `.pikuri/skills`, `.claude/skills`, `.agents/skills`. The `.agents/`
   one is the cross-harness convention — the *most* likely to hold a
   foreign bundle. Per-base is simpler; per-subdir is more honest.
   Lean: per base, and let someone who splits them ask for it.
3. **Should `trusted:` be declarable at all on a base the host did not
   author?** There is no way to enforce this. Same posture as
   `private:` — it is a declaration, and the yardoc says so plainly.
4. **Does anything actually turn this on?** No `bin/` sets
   `trusted:` today; the flag is tested but unexercised in the demos. So
   this ships as a channel nobody uses until a `bin/` declares a trusted
   repo — the same "second unconsumed API" caveat `slash-commands.md`
   raises about itself. Cheapest proof: `bin/pikuri-code` already
   computes a `trusted_repo` boolean for its git confirmations; whether
   *that* is the same question is question 1's territory and needs
   deciding, not assuming.


## Relation to `slash-commands.md`

That note's question 5 lands on `untrusted: :hard` for commands, via a
declaration-only `Command::Extension`, and explicitly defers grading to
here. If commands ship first they ship at `:hard` and adopt this channel
when it lands — no private spelling of the same fact.


## Graduation plan

- **Built** → `Catalog` / `Catalog::Base` / `SkillTool` yardoc owns the
  per-symbol truth (what `trusted:` claims, the union rule, the
  reachable-set rider). One `CHANGELOG` sentence; **breaking only if**
  the bare-path form stops working, which it should not.
- **`DECISIONS.md`** gets the fork: *declared per-base trust* vs. the
  two roads not taken — keep the unconditional `:hard` (rejected: it
  over-warns exactly the operator who did the work to deserve a quiet
  banner, and an ignored smoke alarm is the failure mode the module's
  own header names), and *derive* trust by having the catalog inspect a
  `Filesystem` (rejected: `pikuri-skills` depends on `pikuri-core` only,
  and reaching for `pikuri-workspace` to answer a question the host can
  answer in one kwarg inverts the dependency for nothing).
- **Rejected** → a one-line why-not in `SkillTool`'s existing comment,
  which is already where a reader meets the question.
