# pikuri-thunderbird — AGENTS.md

Local Thunderbird mail and calendar: read-only inbound tools over the
profile's own stores, plus opt-in outbound tools that hand a draft to Thunderbird's UI for a
human to send. Owns the no-egress posture — nothing here speaks IMAP, SMTP or CalDAV.

## Invariants

- **No egress, no send.** Reads the local profile only (never IMAP/SMTP/CalDAV) through an allowlist of stores, writes nothing to Thunderbird. The inbound tools are the default; the outbound tools are opt-in *human-gated hand-offs to Thunderbird's own UI*, never a send or import by pikuri. **No send tool ever ships.** See {Pikuri::Thunderbird::Extension}, `design/architecture.md`.
- **No attachment ever ships** — mail or `.ics`. A hand-off carries only fields that *render literally*, because the gate's value is that the human sees the exact bytes that leave; the one exception is a reply's threading headers, copied from the mail answered (`design/architecture.md`). Reading an attachment's text (`thunderbird_mail_attachment_read`) is inbound and doesn't touch this.

## Testing against a real Thunderbird

- **The dev VM's packages come first.** Before working on this gem, check that every package in `design/architecture.md` § The testbed is installed (`dpkg-query -W`, `snap list thunderbird`); if one is missing, ask the developer to install it and wait — never work around it with a download or a different server. Exception: `xvfb` and `ffmpeg` serve only `session --display`, so without them say so and carry on headless.
- **Never against a real profile.** Real mail in a session log or a transcript is a leak. On the dev VM, `dev/testbed/build` builds the demo profile (Thunderbird's only, default one, an IMAP account synced from a build-time dovecot) and, through the root's `dev/demo-home/`, `~/Documents`; it refuses while Thunderbird runs or a non-demo profile exists. See `D_thunderbird_testbed`.
- **Live tests run in a session:** `dev/testbed/session start [--display]`, then `session js <file> [args]` (ready scripts in `dev/testbed/js/`), `session screenshot`, `session stop`.
- **Test a hand-off over Marionette first** — headless, no Xvfb: `session js dev/testbed/js/handoff.js <command line>` runs it through Thunderbird's own handler, then `compose-windows.js` / `outgoing-mime.js` read what it opened. Only pikuri's own launch needs `--display`, with the agent's side setting its `DISPLAY`. How it all works: `design/architecture.md` § The testbed.

Maintenance: the root `AGENTS.md`'s rules.
