# pikuri-thunderbird — AGENTS.md

Local Thunderbird mail and calendar: read-only inbound tools over the
profile's own stores, plus two opt-in outbound tools that hand a draft to Thunderbird's UI for a
human to send. Owns the no-egress posture — nothing here speaks IMAP, SMTP or CalDAV.

## Invariants

- **No egress, no send.** Reads the local profile only (never IMAP/SMTP/CalDAV) through an allowlist of stores, writes nothing to Thunderbird. The inbound tools are the default; the two outbound tools are opt-in *human-gated hand-offs to Thunderbird's own UI*, never a send or import by pikuri. **No send tool ever ships.** See {Pikuri::Thunderbird::Extension}, `design/architecture.md`.
- **No attachment ever ships** — mail or `.ics`. A hand-off carries only fields that *render literally*, because the gate's value is that the human sees the exact bytes that leave. Reading an attachment's text (`thunderbird_mail_attachment_read`) is inbound and doesn't touch this.

## Testing against a real Thunderbird

- **Never against a real profile.** Real mail in a session log or a transcript is a leak. On the dev VM (its packages: `design/architecture.md` § The testbed), `dev/testbed/build` builds the demo profile (Thunderbird's only, default one, an IMAP account synced from a build-time dovecot) and, through the root's `dev/demo-home/`, `~/Documents`; it refuses while Thunderbird runs or a non-demo profile exists. See `D_thunderbird_testbed`.
- **Live tests run in a session:** `dev/testbed/session start [--display]`, then `session js <file>` (ready scripts in `dev/testbed/js/`), `session screenshot`, `session stop`. A hand-off reaches a `--display` session when the agent's side sets its `DISPLAY`. How it all works: `design/architecture.md` § The testbed.

Maintenance: the root `AGENTS.md`'s rules.
