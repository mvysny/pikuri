# base64 / encoded-blob spotter for outbound mail bodies

Status: **idea, not built — design converged.** A defense-in-depth
addition to `Pikuri::Thunderbird::ComposeGuard`; the algorithm below is
settled, only the note wording is genuinely open. Spun out of the
trifecta dry-run — see [`trifecta-detector.md`](trifecta-detector.md)
§"(b)" (the graded egress axis + the "scanners bound, don't close"
analysis) and [`more-confirmers.md`](more-confirmers.md) §"Egress axis."

## What

A body check that flags an agent-composed outbound mail body carrying a
**machine-encoded blob** — enough base64-alphabet, high-charset-diversity
material to read as encoded bytes rather than prose — and surfaces it as
a loud, *located* human-facing note. Soft warn, never fail-closed.

## Why (the residual it targets)

The trifecta dry-run established the surviving exfil channel for
pikuri-computer's Thunderbird compose (an `egress_human_approver` seat).
The already-shipped guards close a lot:

- `ComposeGuard` fail-closes the body on any `Sanitizer` warning
  (control bytes / bidi / zero-width / mixed-script homoglyph) — so
  *machine-invisible* stego is blocked, not just flagged.
- addresses are hard-dropped if non-ASCII or punycode; a novel recipient
  *domain* earns a soft warn.

What's left as the easiest **high-bandwidth** exfil is the dumbest one:
a base64 dump of a key/secret pasted straight into the plaintext body.
It's all-ASCII and printable, so it sails through the fail-closed
`Sanitizer` gate, and the human skims past a wall of gibberish.

## Scope: a paste guard, not an exfil control

Be honest about what this is. The threat model is a prompt-injected LLM,
and **the injection that says "base64 the SSH key and mail it" can add
"…split it with spaces and sprinkle it between words" at zero marginal
cost** — any evasion is one more clause in the same payload. So this does
*not* meaningfully raise the bar against an **adaptive** attacker.

What it *does* catch:

- the lazy, **unwrapped** dump from a *non-adaptive* attacker — real
  today, but with a half-life: it ends at the first published pikuri
  bypass, after which the copied payload includes the evasion for free;
- the **benign human paste** — a cert, an API key, a token to a
  colleague, forgotten in a draft. This is a UX attention aid, not a
  security mechanism.

Design consequence: **it must be documented as skim-defeat for
benign/lazy content, explicitly de-scoped from the exfil threat model.**
Sold as "closes the base64 exfil channel" it would *lull* — the very
failure the approver-seat rests on. A control an attacker disables with
one sentence but that reads like a defense is worse than none, because it
spends the reader's trust.

Why we can afford the conservatism this implies (**err toward not
warning**): outbound mail is human-gated (a Thunderbird compose window,
never an autonomous send) and humans treat *send* as irreversible —
"once it's sent, it's sent." That diligence is the real backstop; the
spotter is defense-in-depth on top of a careful human. A missed blob is
caught by the reviewer; a false alarm spends the attention that reviewer
runs on. So miss quietly rather than cry wolf.

## Algorithm (settled)

Over the plaintext body:

1. **Pre-filter** each whitespace-delimited token: drop any containing
   `://`, `@`, `/`, or `%` — URLs, emails, paths, percent-encoding gone
   before they can trip anything.
2. **Admit** a token iff `length >= 16` AND it contains all three of
   `[A-Z]`, `[a-z]`, `[0-9]`.
3. **Join** all admitted tokens (sum their lengths — no decode).
4. **Warn** iff the joined length `>= 32`.

The **three-class test** is the word-vs-blob discriminator: a natural
word is one class (all lowercase), a Capitalized word or acronym two
(`ISO8601`, `Antidisestablish`), random base64 three — the
mixed-case-plus-digit churn only an encoder produces. It rejects every
prose word, SHOUTING acronym, lowercase-digit slug (`invoice20260722`),
and pure-digit ID at any length. `sophistication` (1 class) never trips
it; `aGVc3Bhd4Xk2m` does.

Two subtleties that close the wrapping evasions the earlier rungs left
open:

- **The join defeats space-split AND innocent-word-interleave for free.**
  Because only 3-class tokens are admitted, cover words fail the gate and
  are skipped automatically — `the aGV… quick asd… brown` collapses to
  just the payload chunks. No de-interleave logic; the filter *is* the
  de-interleaver. The same mechanism folds space-split chunks back
  together.
