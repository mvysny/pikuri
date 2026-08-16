# Bundle trust grading — let a catalog say its skills are user-authored

Status: **proposal, unbuilt.** Split out 2026-08-16 from
[`slash-commands.md`](slash-commands.md) question 5, which needed this
and correctly refused to invent a private answer for commands to a
question skills already answer pessimistically. Rewritten the same day
once the project half turned out to need no decision at all; revised
again after a review pass found a construction-order problem in the
proposed wiring and a self-defeating rejection in the graduation plan;
and once more when the host question was settled (a prompt, not a flag)
and `pikuri-code`'s permanent dependency-cache `readable:` turned out to
decide what that prompt can feed.

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
project root. (That is a workspace whose roots *are* the project root.
`bin/pikuri-code`'s are not, and the difference turns out to decide who
can honestly ask the question — see "Who asks".)

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

- **Project base — the same *fact* the host already needs for
  `Filesystem(trusted:)`, asked once.** Same bytes `read` returns, from
  the same root. Where the workspace's roots *are* the project root it
  is literally the same boolean — not a declaration, a copy. Where they
  are not (`pikuri-code`, whose `readable:` carries dependency caches
  forever) the workspace needs that fact *conjoined* with the others,
  and the catalog needs it alone; see "Who asks". **Carve-out:** in a
  wiring with skills but no file tools (a Q&A agent with a catalog and
  web tools) there is no workspace at all, so the fact is asked purely
  for the catalog.
- **Home base — a declaration, defaulting `false`.** `~/.claude/skills`
  is *not* automatically user-authored: marketplace plugins, cloned
  collections and pasted files land there routinely. Like `trusted:` and
  `private:`, the framework cannot verify it, so silence buys the
  pessimistic value. **This half is not yet independent of the open
  question below** — today a host folds the home base into the
  workspace's `readable:` list, and `trusted?` is declared over the
  *whole* reachable set, not over `project_root`. So a `trusted: true`
  filesystem in the current `bin/pikuri-code` shape already claims those
  bytes. Grading the home base separately only becomes honest once that
  is settled; see "The one open question".

### The gem boundary forces the shape

`pikuri-skills.gemspec` depends on **`pikuri-core` only** — not
`pikuri-workspace`. So `Catalog::Bundled` cannot ask a `Filesystem`
anything, and the copy must be **the host passing a value it already
holds**, not a dependency.

The obvious spelling — `trusted: filesystem.trusted?` — does not
compile in the one real wiring, and the reason improves the design.
`bin/pikuri-code` builds the catalog **before** the filesystem, because
the filesystem needs the catalog: `skill_catalog` at `:121`,
`readable: … + skill_catalog.roots` at `:206`. There is no `filesystem`
to ask yet.

There does not need to be. The host holds the *fact* — "this repo's
sources are mine" — before it builds either object, so it asks once and
spends the answer where each object needs it. The catalog takes it per
base, as `Catalog::Base = Data.define(:dir, :trusted)` (`dir` a `String`
or `Pathname`):

```ruby
repo_bytes_mine = ...   # asked once, before either object exists

skill_catalog = Pikuri::Skill::Catalog::Bundled.new(search_bases: [
  Pikuri::Skill::Catalog::Base.new(project_root, trusted: repo_bytes_mine),
  Pikuri::Skill::Catalog::Base.new(Dir.home,     trusted: home_skills_are_mine)
])

filesystem = Pikuri::Workspace::Filesystem.new(
  project_root: project_root,
  readable:     … + skill_catalog.roots,
  # permanently false in pikuri-code — see "Who asks"
  trusted:      repo_bytes_mine && every_other_readable_root_is_mine,
  private:      private_repo
)
```

**One fact, two consumers with different reachable sets — and that
conjunction is not decoration.** `Filesystem#trusted?` is a claim about
*everything the file tools can reach*; the catalog's project base is a
claim about one root. Where a workspace's roots are the project root
alone the conjunction collapses and the two are literally the same
boolean, which is the "not a declaration, a copy" case. Where they are
not — `bin/pikuri-code` — they diverge permanently, and "Who asks"
below is that story.

