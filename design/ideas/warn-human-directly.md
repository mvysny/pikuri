# Warn the human directly — a security-alert channel that bypasses the LLM

Status: **idea, not built; leaning build** (§"The lean"). Its first
producer, the injection tripwire, was folded in on 2026-11-21
(§"The injection tripwire" below); the tripwire's shell producer,
escalation on a repeat and the "start fresh" affordance are
pikuri-workshop's
[`injection-tripwire.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/injection-tripwire.md).
Shipped and leaned on: {Pikuri::Thunderbird::ComposeGuard}, whose
warnings reach the human only because the model relays them, and the
static trifecta detector (`book/trifecta-detector.md`), the poisoned-*capable*
half to the tripwire's poisoned-*now*; a declared per-node flag between
them was rejected (`D_no_static_poisoned_flag`), and the *has-read* badge
rides pikuri-workshop's
[`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md).
Prerequisite shipped 2026-11-21: {Pikuri::Agent::Listener::Terminal}
escapes control bytes in model prose, so the model can no longer erase
the alert line it follows (§"Un-spoofable needs the chrome").

## The lean (2026-11-21)

**Build it in pikuri, small.** It passes `D_gem_placement` test 3 because
it closes a gap in the trifecta promise. The compose window is the gate, and
the guard's notes are what the human at the gate sees, but today they
arrive only through the agent they guard against.

- **One core variant, `Agent::Event::Alert(text)`.** Not a severity field
  and not distinct variants (`Q_severity`).
- **No shared emit helper.** `Extension#configure` hands the tool a
  lambda (`Q_emit_point`).
- **Producers:** `ComposeGuard`'s novelty, blob and dropped-field notes,
  plus the tripwire. **Not** the "couldn't check" notes (`Q_bar`).
- **The model gets a count, not the content:** "The user was shown 2
  warnings directly." The relay-the-warning instructions go
  (§"Design notes").
- **The tripwire's compromise framing is scoped to three kinds**
  (`:bidi`, `:backspace`, `:control_bytes`) and **framed around the source**
  (§"The injection tripwire").

## The principle

**The LLM is an untrusted narrator for security-relevant messages.** Any
warning that reaches the human *only* by the LLM relaying it is worth
exactly as much as the LLM's honesty — and in the one scenario where the
warning matters most (a prompt injection), the narrator is compromised. So
a security signal the human must see has to travel on a channel the LLM
**cannot author into, drop, soften, or paraphrase away.**

## The gap (grounded, not assumed)

The channel half-exists: `Configurator#emit_event(...)` → each
listener's `on_event(event)` → the Terminal listener renders it. Only the
workshop's benign domain events use it today (`PlanModeChanged`,
`ListChanged`); nothing in pikuri emits one. And `Terminal` renders an
event it doesn't recognize as its *dimmest* line (a grey `·`), the
opposite of an alarm. **Guard / security signals don't use it.** They ride
the tool's return string back into the LLM's context:

- `MailCompose` returns `ComposeGuard`'s notes (recipient-novelty
  warning, dropped-field notices) *as the observation*. Its tool
  description literally instructs the model to "relay that warning to the
  user" (`mail_compose.rb:43`), and so does the Extension's
  `OUTBOUND_USAGE` prompt. A poisoned agent simply doesn't.
- The fail-closed body goes the same way: `mail_compose.rb:80` answers
  `Tool::Result.error(verdict.error)`, an observation fed back to the
  *poisoned* agent. The human sees it only if the Terminal listener
  happens to render the tool error, framed as routine. The guard blocked
  *this* attempt, told the *attacker's puppet* about the block — naming
  the flagged kinds, which coaches the retry (`compose_guard.rb:130`) —
  and left the session running, free to retry with linguistic stego,
  which the guard can't catch. Symptom treated, disease in-context.

So every human-facing guard note currently depends on the narrator. That's
the bug class this feature closes.

## What the feature is

A **direct-to-human, out-of-band alert channel**:
`Pikuri::Agent::Event::Alert = Data.define(:text)`, emitted by guard/tool
code, which `Terminal` renders loud (its own marker and color), as chrome
speaking, visually distinct from model output.

