# pikuri-computer

Status: **binary + prompt built; ch7 addendum + live verification pending.**
Realized as `pikuri-os/bin/pikuri-computer` — a demo binary, *not* a gem (see
below) — plus (not yet written) an addendum to the pikuri-os book chapter (ch7).
The binary wires `os --with-internet` (default; `--no-internet` drops the
`RESEARCHER`) + thunderbird (both outbound flags) into one desktop assistant; the
ch7 addendum will own the reassembled-trifecta teaching. A gem is *deferred* —
earned later only if in-perimeter lib code accretes (below), not now. Staging
area — drain into `bin/` + ch7 as it lands (graduation pipeline,
[`../CLAUDE.md`](../CLAUDE.md)). Not yet run against a live model + real
Thunderbird profile.

## Why a bin, not a gem

The gem rested on one pillar: *the composition's threat model belongs to neither
constituent.* That pillar fell. The composed shape — whole-disk `:private` +
attacker-authorable `:untrusted` + human-gated egress — is **≈ `os --with-internet`'s
own threat model** (the `RESEARCHER` already gives os whole-disk human-gated
exfil; see the lesson section). It doesn't belong to "neither"; it belongs to a
documented *os mode*. So the gem's load-bearing justification is gone, and the
proportionate response is a **demo binary + a book addendum** — matched to what's
actually novel (Lesson 2 below: pool amplification + laundering surface; Lesson 1,
the presence-flip, ch7 already teaches via `RESEARCHER`).

This is the note's own earlier-**rejected** alternative (a composition binary
with a cross-gem dev-dep) — un-rejected precisely because the reason for
rejecting it (a novel threat model) is the reason we retired.

## Where it lives

`pikuri-os/bin/pikuri-computer`, `require`-ing pikuri-thunderbird as a **dev/demo
dep** (resolved by the top-level Gemfile; `bin/pikuri-*` are demo entry points,
not advertised gem executables). This keeps pikuri-os's **gemspec, `lib/`, and
extension surface unchanged** — still substrate-only, no thunderbird runtime dep
— so *"not a bigger pikuri-os"* still holds at the level that matters
(identity/deps); only a demo script joins `bin/`. Chosen over hosting in
pikuri-thunderbird: os → computer reads naturally (the OS substrate gaining an
app), thunderbird → computer doesn't, and the teaching lands in the os chapter
anyway.

Thunderbird stays an *app*, not substrate: it does not join os's extension
surface or gemspec; the binary wires it as a demo composition. (That
substrate-vs-app line is exactly why this was never a runtime feature of the os
gem — only a demo on top.)

## What ships

- `pikuri-os/bin/pikuri-computer` — the wiring (both extensions +, by default,
  the `RESEARCHER` sub-agent). Reuses os's `FullFsNoNet` + confirmed-mutation +
  plan-mode posture; adds thunderbird's two outbound flags.
- **Prompt: composed, not a new monolith.** `os-assistant` + `os-network-online`
  (reused as-is) + a lean new `computer-mail-calendar.txt` fragment. The fragment
  carries only what the thunderbird tool descriptions do *not* — the
  untrusted-email policy, the draft/hand-off posture, and a grounding nudge — so
  the per-tool mechanics (plain-text body, dropped recipients, network-calendar
  warning) stay in the tools (the "no per-tool mechanics in a main prompt" rule).
  This is why `thunderbird-compose.txt` was *not* reused wholesale: most of it is
  already tool-owned; only the cross-cutting policy is prompt-level, and
  `os-assistant` had none of it (its inputs were the user's own files), so
  composing thunderbird in genuinely *requires* adding the untrusted block.
- **ch7 addendum** (pending) owns the reassembled-trifecta teaching. No
  `DESIGN.md` without a gem — the book is the legitimate home for a cross-cutting
  threat model (doc-kinds table, [`../CLAUDE.md`](../CLAUDE.md)).

## The two bounds that freeze the concept (why it never becomes pikuri-assistant)

Growth is stopped structurally, not by vigilance — and a frozen concept that
won't accrete is *also* why bin-not-gem is stable (nothing to earn a gem's home):

