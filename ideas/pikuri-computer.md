# pikuri-computer

Status: **fully landed — binary + prompt + ch7 addendum built and live-verified.**
Realized as `pikuri-os/bin/pikuri-computer` — a demo binary, *not* a gem (see
below) — plus the addendum to the pikuri-os book chapter (ch7 Part 3, landed).
The binary wires `os --with-internet` (default; `--no-internet` drops the
`RESEARCHER`) + thunderbird (both outbound flags) into one desktop assistant; the
ch7 addendum owns the reassembled-trifecta teaching. A gem is *deferred* —
earned later only if in-perimeter lib code accretes (below), not now. Verified
end-to-end against a live model + a real Thunderbird profile. What remains in this
note is only the origin map + the deferred-gem trigger (graduation pipeline,
[`../CLAUDE.md`](../CLAUDE.md)).

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
  (reused as-is); the mail/calendar guidance rides `Thunderbird::Extension`'s
  `system_prompt_snippets` (untrusted-email policy + grounding discipline always,
  draft/hand-off paragraph when an `allow_` flag is on), so the binary appends no
  thunderbird fragment of its own and the per-tool mechanics (plain-text body,
  dropped recipients, network-calendar warning) stay in the tools. The
  cross-cutting untrusted block that `os-assistant` lacks (its inputs were the
  user's own files) now arrives *automatically with the extension*, so wiring
  thunderbird in can't forget it. (Superseded the earlier plan of a hand-written
  `computer-mail-calendar.txt` fragment — same content, but owned once by the
  extension instead of copied per binary.)
- **ch7 addendum** (landed as ch7 Part 3) owns the reassembled-trifecta teaching.
  No `DESIGN.md` without a gem — the book is the legitimate home for a
  cross-cutting threat model (doc-kinds table, [`../CLAUDE.md`](../CLAUDE.md)).

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

## The lesson it teaches — graduated to ch7 Part 3

The reassembled-trifecta teaching — the presence-vs-severity spine, the pool
amplification contrast, and the "what the gate is / isn't" laundering-surface
correction — has **landed in the book** (`book/07-os-assistant.md`, Part 3),
which is now its source of truth. Origin summary, kept for the map:

- **Presence (binary).** All three legs live → assembled, full stop; the biggest
  move in the model is leg *presence*, not pool size. ch7 already teaches the
  flip via `RESEARCHER`, so on `--with-internet` it's a *thought-experiment
  contrast* (the default no-egress os is where thunderbird's compose leg *would*
  be the presence-flip).
- **Severity (graded).** Same compose leg, bigger pool: standalone
  `bin/pikuri-thunderbird` (mailbox) vs here (whole disk) = pool amplification;
  plus a stronger untrusted source (aimed email) and a richer laundering surface
  (prose vs query-shaped URL).
- **The gate.** Not "author vs approver" — both `RESEARCHER` task and compose
  window are *editable approval of a model-authored prefill*; the only real gap
  is the laundering surface, so compose is *marginally* weaker and only against
  *laundered* exfil.

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
- [`trifecta-detector.md`](trifecta-detector.md) — the outbound wiring is the
  detector's headline example (a full `{private, egress, untrusted}` agent,
  human-gated), and it now exists + is live-verified — so the "un-pause once the
  binary exists" condition is met; resuming is that note's own call.
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
- **Book placement — resolved.** Landed as **ch7 Part 3**, appended after Part 2
  (`--with-internet`) and teaching from that baseline; the two-part chapter intro
  and the `book/README.md` TOC entry were updated to three parts.
- **Trifecta detector** — its stated blocker is now cleared: the binary exists
  and is live-verified, so the detector's headline `{private, egress, untrusted}`
  human-gated example is concrete. Resuming the detector is now its own note's
  call ([`trifecta-detector.md`](trifecta-detector.md)); the outbound posture
  stays documented honestly as smoke-alarm-grade (human-gated ≠ severed).
- **Name.** `pikuri-computer` for the binary. A *gem* name is deferred with the
  gem. *Rejected* earlier for the gem: `pikuri-desktop` (capability-bucket smell),
  `pikuri-os-assistant` (redundant); `pikuri-personal` / `pikuri-local` left on
  the table.
- **Attendees / other thunderbird deferrals** are thunderbird's, not
  pikuri-computer's — they live in [`thunderbird.md`](thunderbird.md).
