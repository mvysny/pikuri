# Warn the human directly — a security-alert channel that bypasses the LLM

Status: **idea, not built.** The delivery mechanism the injection
tripwire needs, but broader — see
[`injection-tripwire.md`](injection-tripwire.md) (its step 2) and
[`trifecta-detector.md`](trifecta-detector.md) §"(b)" (`ComposeGuard`).

## The principle

**The LLM is an untrusted narrator for security-relevant messages.** Any
warning that reaches the human *only* by the LLM relaying it is worth
exactly as much as the LLM's honesty — and in the one scenario where the
warning matters most (a prompt injection), the narrator is compromised. So
a security signal the human must see has to travel on a channel the LLM
**cannot author into, drop, soften, or paraphrase away.**

## The gap (grounded, not assumed)

The channel already exists and is used for benign domain events:
`ctx.emit_event(...)` → each listener's `on_event(event)` → the Terminal
listener renders it (today: `PlanModeChanged`, `ListChanged`,
`FallbackNotice`). What's missing is that **guard / security signals don't
use it** — they ride the tool's return string back into the LLM's context:

- `MailCompose#compose` returns `ComposeGuard`'s notes (recipient-novelty
  warning, dropped-field notices) *as the observation*, and the tool
  description literally instructs the model to "relay that warning to the
  user." A poisoned agent simply doesn't.
- The fail-closed body error goes the same way (see the tripwire note).

So every human-facing guard note currently depends on the narrator. That's
the bug class this feature closes.

## What the feature is

A **direct-to-human, out-of-band alert channel**: a security-event variant
(e.g. `SecurityNotice` / `HumanAlert`) emitted by *guard/tool code*, that a
listener renders as chrome speaking — visually distinct from model output,
un-spoofable precisely because the LLM never authored it.

Its trustworthiness is the mirror of the Confirmer's: **Confirmer = *ask*
the human (sync, blocking, a yes/no gate); this = *tell* the human (async,
one-way, no decision).** The Confirmer already proves chrome can address
the human un-forgeably; this is its non-blocking sibling for notices that
aren't gates (a warning about a draft that *was* handed off; a tripwire on
a draft that was blocked).

Producers on day one: the injection tripwire, `ComposeGuard`'s novelty +
dropped-field notes. Then any deterministic guard verdict the human must
act on.

## Design notes

- **Dual delivery, not either/or.** The LLM still needs a minimal
  observation ("draft blocked" / "recipient flagged") so it doesn't loop or
  hallucinate success — but the *authoritative human copy* rides the event.
  Decide the minimal LLM-facing text: enough to not loop, not enough to
  game the human channel.
- **Defang quoted attacker fragments.** Guard-authored text is trusted (no
  defanging needed), but where a notice *quotes* attacker-controlled data
  (the novel domain, a dropped address) that fragment must go through
  `Pikuri::Sanitizer` — the same reason the Confirmer does.
- **Fires even under `--no-confirm` / `AUTO_APPROVE`.** Auto-approve
  silences *gates* (decisions), not *alerts* (information). A session that
  skips confirmations should still get the tripwire alarm. This is the
  concrete payoff of the ask-vs-tell split.
- **Seam:** capability seam (`emit_event`); listeners no-op on unknown
  variants; chrome-agnostic, so a future TUI renders the same event its own
  way. The event is the contract.

## Open questions

- One event variant with a severity field, or distinct variants
  (notice / alarm)? Severity drives rendering loudness + the tripwire's
  escalate-on-repeat.
- Where's the shared emit point so `ComposeGuard`, the tripwire, and the
  Bash confirmer don't each reinvent it? (A small helper on the
  capability context, or a mixin the guards call.)
- Alarm fatigue — the channel is only as valuable as it is rare. What's the
  bar for "the human *must* see this" vs. "let the LLM relay it"? Guard
  verdicts that are deterministic + security-relevant qualify; routine tool
  chatter does not.
