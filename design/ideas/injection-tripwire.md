# Injection tripwire — a Sanitizer flag on LLM-*authored* content is a compromise signal

Status: **idea, not built.** Runtime counterpart to the (static,
boot-time) trifecta detector, which shipped — `book/trifecta-detector.md`
for what it measures. This note is the poisoned-*now* half; the
poisoned-*capable* half is the detector's untrusted leg, and a declared
per-node flag was rejected (`D_no_static_poisoned_flag`). The *has-read*
badge between them rides
pikuri-workshop's [`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md). `ComposeGuard` and
the graded egress axis are both shipped; see
{Pikuri::Thunderbird::ComposeGuard} and {Pikuri::Tool::TrifectaLegs}.
The shell producer, escalation on a repeat and the "start fresh"
affordance went to pikuri-workshop's
[`injection-tripwire.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/injection-tripwire.md)
on 2026-11-21; this note keeps the insight and the mail producer.

## The insight

A `Pikuri::Sanitizer` flag on **content the LLM authored itself** —
bidi override, zero-width, control byte, mixed-script homoglyph — is a
near-certain **prompt-injection tripwire**, not a cosmetic display issue.
A normally-functioning model has *no honest reason* to put those bytes in
an email body it wrote or a bash command it chose; their whole purpose is
to hide meaning from a human reviewer. So tripping the guard is strong
evidence the agent is *currently* being driven by something it read.

This is the load-bearing distinction: **authored-by-LLM vs
relayed-by-LLM.** The Terminal listener also Sanitizes *tool
observations* — but there the funny bytes are an attacker's, faithfully
relayed, and flagging them is correct display-safety, **not** a poisoning
signal. The tripwire is specifically about bytes in the LLM's *own
output*: a body it composed (`ComposeGuard`), a command it wants to run
(the Bash confirmer's Sanitized display of LLM-authored argv). Same
primitive, opposite meaning depending on who authored the bytes.

## The bug it exposes (verified, not assumed)

Today the tripwire fires but the alarm rings in the wrong room.
`MailCompose#compose` (`mail_compose.rb:77`) turns a fail-closed body into
`"Error: #{verdict.error}"` — which becomes the **tool observation fed
back to the LLM**, i.e. to the *poisoned* agent. The human sees it only if
the Terminal listener happens to render the tool error, framed as routine.
Net effect: the guard blocked *this* attempt, told the *attacker's puppet*
about the block, and left the session running — free to retry with
linguistic stego (which the guard can't catch). Symptom treated, disease
in-context.

## Proposed next steps — a graduated response, NOT auto-teardown

1. **Block the draft** — shipped (`ComposeGuard` fail-close).
2. **Route the signal to the human, loudly.** Emit a distinct event
   (`ctx.emit_event`, per the capability seam) that a listener renders as
   an unmistakable security alert — not a tool-error string the LLM reads.
   This is the core fix: the audience is currently wrong. The general
   mechanism (and *why* it must bypass the LLM — an untrusted narrator for
   its own compromise) is spun out to
   [`warn-human-directly.md`](warn-human-directly.md); the tripwire is its
   first producer.
3. **Frame it as compromise, in plain words.** "The assistant tried to put
   hidden/deceptive characters into an outgoing email. A normal assistant
   never does this — it has very likely been manipulated by content it
   read (a prompt injection)."
4. **Advise dropping the poisoned context** and **name the likely source**
   ("the message it just read may be hostile — don't act on it"). The
   one-step "start fresh" affordance that would act on the advice is a
   host's UI (the workshop note).

### Why *advise*, not auto-close the harness

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

### The subtlety the advice must carry

**Clearing context is not enough if the poison lives in a durable store.**
The injection came from an email in the Gloda index; re-running the same
query re-reads the hostile message → re-poison. So the advice is
context-drop **plus source-awareness** ("don't re-open that message"),
never a silent context wipe that lets the user walk straight back in.

## Relation to the trifecta detector, and to base64

- **Runtime confirmation of the static verdict.** The detector says (at
  boot) "this agent is poisoned-*capable*" — hard `:untrusted` + `:private`
  + `:egress`. The tripwire says (at runtime) "and here's a live signal it
  is poisoned-*actual*." Empirical confirmation of open-question (a)'s
  `poisoned` state.
- **Higher confidence than the base64 spotter.** The hidden-byte classes
  have ~zero honest *authored* use, so the tripwire justifies a
  teardown-advice response. A base64 blob
  ({Pikuri::Thunderbird::ComposeGuard#body_blob_note},
  `D_blob_spotter_alphabets`) *does* have honest
  uses (a pasted cert/token), so it's only a soft warn — different tier,
  different response. Don't conflate them.

## Open questions

- Which event variant / listener rendering? (One `SuspectedInjection`
  event carrying the flagged kinds + the tool that produced it.)
- Does the "authored vs relayed" split need to be explicit in the
  Sanitizer API (a caller-supplied provenance flag), or does each call
  site already know which it is? (It does — so keep provenance at the call
  site, don't widen `Sanitizer`.)
