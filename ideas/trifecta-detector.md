# Trifecta detector — the one question left

Status: **built and shipped** — v1 on 2026-08-09, the `egress_destination`
axis on 2026-08-12. Nothing about the detector is outstanding, so this file
is no longer a design note; it keeps only the one question the detector has
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
  `SEARCHER` persona), `D-trifecta-map-orphans`, and `D-write-custody-axis`
  (the synced-folder / `Write` gap: closed won't-build, carrying the custody
  test and the host-side escape hatch for it).
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

The question below has no slot, blocks nothing, and is not a piece of a larger
plan. It is a standalone open topic.

## Should severity carry a per-agent `poisoned` assumption?

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

**The argument to beat, from the runtime side:**
[`private-context-taint.md`](private-context-taint.md) refuses exactly this
kind of nuance for its own taint — coarse-and-honest, because a model blends
everything, so *a private source was called* is the entire rule. A static
grader knows strictly less than a runtime one, so if per-node nuance is
unsound there it needs a very good reason to be sound here. (Different leg —
that note tracks `:private`, this asks about `:untrusted` — which is why the
question lives here and not there.)

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
