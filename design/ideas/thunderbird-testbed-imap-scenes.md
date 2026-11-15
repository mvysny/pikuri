# IMAP-only scenes in the Thunderbird testbed

Status: **not built.** The testbed's account is IMAP now (`pikuri-thunderbird/design/architecture.md`
§ The testbed), but its mail is the same shape a POP3 mailbox has. IMAP brings shapes of its own
that pikuri handles and only the owner's install (or a one-off probe) exercises:

- **One message in two folders** → N Gloda rows, which `Gloda::Mail` dedups, and whose read
  prefers the copy whose body was downloaded. Gmail's labels do this; dovecot can by serving a
  copy in a second folder. Changes the builder's done-count: N rows, not N messages.
- **A folder synced headers-only** (its Offline flag cleared) → `thunderbird_mail_read` saying
  the body isn't downloaded and naming the setting. Probed by hand on 2026-11-15, not staged by
  the build: the builder's done-count counts only messages with a body, and would wait forever.
  Staging it needs that count split (rows, and rows with a body).
- **"Not stored on this computer"** (`MessageStore` answering `nil`) needs a copy gone from the
  offline store after Gloda indexed it with a body. No Thunderbird action that does this is
  known yet; without one, the answer stays covered by specs alone.
- **A second account on the same host** → the `-1` store directory (`ImapMail/127.0.0.1-1/`),
  which `MessageStore` maps through `prefs.js`. A second dovecot user is enough.

Not reachable with dovecot: Gmail's own behaviour (`X-GM-EXT-1`, `[Gmail]/All Mail`).