- **Floor 16, not 10 — an alarm-fatigue decision, not a detection one.**
  The join loses locality (it sums tokens from anywhere in the body), so
  every admitted token must be rare in honest mail. At 16 a 3-class token
  is essentially always a pasted secret (on-scope to flag anyway). At 10
  you admit ordinary engineering tokens and the global sum cries wolf on
  a normal dev email — `commit abc123Def456 broke build 7Gh8Ij9Kl0 on
  runner X2y3Z4a5b6` → ~33 → false warn. And the missing-digit
  false-negative rate `(54/64)^n` is ~18% at n=10 but ~1.7% at 16 and
  ~0.4% at 32, so the low floor barely helps detection while it wrecks
  the FP rate.

Threshold rationale: a 32-byte key → 44 base64 chars, comfortably over
32. A lone 16-byte secret (24 chars) slips under — accepted (small, and a
24-char blob is short enough to see). Drop the *join* threshold to 24 to
catch it, at the cost of firing when two 16-char keys coexist.

## Placement & tier

- **`ComposeGuard`, NOT `Pikuri::Sanitizer`.** The Sanitizer is
  deliberately deterministic over *finite codepoint classes* with
  near-zero false positives (its own rdoc: "complete on the classes
  above, not exhaustive"). A composition/length heuristic is a different
  animal — statistical, genuinely FP-prone — and folding it in would
  wreck the Sanitizer's "the bytes you approve are the bytes that run"
  guarantee. It belongs beside the novelty check, as `ComposeGuard`'s own
  content policy.
- **Soft warn (keep-in-draft + located note), never fail-closed.** Legit
  base64 in human mail is rare but real. Implementation is small: the
  `notes` array is *already* the soft-warn channel and the body already
  passes through after the Sanitizer gate, so the addition is one
  `body_blob_note(body, notes)` call beside `novelty_note` in `#check` —
  no `Verdict` change, no binary→ternary refactor. (An earlier draft
  worried this needed a new "middle tier"; it overstated the work.)
- **Locate and quote, don't banner.** The note names where and quotes the
  head — `⚠ line 4 contains a 44-char encoded blob: aGVsbG8gd29ybGQ… —
  verify you meant to send this.` Directed attention is both more useful
  and the antidote to alarm fatigue: a specific, quoted note earns a
  look; a generic "this may contain encoded content" banner trains the
  human to click past — which would *cause* the fatigue we fear.

## Clear-eyed limits (why this is a rung, not a fix)

- **Space / word interleaving is a free evasion.** Splitting the blob
  with spaces or between innocent words is one clause in the injection
  payload (see Scope). The join handles chunks ≥16; **sub-16
  fine-splitting walks under** — and that's accepted: below ~16 the
  3-class filter itself gets flaky (a short chunk often lacks a digit and
  is dropped), so the reach isn't there anyway, and a body littered with
  tiny gibberish groups is *visually louder* to a human skim. To hide
  that, the attacker needs a coherent cover text = linguistic stego.
- **Linguistic steganography is the bottom rung and defeats everything.**
  The acrostic "I think dogs are super cute" → `itdasc`. Unsolvable by
  any cheap heuristic; conceded.
- **Orthogonal to the recipient bypass.** The sharpest surviving channel
  isn't the encoding — it's *reply-to-injector*: the injecting email's
  From-domain is already in Gloda's `identities` graph (which counts
  received mail, both directions — verified), so replying to the attacker
  draws **no** novelty warning. A body spotter does nothing about that.
- **base64 / mixed-case only; skip hex and base32.** The 3-class
  signature is encoding-variant-independent for the mixed-case encodings,
  but hex (`[0-9a-f]`, 2-class) and base32 (upper+digit, 2-class) don't
  trip it. Covering them means a *2-class* rule, which collides head-on
  with legit hex (SHA-256 checksums, UUIDs) and pure-uppercase content —
  pure FP cost for rungs a base32/hex-capable attacker already stands on.
  Not worth it.

## Open questions

Resolved this session (kept as the reasoning trail):

- ~~Minimum length / entropy threshold?~~ → floor-16 + 3-class per token,
  global join, warn at joined ≥32. No entropy math — the structural
  3-class rule is the discriminator and stays near-deterministic.
- ~~Cover hex and base32?~~ → no; a 2-class rule is all FP.
- ~~Worth building at all?~~ → yes, but *only* as a benign-paste /
  skim-defeat aid, documented as such and de-scoped from the exfil threat
  model. Security value against an adaptive attacker is ~nil and
  time-limited; value to the honest user (and against copy-pasted
  non-adaptive attacks) is real and cheap (~15 lines + specs).

Genuinely still open:

- Exact located-note wording, and how much of the blob to quote (head
  only? first N chars?) so the quote itself doesn't become a skimmable
  wall — the one detail that decides whether the note earns a look or
  trains a dismiss.