The precedent for asking is three lines up: `private_repo`
(`pikuri-code:139`) is one prompt whose answer is spent on
`Filesystem(private:)`. The gem boundary that looked like a constraint
forcing an awkward bridge turns out to enforce the better shape:
`pikuri-skills` never sees a `Filesystem`, and need not know a workspace
exists at all.

One ordering constraint on the host: the answer must be *in hand before
the catalog is built*. `private_repo` is prompted at `:139`, after the
catalog at `:121`. Cheapest fix is to move the catalog *down* rather
than the prompt up — build it after both repo-fact prompts, since only
`readable:` at `:206` needs `skill_catalog.roots`. That also groups the
two "what is this repo?" questions, leaving the git-config prompt at
`:240` beside the passive detector it feeds.

**`--yolo` needs no special handling**, provided the prompt is gated
`confirm_enabled && $stdin.tty?` the way `trusted_repo` (`:241`) is —
yolo clears `confirm_enabled`, so the answer is `false` and
`Filesystem::AllowAll`'s raise on `trusted:` (`filesystem.rb:392`) is
never reached. Note the gate differs from `private_repo`'s deliberately:
that one is TTY-only *because skipping it fails silent*, and this one
fails loud, so the cheaper gate is the correct one.

A bare path in `search_bases:` keeps working and means `trusted: false`,
so every existing call site stays correct without an edit and the unsafe
value is the one you get by saying nothing. That needs a real coercion
step, not duck typing — `catalog.rb:116` currently does
`File.join(base.to_s, sub)`, and a `Data` `Base` would `to_s` into
`#<data …>`.

Then one reader — `#untrusted_level`, returning `:none` or `:hard` — and
`SkillTool` consumes it instead of the literal. The abstract `Catalog`
defaults it to `:hard` (hosts subclass `Catalog` directly, and silence
buys the pessimistic value there too). `Catalog::Empty` returns `:none`,
which nothing reaches by the normal path — `Extension#configure` no-ops
on an empty catalog and raises on a pre-registered `SkillTool` — so
either say it is for a hand-constructed `SkillTool` or leave `Empty`
inheriting the base default and skip the override.

**The union needs a carrier, and it should not be the `Skill` record.**
"Union at the point a skill wins its name" means `scan_root` must know
its base's trust and the answer must survive shadowing. Adding a field
to the `Catalog::Skill` `Data.define` changes a public shape
(`deconstruct`, positional construction) for a fact no consumer of a
skill wants; fold a boolean during the scan instead, next to `@skills`.

### Who asks, and what the answer can feed

**The resolution in one line: ask the question, keep the *workspace*
untrusted, mark the *skills from that repo* trusted.** It reads like a
fudge and is the opposite — the two objects reach different bytes, and
each answers about its own. `read` can reach `~/.cargo/registry`, so
`:hard` is its honest answer whatever the user says about their repo;
the catalog reached `.pikuri/skills/` under the project root and nothing
else, so `:none` is its honest answer once the user vouches for that
root. A single "is this repo trusted?" boolean spread across both
objects is what would be dishonest.

