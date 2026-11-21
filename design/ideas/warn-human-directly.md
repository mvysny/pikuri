# Warn the human directly — a security-alert channel that bypasses the LLM

Status: **idea, not built.** Its first producer, the injection tripwire,
was folded in on 2026-11-21 (§"The injection tripwire" below); the
tripwire's shell producer, escalation on a repeat and the "start fresh"
affordance are pikuri-workshop's
[`injection-tripwire.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/injection-tripwire.md).
Shipped and leaned on: {Pikuri::Thunderbird::ComposeGuard}, whose
warnings reach the human only because the model relays them, and the
static trifecta detector (`book/trifecta-detector.md`), the poisoned-*capable*
half to the tripwire's poisoned-*now*; a declared per-node flag between
them was rejected (`D_no_static_poisoned_flag`), and the *has-read* badge
rides pikuri-workshop's
[`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md).

## The principle

**The LLM is an untrusted narrator for security-relevant messages.** Any
warning that reaches the human *only* by the LLM relaying it is worth
exactly as much as the LLM's honesty — and in the one scenario where the
warning matters most (a prompt injection), the narrator is compromised. So
a security signal the human must see has to travel on a channel the LLM
**cannot author into, drop, soften, or paraphrase away.**

## The gap (grounded, not assumed)

The channel already exists: `Configurator#emit_event(...)` → each
listener's `on_event(event)` → the Terminal listener renders it. Only the
workshop's benign domain events use it today (`PlanModeChanged`,
`ListChanged`); nothing in pikuri emits one. **Guard / security signals
don't use it** — they ride the tool's return string back into the LLM's
context:

- `MailCompose` returns `ComposeGuard`'s notes (recipient-novelty
  warning, dropped-field notices) *as the observation*, and its tool
  description literally instructs the model to "relay that warning to the
  user" (`mail_compose.rb:43`). A poisoned agent simply doesn't.
- The fail-closed body goes the same way: `mail_compose.rb:80` answers
  `Tool::Result.error(verdict.error)`, an observation fed back to the
  *poisoned* agent. The human sees it only if the Terminal listener
  happens to render the tool error, framed as routine. The guard blocked
  *this* attempt, told the *attacker's puppet* about the block, and left
  the session running — free to retry with linguistic stego, which the
  guard can't catch. Symptom treated, disease in-context.

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

Producers on day one: the injection tripwire (below), `ComposeGuard`'s
novelty + dropped-field notes. Then any deterministic guard verdict the
human must act on.

## The injection tripwire — the first producer

### The insight

A `Pikuri::Sanitizer` flag on **content the LLM authored itself** —
bidi override, zero-width, control byte, mixed-script homoglyph — is a
near-certain **prompt-injection tripwire**, not a cosmetic display issue.
A normally-functioning model has *no honest reason* to put those bytes in
an email body it wrote; their whole purpose is to hide meaning from a
human reviewer. So tripping the guard is strong evidence the agent is
*currently* being driven by something it read.

The load-bearing distinction is **authored-by-LLM vs relayed-by-LLM.**
The Terminal listener also Sanitizes *tool observations* — but there the
funny bytes are an attacker's, faithfully relayed, and flagging them is
correct display-safety, **not** a poisoning signal. The tripwire is about
bytes in the LLM's *own output*: a body it composed (`ComposeGuard`).
Same primitive, opposite meaning depending on who authored the bytes. Each
call site already knows which it is, so provenance stays at the call site
and `Sanitizer` does not grow a provenance flag.

### A graduated response, not auto-teardown

1. **Block the draft** — shipped (`ComposeGuard` fail-close).
2. **Route the signal to the human, loudly**, on the alert channel above
   rather than as a tool-error string the LLM reads. This is the core
   fix: the audience is currently wrong.
3. **Frame it as compromise, in plain words.** "The assistant tried to put
   hidden/deceptive characters into an outgoing email. A normal assistant
   never does this — it has very likely been manipulated by content it
   read (a prompt injection)."
4. **Advise dropping the poisoned context** and **name the likely source**
   ("the message it just read may be hostile — don't act on it"). The
   one-step "start fresh" affordance that would act on the advice is a
   host's UI (the workshop note).

The instinct ("close the harness, it's poisoned") is right in spirit, but
auto-teardown is the wrong default:

- **False positives exist.** The user may have asked the agent to quote /
  relay a message that legitimately carries such bytes, or a rare
  mixed-script misfire. Auto-killing on every flag trains dismissal — the
  exact alarm-fatigue that hollows out the whole approver seat.
- **DoS lever.** If one crafted email in front of the agent can force-kill
  every session, that's an availability attack. Annoying, not
  catastrophic, but a reason not to make teardown automatic.
- **Agency.** Tearing down loses the user's working session; that should be
  their call, made with a clear explanation, not the harness's.

A harder default on a *second* trip (auto-clearing the context) is the
workshop note's.

**The advice must carry the source.** Clearing context is not enough when
the poison lives in a durable store: the injection came from an email in
the Gloda index, and re-running the same query re-reads the hostile
message → re-poison. So the advice is context-drop **plus
source-awareness** ("don't re-open that message"), never a silent context
wipe that lets the user walk straight back in.

### Relation to the trifecta detector, and to base64

- **Runtime confirmation of the static verdict.** The detector says (at
  boot) "this agent is poisoned-*capable*" — hard `:untrusted` + `:private`
  + `:egress`. The tripwire says (at runtime) "and here's a live signal it
  is poisoned-*actual*."
- **Higher confidence than the base64 spotter.** The hidden-byte classes
  have ~zero honest *authored* use, so the tripwire justifies a
  teardown-advice response. A base64 blob
  ({Pikuri::Thunderbird::ComposeGuard#body_blob_note},
  `D_blob_spotter_alphabets`) *does* have honest uses (a pasted
  cert/token), so it's only a soft warn — different tier, different
  response. Don't conflate them.

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
  (notice / alarm)? Severity drives rendering loudness and the workshop's
  escalate-on-repeat. The tripwire's alarm wants the flagged kinds and the
  tool that produced it (a `SuspectedInjection` shape).
- Where's the shared emit point, so `ComposeGuard`, the tripwire and the
  workshop's shell producer don't each reinvent it? (A small helper on the
  capability context, or a mixin the guards call.)
- Alarm fatigue — the channel is only as valuable as it is rare. What's the
  bar for "the human *must* see this" vs. "let the LLM relay it"? Guard
  verdicts that are deterministic + security-relevant qualify; routine tool
  chatter does not.
