# base64 / encoded-blob spotter — SHIPPED 2026-07-22

Origin: the trifecta dry-run (see [`trifecta-detector.md`](trifecta-detector.md)
§"(b)", [`more-confirmers.md`](more-confirmers.md) §"Egress axis"). Implemented
as `Pikuri::Thunderbird::ComposeGuard#body_blob_note` — commits `085a84f`
(impl + specs), `f00a29c` (doc). Graduated nuggets now live in their durable
homes: the algorithm + full rationale in that method's yardoc; the
residual-channel / threat-model note in `pikuri-thunderbird/DESIGN.md`
(§Compose, "What the body guards do *not* close"). What follows is only what did
**not** graduate.

## Still open

- **Located-note wording.** The shipped phrasing ("Line N onward contains
  encoded-looking content (…, N chars total) — verify…") is a first cut, not a
  studied one. Revisit once it fires on a real compose: how much of the blob to
  quote without the quote itself becoming a skimmable wall.

## Rejected (kept to bound the design — don't retry blindly)

- **Floor < 16, or merge/strip whitespace to beat fine-splitting.** Collapses
  the prose discriminator: stripping whitespace to defeat a space-split turns an
  ordinary sentence containing a number into a 3-class run → FP flood on normal
  mail → alarm fatigue, the one failure the approver-seat can't survive. The
  contiguous-run signal *is* the near-zero-FP property; don't trade it away.
- **Cover hex / base32.** A 2-class rule (hex is `[0-9a-f]`, base32 is
  upper+digit) collides head-on with legit hex — SHA-256 checksums, UUIDs — for
  pure FP cost, on rungs an adaptive attacker already stands on.