**A question, not a flag** (author's call, 2026-08-16). The counter-case
is on the record and was overruled: forgetting `--trusted` fails *loud*
(an over-warn, the declared bias), so a flag's absence is safe, and
`private_repo`'s own comment justifies prompting precisely because
*that* one fails silent. What decides it instead is that `bin/` scripts
are illustrative: a flag nobody types is an axis nobody meets, and a
demo that never exercises its own grading channel teaches nothing. Three
y/n questions is still a script you can read end-to-end.

So `bin/pikuri-code` grows a **third** prompt, and the three are
genuinely three:

- `private_repo` (`:139`) — would you mind these bytes leaking?
- **new** — are this repo's sources *yours*? (no vendored deps, no
  fetched PR branch, no `node_modules` you didn't write)
- `trusted_repo` (`:240`) — do you control this repo's *git config*?
  The executes-code axis, and by the yardoc's own words not this one.

**Why the answer can only reach the catalog, never `pikuri-code`'s
`Filesystem`.** `ToolchainPaths.readable` permanently folds
`~/.m2/repository`, `~/.cargo/registry`, `~/.npm`, `go/pkg/mod` and the
rest into `readable:` — downloaded third-party bytes, by definition. So
the conjunction above is *permanently false* there and
`Filesystem(trusted: true)` is never honest in that binary. That is not
a bug to fix: `read` really can reach `~/.cargo`, so its `:hard` is
correct, and the catalog really cannot, so its `:none` is correct too.
The founding equivalence of this note — same bytes, same question —
holds per *reachable set*, not per repo.

**What moves, then, and what does not.** The node verdict does not:
`read` and `bash` keep contributing `:hard`, so `pikuri-code` stays
`[TRIFECTA: HARD]`. What moves is the map and the attribution, which is
where this note's argument actually lives — `Report#render_lines` prints
per-tool tags, so `skill [:untrusted_hard]` becomes `skill []`, and
`#advisory` stops naming `skill` in its `untrusted(read, bash, skill)`
list. An operator reading that map to decide whether it is right stops
seeing a leg the tool does not hold. Node-level quiet has to wait for a
host whose readable set *is* the project root — the planned TUI, or any
workspace agent without toolchain paths.

### Properties to write into the yardoc

- **It is a boot-time union over the skills actually *stored*.** One
  untrusted-base skill takes the whole catalog to `:hard`, however many
  trusted ones sit beside it — consistent with `TrifectaLegs#|`
  everywhere else. Say it, so it does not read as a bug. Union at the
  point a skill wins its name, not at scan: a skill *shadowed* by an
  earlier base is never loaded and must not count.
  **The complement is the good half, and it is why the union is over
  *stored* rather than over *declared bases*: an untrusted base that
  turns out to be empty costs nothing.** A host wires `Dir.home` with
  `trusted: false` unconditionally — it cannot know what is there — and
  a user with no `~/.claude/skills` at all still gets `:none`. Nothing
  outside the catalog can compute that without redoing the scan.
  **The other side bounds the payoff, and should be said too:** one
  third-party skill in that directory returns the banner to `:hard`. The
  quiet reading is earned by a wiring whose *entire stored set* is
  vouched for — an empty or absent home base, or one the host declares.
- **Grading the tool silently grades the prompt block.**
  `Extension#system_prompt_snippets` injects the same bundles'
  *descriptions* into the system prompt and declares no legs of its own,
  as does `#schedule_load_skill`; both ride `SkillTool`'s declaration.
  Correct — same bytes, same catalog — but it should be a sentence of
  yardoc rather than an accident, since the extension is where a reader
  would look for a second contribution and find none.
- **The "entire reachable set" rider is what earns the home base its
  grading.** `Filesystem#trusted?` warns: *"claim it only when the
  trusted area is the tool's entire reachable set — a vouched-for island
  inside a broad root buys nothing."* This is the argument for the
  *home* half specifically: a catalog's reachable set is the enumerable
  list of files it loaded at scan time, so grading it per base is
  honest in a way an island inside a walkable root is not. The project
  half needs no such argument; it is just `read`'s answer, repeated.
  Note the rider cuts both ways and that is the open question below: the
  moment the host folds the home base into `readable:`, those bytes stop
  being outside `read`'s reach and the island is `read`'s, not the
  catalog's.

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

**Latent today, and it is the *next* host's problem, not
`pikuri-code`'s** (corrected twice on 2026-08-16: an earlier draft filed
it as an independent bug, and the correction to that overstated it as
live in the shipped wiring). It binds any host that declares
`Filesystem(trusted: true)` while folding home skill roots into
`readable:`. `pikuri-code` cannot be that host — its `readable:` carries
dependency caches forever, so its workspace is honestly untrusted no
matter what the new prompt answers, and `read` stays `:hard`. The host
that hits this is the one "Who asks" names as the first to move a
verdict: readable set == project root, plus `Catalog#roots`. For that
host, `home_skills_are_mine: false` alongside `trusted: true` is exactly
the incoherence `filesystem.rb:392` refuses for `AllowAll`, in
miniature.

