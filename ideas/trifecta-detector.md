# Trifecta detector — the two questions left

Status: **built and shipped** — v1 on 2026-08-09, the `egress_destination`
axis on 2026-08-12. Nothing about the detector is outstanding, so this file
is no longer a design note; it keeps only the two questions the detector has
never answered.

Where everything went, so nobody hunts here for it:

- **Mechanics + per-symbol rationale** → {Pikuri::Trifecta},
  {Pikuri::Tool::TrifectaLegs}, `Trifecta::{Node,Report,Contribution}`, the
  three posture predicates (`Sandbox#egress?` / `#confined_to_workspace?`,
  `Confirmer#blocks_on_human?`), `Filesystem(private:, trusted:)`,
  `Extension#trifecta_contribution`. Source is the authority.
- **The reader's half** → `book/trifecta-detector.md` ("Measuring the
  trifecta"): the two strength lattices and the verdict grid, the
  payload-visibility test, the destination test, what the detector refuses to
  grade, propagation (max in parallel / min in series), the
  one-binary-three-verdicts walkthrough, how to tag your own tool.
- **Roads not taken** → `D-egress-axis-shape` (the two-axis shape, the
  `egress_human_author` drop, the rejected proxy-visible rung, the dropped
  `SEARCHER` persona) and `D-trifecta-map-orphans`.
- **The paper dry-run table** → `pikuri-code/spec/pikuri/code/dry_run_spec.rb`
  and `pikuri-core/spec/pikuri/trifecta_build_spec.rb`, which are now the live
  version of it. Moral from validating this thing by hand, recorded because it
  cost a false finding: stub a leg and you will invent a bug — render the real
  wiring.

Two threads that were parked here have owners elsewhere: the runtime "this
agent is poisoned *right now*" signal is
[`injection-tripwire.md`](injection-tripwire.md)'s, and the structural version
of the untrusted attenuation is
[`quarantined-handles.md`](quarantined-handles.md)'s.

Neither question below has a slot, blocks anything, or is a piece of a larger
plan. They are standalone open topics.

## 1. Is a synced folder an egress sink? (the `Write` / `Edit` gap)

`Write` and `Edit` ship as `TrifectaLegs::NONE`, with the gap stated at the
declaration site: a workspace pointed at `~/Dropbox` plausibly turns a write
into egress, and nothing declares it. The intuition that wouldn't resolve was
that such a write looks like `:tool_vouched` — the destination is a party the
attacker doesn't control — but *safer than that somehow*.

**The "somehow" has a name: custody.** `egress_destination` grades whether the
attacker can *read back* what left, which is the wrong axis here. The property
that actually separates these cases is:

> **Does the recipient differ from the data's owner?**

- A **search query** changes custody. The bytes land in a third party's logs,
  with no relationship to the user, and can't be retracted. Unreadable to the
  attacker, but genuinely *out*.
- A **personal cloud sync** does not. The bytes land in the user's *own
  account* — same owner, different hardware. An attacker gains nothing without
  also compromising that account, which the agent never granted. So this isn't
  a weaker egress leg, it is **not a leg at all**, and "one step safer" is
  really "off the axis".
- A **shared** folder (a team Drive, a public link) *does* change custody, and
  isn't a middle rung either: the recipients are humans, the bytes persist, and
  a public link is readable by anyone. Plain `:attacker_reachable`, arguably
  worse than a search query.

**So probably no new lattice level.** The two ends collapse onto values that
already exist and the middle is empty. What might be earned is a
*declaration* — and the four values first floated (local / private cloud /
shared cloud / git) collapse to a binary once custody is the test.

**Git doesn't belong on this axis.** A write into a working tree egresses
nothing; a `push` does, and a push is `bash`, already tagged from the sandbox.
What distinguishes the Dropbox case is that replication is **ambient** — it
happens with no further agent action. A sink that needs a deliberate second
capability is already covered by that capability.

**If it is ever built it needs no new machinery.** The reachable-set rule
applies unchanged: `~/Dropbox` routinely holds both private and shared
subfolders, so a declaration may only lower the tag when the vouched-for area
is the tool's *entire* reachable set. "There is a shared folder somewhere
under this root" means the leg is present, exactly as a trusted island inside
a broad root buys nothing.

Not urgent, and cheap to add late: no wiring in the repo points a workspace at
a synced folder, so it would change no verdict today, and unlike the
destination axis this one is *user-declared* — reachable the day someone
declares it. `book/trifecta-detector.md` §"The edges, stated plainly" names
the absence, and `D-egress-axis-shape` points here.

## 2. Should severity carry a per-agent `poisoned` assumption?

Propagation today implicitly assumes every parent is drivable — that it will
faithfully relay or launder whatever it is told. True for `pikuri-computer`,
whose parent reads attacker-authored mail on day 1; pessimistic for a topology
built to keep the parent pristine, where untrusted content reaches it only as
sub-agent summaries (the federation in [`assistant.md`](assistant.md)). A
`poisoned: true|false` per node would let the two analyses differ.

**The lead to check before adding any flag: this may already *be* the
untrusted strength axis.** A node holding hard `:untrusted` reads attacker
content directly, so it is poisoned-capable; one holding only `:weakened` gets
it through a summarizing boundary, so it resists. If that mapping holds
everywhere, the soft/loud split already encodes poisoned-vs-pristine and a
separate flag is redundant. Unverified — the job is to hunt for a scenario the
lattice can't express, and to add the flag only if one exists.

Three parts of this are settled and shouldn't be relitigated:

- **The laundering channel is modelled.** A poisoned parent putting a secret
  into a sub-agent task string is exactly why egress propagates up at full
  strength: the parent can just *ask* the egress-holder to send the thing.
- **`git_clone` is a readable egress verb.** The clone host is
  attacker-chosen, so `:attacker_reachable`, never `:tool_vouched` — declared
  with that reasoning at its declaration site. Its persona's harmlessness
  comes from holding no `:private`, never from bounded egress.
- **The runtime side is a different note.** A `Sanitizer` fail-close on
  LLM-*authored* outbound content is a live "poisoned now" signal rather than
  a poisoned-*capable* one, and today it is misrouted to the LLM instead of
  the human — [`injection-tripwire.md`](injection-tripwire.md).
