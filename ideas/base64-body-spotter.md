# base64 / encoded-blob spotter for outbound mail bodies

Status: **idea, not built.** A small defense-in-depth addition to
`Pikuri::Thunderbird::ComposeGuard`. Spun out of the trifecta dry-run —
see [`trifecta-detector.md`](trifecta-detector.md) §"(b)" (the graded
egress axis + the "scanners bound, don't close" analysis) and
[`more-confirmers.md`](more-confirmers.md) §"Egress axis."

## What

A body check that flags a **machine-encoded blob** — a long contiguous
run from a base64 / base32 / hex alphabet with high charset entropy and
low natural-language likelihood — in an agent-composed outbound mail
body, and surfaces it as a loud human-facing note.

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
`Sanitizer` gate, and the human skims past a wall of gibberish. A spotter
forces the attacker off base64 — exactly the "patient approval forces the
attacker down the ladder" bar-raising the note describes.

## Design notes

- **Placement: `ComposeGuard`, NOT `Pikuri::Sanitizer`.** The Sanitizer
  is deliberately deterministic over *finite codepoint classes* with
  near-zero false positives (its own rdoc: "complete on the classes
  above, not exhaustive"). An entropy/encoding heuristic is a different
  animal — statistical, genuinely FP-prone — and folding it in would
  wreck the Sanitizer's "the bytes you approve are the bytes that run"
  guarantee. It belongs beside the novelty check, as `ComposeGuard`'s own
  content policy.
- **Tier: soft warn (keep-in-draft + note), NOT fail-closed.** Legit
  base64 in a human-to-human mail is rare but real (a pasted cert, a
  token to a colleague). Fail-closing would break that; a loud note
  ("this body contains a machine-encoded blob — verify it's something you
  meant to send") preserves the use case while raising attention. NB:
  `ComposeGuard`'s body handling is currently *binary* (clean → keep,
  any warning → fail-closed) — this needs a new middle "keep with body
  note" tier.

## Clear-eyed limits (why this is a rung, not a fix)

- **Trivially evaded.** base32 / hex / decimal / spelled-out
  ("four one two…") / and ultimately **linguistic steganography** (the
  acrostic "I think dogs are super cute" → `itdasc`) all walk under it.
  This closes exactly one rung of the ladder.
- **Orthogonal to the recipient bypass.** The sharpest surviving channel
  isn't the encoding — it's *reply-to-injector*: the injecting email's
  From-domain is already in Gloda's `identities` graph (which counts
  received mail, both directions — verified), so replying to the attacker
  draws **no** novelty warning. A body spotter does nothing about that.
- **Alarm fatigue.** Too eager a threshold flags UUIDs, git SHAs, URLs
  with long query strings → the human learns to ignore the note, which is
  the very failure mode the whole approver-seat rests on.

## Open questions

- Minimum run length / entropy threshold that catches a 32-byte key dump
  without flagging a URL or a UUID? (URLs/emails should be excluded
  first.)
- Cover hex and base32, or base64 only? (Diminishing returns vs. FP cost.)
- Is one more evadable rung worth the code + the FP risk at all, given the
  residual (reply-to-injector + linguistic stego) stays open regardless?
  The honest case *for*: attention-raising on the laziest attack is cheap
  insurance, and the laziest attack is the likeliest. The case *against*:
  every rung that isn't the top rung can lull.