**A core variant, not a gem's domain event**, because loudness needs the
listener to recognize the type, and a domain event renders dim. It names
no gem, so it doesn't reopen `D_domain_events`' rejected "grow the sealed
set with each gem's variant". It does amend that entry's "all emitted by
Agent": this is the one core variant gems emit. That line is owed at
graduation.

Its trustworthiness is the mirror of the Confirmer's: **Confirmer = *ask*
the human (sync, blocking, a yes/no gate); this = *tell* the human (async,
one-way, no decision).** The Confirmer already proves chrome can address
the human un-forgeably; this is its non-blocking sibling for notices that
aren't gates (a warning about a draft that *was* handed off; a tripwire on
a draft that was blocked).

Producers on day one: `ComposeGuard`'s novelty, blob and dropped-field
notes, and the injection tripwire (below). **Novelty is the most valuable
of them.** A look-alike recipient domain is exactly what a poisoned agent
wants left unsaid, and the human at the compose window can't tell a new
domain from a known one without the note.

## The injection tripwire — the first producer

### The insight

A `Pikuri::Sanitizer` flag of kind **`:bidi`, `:backspace` or
`:control_bytes`** on **content the LLM authored itself** is a strong
**prompt-injection tripwire**, not a cosmetic display issue. A
normally-functioning model has *no honest reason* to put those bytes in an
email body it wrote, because their whole purpose is to hide meaning from a
human reviewer.

