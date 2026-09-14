# pikuri-thunderbird — AGENTS.md

Local Thunderbird mail and calendar: read-only inbound tools over the
profile's own stores, plus two opt-in outbound tools that hand a draft to Thunderbird's UI for a
human to send. Owns the no-egress posture — nothing here speaks IMAP, SMTP or CalDAV.

## Invariants

- **No egress, no send.** Reads the local profile only (never IMAP/SMTP/CalDAV) through an allowlist of stores, writes nothing to Thunderbird. The inbound tools are the default; the two outbound tools are opt-in *human-gated hand-offs to Thunderbird's own UI*, never a send or import by pikuri. **No send tool ever ships.** See {Pikuri::Thunderbird::Extension}, `design/architecture.md`.
- **No attachment ever ships** — mail or `.ics`. A hand-off carries only fields that *render literally*, because the gate's value is that the human sees the exact bytes that leave.

Maintenance: the root `AGENTS.md`'s rules; cap 10 KB.