Two ways out, and the note does not pick one: extend that raise to any
`readable:` root outside `project_root` under `trusted: true` (then the
host must vouch for its home skills or drop `trusted:`), or stop folding
the home base into `readable:` (then the sidecar `read` for home skills
stops working — see `Catalog#roots`, whose whole documented purpose is
that fold). **Settle it before a host declares a trusted workspace**;
nothing in the catalog change waits on it.

Note what this does *not* block: `pikuri-code` wiring its home base
`trusted: false` and asking no fourth question. That is coherent today —
its workspace claims nothing — and the empty-base complement means a
user with no `~/.claude/skills` still gets the quiet reading.

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
- **`bin/pikuri-code` turns it on** (2026-08-16, superseding this
  note's earlier "nothing turns this on yet" — which had also assumed a
  consumer would arrive via `Filesystem(trusted:)`, and none can there).
  It asks the third question and spends the answer on the catalog's
  project base. So this does not ship as an unconsumed API, unlike the
  caveat `slash-commands.md` raises about itself — but what it consumes
  is the *map*, not the verdict: the node stays `[TRIFECTA: HARD]` on
  `read` + `bash` alone. A host that moves the verdict is one whose
  readable set is the project root.


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
  per-symbol truth (what `trusted:` claims, the union-over-stored rule
  and the empty-base complement, that a base's trust is a claim about
  *that root* rather than about the workspace, and why the reachable-set
  rider only concerns home). `bin/pikuri-code` grows the third prompt +
  a comment saying why its own `Filesystem` stays untrusted regardless —
  a reader who sees the question asked and the workspace left alone will
  otherwise read it as a bug. One `CHANGELOG` sentence; **breaking only
  if** the bare-path form stops working, which it should not.
- **`DECISIONS.md`** gets the fork: *declared per-base trust* vs. four
  roads not taken — spending one repo-trust boolean on both the
  workspace and the catalog (rejected: the two reach different bytes, so
  the honest wiring keeps `pikuri-code`'s workspace untrusted — its
  `readable:` holds `~/.m2` forever — while its project skills go
  trusted; one boolean forces a lie in whichever direction it is set);
  keep the unconditional `:hard` (rejected: it
  over-warns exactly the operator who did the work to deserve a quiet
  banner, and an ignored smoke alarm is the failure mode the module's
  own header names); *derive* trust by having the catalog inspect a
  `Filesystem` (rejected: `pikuri-skills` depends on `pikuri-core` only,
  and reaching for `pikuri-workspace` to answer a question the host can
  answer in one kwarg inverts the dependency for nothing); and a single
  catalog-wide flag instead of per-base (rejected, but **not** on the
  grounds an earlier draft gave — "the common wiring is a trusted
  project plus an unvouched `~/.claude/skills`, and one flag forces that
  case to `:hard`" is falsified by the union rule, which forces the same
  `:hard` whenever that directory *stores a skill*. The real ground is
  the case where it does not: a host must wire `Dir.home` untrusted
  unconditionally, since it cannot know what is there, and only the
  catalog knows whether anything was loaded. Per-base + union-over-stored
  reports `:none` for the user with no `~/.claude/skills`; one flag
  reports `:hard`, and no host can do better without redoing the scan).
- **Rejected** → a one-line why-not in `SkillTool`'s existing comment,
  which is already where a reader meets the question.