- **Local perimeter.** The concept admits only *on-device* capability — local
  programs with local data, egress only via a human-gated hand-off to the
  program's own UI. A cloud connector (a WhatsApp cloud API, …) is the agent
  reaching a third party's servers — *out of perimeter, permanently*. This is
  the wall against becoming pikuri-assistant, which is *defined* by wiring cloud
  MCP + doing anything. "computer" names this perimeter (everything on your one
  machine), **not** "maintenance."
- **Pedagogical minimality.** A *local* second egress app (a WhatsApp desktop
  client) would pass the perimeter bound but teach nothing new — the same
  human-gated-egress leg again. One egress app is the complete lesson;
  `os --with-internet` + thunderbird is the *minimal complete demonstration*, so
  the concept freezes there.

Together: no cloud (Bound 1) + one example is enough (Bound 2) = an honestly
frozen concept with a *closeable* threat model — small enough that a binary +
chapter addendum carries it.

## The lesson it teaches (the ch7-addendum spine)

Two lessons ride here, running in *opposite directions* along the composition.
Keep them apart — an earlier draft fused them, which picked the wrong hero and
overstated the gate.

**Lesson 1 — the os direction: presence-flip.** On the *default* `bin/pikuri-os`
— whose whole identity is the *removed* egress leg (`FullFsNoNet`, no
`RESEARCHER`) — the agent is trifecta-**broken by construction**, and adding
thunderbird outbound would flip it **broken → assembled** (the whole-disk
`:private` pool and the attacker-authorable `:untrusted` email channel were
already present; the compose leg is the third wire). That flip is categorical —
the biggest move in the model, *leg presence*, nothing to do with pool size. But
ch7 already teaches this exact flip via `RESEARCHER`, so in the `--with-internet`
demo it's a *thought-experiment contrast*, not a new lesson.

**Lesson 2 — the thunderbird direction: pool amplification (the genuinely new
one).** `bin/pikuri-thunderbird` teaches human-gated egress next to a
*mailbox-sized* pool. Move that *same, unchanged* compose leg next to os's disk
and it becomes a review-gated exfil path for the whole filesystem. The leg's
severity scaled with the pool beside it; nothing about the leg changed.

**Core lesson, both directions in one line: the trifecta is binary in *presence*
(all three legs live → assembled) and graded in *severity* (by the size of the
private pool beside the egress leg).** A leg that's low-risk in one wiring is
serious in another, unchanged.

**What the gate is — and isn't.** Not "author vs approver." Both the `RESEARCHER`
task string (`--with-internet`) and the compose window are *editable approval of a
model-authored prefill* — the human sees a payload, edits or rejects. Against a
blatant blob (`base64` of `id_rsa`) the two gates are equally strong: the human
sees the blob and the foreign destination either way. The real difference is the
**laundering surface** — a research task is query-shaped and short, forcing a
high-entropy secret to ride as a conspicuous blob; an email body is unconstrained
prose, offering a low-conspicuousness path (fluent text, a fake reference number)
the research URL structurally can't. So compose is *marginally* weaker, and only
against *laundered* exfil — not the wholesale "weaker gate" an earlier draft
claimed.

## The ch7 addendum's arc

The reader arrives at `os --with-internet` (ch7 Part 2: `RESEARCHER` reattached
the network, trifecta already assembled, human-gated). The addendum adds
thunderbird and asks *what actually changes* — teaching presence-vs-severity
concretely:

1. **Presence: nothing flips here** — `RESEARCHER` already assembled it. (The
   thought experiment: on the *default* no-egress os, thunderbird's compose leg
   *would* be the presence-flip, the sole egress reassembling the trifecta. That
   contrast is how the reader feels "binary in presence.")
2. **Severity: three things sharpen.** (a) a *stronger untrusted source* — email
   is addressed at the user and looks legitimate, a better injection vector than
   a scraped page; (b) a *second egress channel*, same human-gated mechanic but a
   *richer laundering surface* (email prose vs a query-shaped URL); (c) *pool
   amplification*, made legible by contrasting the identical compose leg in
   standalone `bin/pikuri-thunderbird` (mailbox) with here (whole disk).

The *contrast between baselines and between wirings* is the content — which is
what makes this a teaching addendum rather than two things bolted together.

## The meta-principle this establishes

Growth pattern for all future additions: **grow by adding bounded gems, and each
addition is an occasion to re-examine the trifecta.** Mechanism:

