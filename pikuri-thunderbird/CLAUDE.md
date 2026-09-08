# pikuri-thunderbird — CLAUDE.md

This gem's must-not-break list, loaded beside the root `../CLAUDE.md`
when work touches this directory. One-line invariants + pointers only;
the truth lives in the cited yardoc, threat model + storage measurements
in `DESIGN.md`, roads not taken in `../DECISIONS.md`.

## Seams (invariants)

- **No egress, no send.** Reads the local profile only (never IMAP/SMTP/CalDAV) through an allowlist of stores, writes nothing to Thunderbird. The inbound tools are the default; the two outbound tools are opt-in *human-gated hand-offs to Thunderbird's own UI*, never a send or import by pikuri. **No send tool ever ships.** See {Pikuri::Thunderbird::Extension}, `DESIGN.md`.
- **No attachment ever ships** — mail or `.ics`. A hand-off carries only fields that *render literally*, because the gate's value is that the human sees the exact bytes that leave. `T_thunderbird_no_attachment`.
