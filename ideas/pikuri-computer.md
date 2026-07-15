# pikuri-computer

Status: **designed, not built.** The shape is settled (this note); nothing
shipped. The gem composes `pikuri-os` + `pikuri-thunderbird` into one agent and
owns the *reassembled-trifecta* threat model that belongs to neither
constituent. This file is the staging area — as pieces land in source / `book/`
/ CLAUDE.md, cut them per the graduation pipeline
([`../CLAUDE.md`](../CLAUDE.md)) so what remains is always "not yet done."

## Why a new gem (and not a bigger pikuri-os)

The origin: pikuri-os *looked* like it should grow to host thunderbird (with
the os book chapter covering both). It shouldn't. pikuri-os is not a bundle — it
deps core/workspace/code as its *substrate* (an OS helper needs bash + file
tools) and adds OS-substrate functionality (file-index, machine memory, boot
grounding) under one defining posture: **offline, no-egress-by-enforcement
(`FullFsNoNet`), audit-first.**

Thunderbird exposed a latent tension — *identity vs ambition*: pikuri-os wants
to stay a crisp, auditable OS-substrate helper, but it's tempting to make it the
home for "everything the assistant can do on this machine," which pulls toward
apps + egress + open-ended growth. Resolution: **pikuri-os IS the identity; the
grab-bag is a different gem.** pikuri-os and pikuri-thunderbird both stay exactly
as they are; growth happens by *adding* pikuri-computer, which deps both and
wires them.

Why thunderbird isn't just another "program we control" like localsearch/recoll:

- **Conceptual layer.** localsearch/recoll/filesystem/sysinfo are the OS/desktop
  *substrate*; thunderbird is an *application*. Substrate → pikuri-os; apps →
  pikuri-computer.
- **The egress leg.** localsearch/recoll structurally *cannot* egress.
  Thunderbird's outbound tools reintroduce the exact leg pikuri-os exists to
  remove — so it can't be privileged the way the read-only indexers are; it
  would put back pikuri-os's defining absence.

## What the gem is (contents)

A wiring + prompt + threat-model gem — same shape as `pikuri-assistant`
(little/no lib code of its own):

- gemspec deps: `pikuri-os` + `pikuri-thunderbird`.
- `bin/pikuri-computer` + `prompts/` — the inbound-only wiring reuses
  thunderbird's read-only stance; the outbound wiring needs a
  drafting-for-review prompt (the `thunderbird-compose` shape).
- `DESIGN.md` — the reassembled-trifecta threat model (the payload; below).
- Optionally a one-call composed `Extension`, *only* if the binary would
  otherwise repeat wiring — don't invent lib code it doesn't need.

pikuri-os keeps its own lean demo binary (the pure no-egress OS-diagnosis
exemplar). Optional cleanup: rename `bin/pikuri-os-assistant` → `bin/pikuri-os`
so "os" and "computer" name two clearly-distinct postures (binaries are dev/demo
entry points, so the rename is cheap).

## The two bounds that freeze it (why it never becomes pikuri-assistant)

Growth is stopped structurally, not by vigilance:

- **Local perimeter.** The gem admits only *on-device* capability — local
  programs with local data, egress only via a human-gated hand-off to the
  program's own UI. A cloud connector (a WhatsApp cloud API, …) is the agent
  reaching a third party's servers — *out of perimeter, permanently*. This is
  the wall against becoming pikuri-assistant, which is *defined* by wiring cloud
  MCP + doing anything. "computer" names this perimeter (everything on your one
  machine), **not** "maintenance."
- **Pedagogical minimality.** A *local* second egress app (a WhatsApp desktop
  client) would pass the perimeter bound but teach nothing new — the same
  human-gated-egress leg again. One egress app is the complete lesson; os +
  thunderbird is the *minimal complete demonstration*, so the gem freezes there.

Together: no cloud (Bound 1) + one example is enough (Bound 2) = an honestly
frozen gem with a *closeable* threat model.

## The lesson it teaches (the DESIGN.md + book-chapter spine)

`bin/pikuri-thunderbird` already teaches human-gated egress — but next to a
*mailbox-sized* private pool. Compose with pikuri-os and the private pool
becomes the *entire filesystem*: the same compose window is now a review-gated
exfil path for the whole disk, behind the *weaker* approve-a-prefill gate
(contrast pikuri-os's `--with-internet` author-seat gate on the RESEARCHER task
string — structurally separated, researcher holds no fs).