- A **bounded** gem has a *closeable* threat model — freeze the capability
  surface, enumerate the legs, write the DESIGN.md, done. Fattening one gem
  makes every new tool interact with every existing leg → a combinatorial threat
  model that never closes. Horizontal growth (new bounded gems) preserves
  auditability ("small enough to audit"); vertical growth (one fat gem) destroys
  it.
- **But a bounded *concept* doesn't automatically earn a gem.** pikuri-computer
  refines the pattern: its threat model turned out *not novel* (≈
  `--with-internet`), so it stays a demo binary + a chapter, not a gem. "Add a
  gem" needs a *novel* threat model **or** cohesive lib code that needs a home —
  not merely a nameable posture.
- **pikuri-assistant is the deliberate exception** — the one gem that accepts
  the un-closeable surface. Which is exactly why nothing else should drift
  toward it.
- **Name gems after a bounded concept/posture, never a capability bucket.** A
  name that answers "what else could I add?" is wrong; one that answers "what
  does this refuse to become?" is right. ("computer" works only because it's
  pinned to the local-perimeter posture.)

## When it becomes a gem (deferred — not thinking far ahead)

Not on feature count — that's the capability-bucket trap (Bound 1 + the naming
rule). The honest trigger is **cohesive in-perimeter lib code** accreting enough
to need its own home + specs (the pikuri-tasks justification), *not* "what else
could it do":

- **Local music, offline maps, local sensors** — in-perimeter, no new egress
  leg; fine to add to the binary, but they don't change the threat model, so
  they can't justify a gem on threat-model grounds. A cluster of them with real
  lib code eventually *could*, on code-home grounds — its threat model still
  inherited-by-pointer, not novel.
- **Weather, online maps, any cloud API** — the agent reaching a third party's
  servers = *out of perimeter* (Bound 1). Those belong in pikuri-assistant, not
  here.

Until real lib code exists, `bin/pikuri-computer` + the ch7 addendum is the whole
thing.

## Related

- [`pikuri-os.md`](pikuri-os.md) — pikuri-os stays substrate-only in `lib/` /
  gemspec, and now *hosts* `bin/pikuri-computer` (a demo composition, not an os
  feature; thunderbird rides as a dev-dep of the binary).
- [`thunderbird.md`](thunderbird.md) — supplies the inbound + human-gated-outbound
  tools the os binary wires. (Resolves that note's deferred "Integrate into
  pikuri-os" item: *don't* integrate — compose in a demo binary instead.)
- [`trifecta-detector.md`](trifecta-detector.md) — paused. The outbound wiring is
  still the detector's headline example (a full `{private, egress, untrusted}`
  agent, human-gated). Un-pause once the binary exists.
- [`assistant.md`](assistant.md) — the "do anything" endgame pikuri-computer is
  deliberately *not*; the perimeter bound is the wall between them, and it's where
  weather / online maps / any cloud connector belong.
- [`private-context-taint.md`](private-context-taint.md) +
  [`more-confirmers.md`](more-confirmers.md) — the seat that bounds the human
  gate. Note the correction: both gates here are *editable approval of a prefill*;
  the real difference between them is the laundering surface, not author-vs-approver.

## Open / deferred

- **Gem vs binary — resolved: binary in pikuri-os, gem deferred.** Reverses the
  earlier "committed to a new gem" call; the reason is the threat-model-≈-`--with-internet`
  analysis above. Revisit only on accreted in-perimeter lib code.
- **Book placement.** ch7 addendum, appended after Part 2 (`--with-internet`),
  teaching from that baseline. Chapter length is not a constraint. Exact sequence
  TBD when written.
- **Trifecta detector** — paused by decision; resume once the binary exists (its
  concrete example). Until then, document the outbound posture honestly as
  smoke-alarm-grade (human-gated ≠ severed).
- **Name.** `pikuri-computer` for the binary. A *gem* name is deferred with the
  gem. *Rejected* earlier for the gem: `pikuri-desktop` (capability-bucket smell),
  `pikuri-os-assistant` (redundant); `pikuri-personal` / `pikuri-local` left on
  the table.
- **Attendees / other thunderbird deferrals** are thunderbird's, not
  pikuri-computer's — they live in [`thunderbird.md`](thunderbird.md).