**Not `:zero_width` or `:mixed_script`.** Sanitizer's zero-width set
includes ZWJ (U+200D), which every multi-part emoji uses (👩‍💻), and ZWNJ,
which Persian spelling needs. `:mixed_script` fires on "β-blocker" and
"λ-calculus". Honest bodies carry these, so those two kinds keep today's
fail-close with a plain alert ("the draft was refused; type it in
Thunderbird if you meant it"), without the compromise framing.

The load-bearing distinction is **authored-by-LLM vs relayed-by-LLM.**
The Terminal listener also Sanitizes *tool observations* — but there the
funny bytes are an attacker's, faithfully relayed, and flagging them is
correct display-safety, **not** a poisoning signal. The tripwire is about
bytes in the LLM's *own output*: a body it composed (`ComposeGuard`).
Same primitive, opposite meaning depending on who authored the bytes. Each
call site already knows which it is, so provenance stays at the call site
and `Sanitizer` does not grow a provenance flag.

"Authored" still includes **quoting**: an honest reply that quotes a
hostile message carries its bidi bytes. That is the common false positive
about the agent, and it is still a true positive about the source, which
is what the framing below builds on.

### A graduated response, not auto-teardown

1. **Block the draft** — shipped (`ComposeGuard` fail-close).
2. **Route the signal to the human, loudly**, on the alert channel above
   rather than as a tool-error string the LLM reads. This is the core
   fix: the audience is currently wrong.
3. **Frame it around the source, in plain words.** "The text the
   assistant was writing carries characters made to hide meaning from you.
   Either it was manipulated by something it read (a prompt injection), or
   it is quoting a message that hides something. Either way, that message
   is hostile." This is true whether the agent is a puppet or an honest
   quoter, so a false positive costs almost nothing.
4. **Pre-empt the narrator's spin:** "If the assistant tells you this was
   a false alarm, it cannot know that."
5. **Advise dropping the poisoned context** and **name the likely source**
   ("the message it just read may be hostile — don't act on it"). The
   one-step "start fresh" affordance that would act on the advice is a
   host's UI (the workshop note).

The instinct ("close the harness, it's poisoned") is right in spirit, but
auto-teardown is the wrong default:

- **False positives exist.** The user may have asked the agent to quote /
  relay a message that legitimately carries such bytes. Auto-killing on
  every flag trains dismissal — the exact alarm-fatigue that hollows out
  the whole approver seat.
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
- **Higher confidence than the base64 spotter.** The three tripwire kinds
  have ~zero honest *authored* use, so the tripwire justifies a
  teardown-advice response. A base64 blob
  ({Pikuri::Thunderbird::ComposeGuard#body_blob_note},
  `D_blob_spotter_alphabets`) *does* have honest uses (a pasted
  cert/token), so it gets a plain alert, without the compromise framing.
  Different tier, different words. Don't conflate them.

## Design notes

- **Dual delivery, not either/or.** The LLM still needs a minimal
  observation so it doesn't loop or hallucinate success, but the
  *authoritative human copy* rides the event. The model's copy is a count,
  without content: "Handed to Thunderbird; the user was shown 2 warnings
  directly." For the fail-close, "Refused by the guard; the user was told
  why." It gets **no kinds list**, because today's list coaches the retry.
  The relay instructions (`mail_compose.rb:43`, `OUTBOUND_USAGE`) are
  deleted, since they ask a narrator we've stopped trusting.
- **Defang quoted attacker fragments.** Guard-authored text is trusted (no
  defanging needed), but where a notice *quotes* attacker-controlled data
  (the novel domain, a dropped address) that fragment must go through
  `Pikuri::Sanitizer` — the same reason the Confirmer does. `Terminal`'s
  `Alert` arm defangs the whole text anyway, as its domain-event arm does.
- **Fires even under `--no-confirm` / `AUTO_APPROVE`.** Auto-approve
  silences *gates* (decisions), not *alerts* (information). A session that
  skips confirmations should still get the tripwire alarm. This is the
  concrete payoff of the ask-vs-tell split.
- **Seam:** capability seam (`emit_event`); listeners no-op on unknown
  variants; chrome-agnostic, so a future TUI renders the same event its own
  way. The event is the contract.

### Un-spoofable needs the chrome

"The LLM never authored it" makes the alert impossible to drop *at the
source*, but not on screen. A chrome that prints model prose raw lets the
model erase the alert (`ESC[1A ESC[2K` in its next message) or paint a
fake one. `Terminal` escapes control bytes and bidi overrides in prose as
of 2026-11-21. A richer chrome owes the same. Burying the alert under more
text is still possible (`Q_last_word`).

## Open questions

- `Q_severity` — one variant with a severity field, or distinct variants
  (notice / alarm)? **Lean: neither — one `Alert(text)`.** The bar *is*
  the tier. Anything worth the channel is loud, and everything below stays
  in the observation. The tripwire's alarm differs from a novelty note in
  its words, not its color. The tripwire's would-be `SuspectedInjection`
  fields (flagged kinds, producing tool) go into the text the producer
  composes. Structured fields wait for a chrome that reads them, and the
  workshop's escalate-on-repeat counts its own emissions, so it needs none
  from core.
- `Q_emit_point` — where's the shared emit point? **Lean: there isn't
  one.** `Extension#configure` hands the tool
  `alert: ->(text) { c.emit_event(Agent::Event::Alert.new(text:)) }`, the
  same pattern as `ListChanged`'s `on_change`. The workshop's shell
  producer does the same in its own `configure`. No helper, no mixin.
- `Q_bar` — what earns the channel? **Lean: a deterministic guard verdict
  about *what is about to leave*** (novelty, blob, dropped field,
  tripwire). A note *about the guard itself* doesn't qualify: "couldn't
  check whether you've mailed them before" repeats on every call when the
  index is missing, and fatigue spends the rarity that is the channel's
  whole value. Routine tool chatter doesn't qualify either.
- `Q_last_word` — can't drop ≠ can't bury. The alert lands mid-turn, and
  the model speaks after it, so it can push the alert off screen. (The
  pre-emptive line in the tripwire's text covers the model talking it
  down.) Fixing that needs the chrome to repeat or pin the alert after the
  turn, but `Terminal` can't see a turn end, and pinning in a status bar is
  a TUI's job, so the workshop's. **Lean: accept for v1** in the demo bins.
- `Q_rare_enough` — novelty fires once per new domain. That's rare for a
  secretary that mostly replies to known contacts, but on every draft for
  someone who mails many new people. If it shouts too often, demote
  novelty (never the tripwire) back to the relayed observation. That
  needs no severity field.