**Core lesson: the trifecta's severity scales with the size of the private pool
sitting next to the egress leg, not merely with the presence of the legs.** A
leg that's low-risk in one wiring is serious in another, unchanged.

## Teach it in two parts

The book chapter (and the build) split cleanly along the egress leg:

1. **Add thunderbird *inbound* only (no egress).** Wire the five read-only tools
   onto the os agent. Analyze: a strong new `:untrusted` source (email is the
   textbook attacker-authorable channel) + a bigger `:private` pool, but egress
   still kernel-severed (`FullFsNoNet`) → **trifecta stays broken.** The lesson:
   untrusted + private without egress is *safe*, and *why* (two legs is fine;
   the wire needs all three).
2. **Add thunderbird *outbound* (compose / calendar-create).** The human-gated
   egress leg returns. Analyze the shift: the trifecta reassembles (human-gated,
   not autonomous), the private pool is the whole disk, the gate is
   approve-a-prefill (weaker than the author seat). The lesson: **pool-size
   amplification** + why the same leg's danger changed.

The *contrast between the two wirings* is the content — which is exactly why the
gem is a good teaching artifact rather than just two things bolted together.

## The meta-principle this establishes

Growth pattern for all future additions: **grow by adding bounded gems, and each
addition is an occasion to re-examine the trifecta.** Mechanism:

- A **bounded** gem has a *closeable* threat model — freeze the capability
  surface, enumerate the legs, write the DESIGN.md, done. Fattening one gem
  makes every new tool interact with every existing leg → a combinatorial threat
  model that never closes. Horizontal growth (new bounded gems) preserves
  auditability ("small enough to audit"); vertical growth (one fat gem) destroys
  it.
- **pikuri-assistant is the deliberate exception** — the one gem that accepts
  the un-closeable surface. Which is exactly why nothing else should drift
  toward it.
- **Name gems after a bounded concept/posture, never a capability bucket.** A
  name that answers "what else could I add?" is wrong; one that answers "what
  does this refuse to become?" is right. ("computer" works only because it's
  pinned to the local-perimeter posture.)

## Related

- [`os-assistant.md`](os-assistant.md) — pikuri-os stays as-is: the no-egress
  OS-substrate exemplar. pikuri-computer composes *on top* without changing it.
- [`thunderbird.md`](thunderbird.md) — pikuri-thunderbird stays as-is: supplies
  the inbound + human-gated-outbound tools pikuri-computer wires. (Resolves that
  note's deferred "Integrate into pikuri-os" item: *don't* — compose in
  pikuri-computer instead.)
- [`trifecta-detector.md`](trifecta-detector.md) — paused. pikuri-computer's
  outbound wiring is the detector's headline example (a full
  `{private, egress, untrusted}` agent, human-gated). Un-pause once the gem
  exists.
- [`assistant.md`](assistant.md) — the "do anything" endgame pikuri-computer is
  deliberately *not*; the perimeter bound is the wall between them.
- [`private-context-taint.md`](private-context-taint.md) +
  [`more-confirmers.md`](more-confirmers.md) — the author-vs-approver seat that
  bounds how much the human gate actually buys.

## Open / deferred

- **Trifecta detector** — paused by decision; resume once the gem exists (it's
  the concrete example). Until then, document the outbound posture honestly as
  smoke-alarm-grade (human-gated ≠ severed).
- **Book placement.** Likely: os chapter (ch7) stays pure (egress removed) → a
  thunderbird beat (single-app human-gated egress) → a pikuri-computer chapter
  (compose + the two-part trifecta-reassembly analysis above). Exact sequence
  TBD when written.
- **Gem-vs-binary final call.** Committed to a new gem — the composition's
  threat model belongs to neither constituent. The lighter alternative (a binary
  in pikuri-thunderbird with an os dev-dep) was weighed and dropped for that
  reason.
- **Name.** `pikuri-computer` chosen. *Rejected:* `pikuri-desktop`
  (capability-bucket smell + too close to the pikuri-assistant endgame),
  `pikuri-os-assistant` (collides with the existing binary name). `pikuri-personal`
  / `pikuri-local` (more literal perimeter names) left on the table, not preferred.
- **Attendees / other thunderbird deferrals** are thunderbird's, not
  pikuri-computer's — they live in [`thunderbird.md`](thunderbird.md).
