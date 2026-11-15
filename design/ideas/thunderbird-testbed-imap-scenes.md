# IMAP-only scenes in the Thunderbird testbed

Status: **not built.** The testbed's account is IMAP now (`pikuri-thunderbird/design/architecture.md`
§ The testbed), but its mail is the same shape a POP3 mailbox has. IMAP brings shapes of its own
that pikuri handles and only the owner's install exercises:

- **One message in two folders** → N Gloda rows, which `Gloda::Mail` dedups. Gmail's labels do
  this; dovecot can by serving a copy in a second folder. Changes the builder's done-count: N
  rows, not N messages.
- **A folder synced headers-only** (its Offline flag cleared). Measured (2026-11-15, see the
  Coverage note in `architecture.md` § Mail: mbox on disk): Gloda indexes such a message from
  headers alone — `c0body` NULL, no `attachmentInfos` — so `thunderbird_mail_read` shows an
  empty body and "Attachments: (none)" for a mail that has some. That is a quiet gap in pikuri,
  not a testbed problem. `Q_headers_only_marker`: is `c0body IS NULL` a reliable "body not
  offline" marker? All 194 offline testbed messages had it non-NULL, all 14 headers-only ones
  NULL; an offline message with no text part at all is the case to check. If it holds,
  `mail_read` could say "the body isn't stored on this computer; open it in Thunderbird", and
  this scene would be its test. The scene itself also breaks the builder's done-count, which
  counts only messages with a body.
- **"Not stored on this computer"** (`MessageStore` answering `nil`) needs a copy gone from the
  offline store after Gloda indexed it with a body. No Thunderbird action that does this is
  known yet; without one, the answer stays covered by specs alone.
- **A second account on the same host** → the `-1` store directory (`ImapMail/127.0.0.1-1/`),
  which `MessageStore` maps through `prefs.js`. A second dovecot user is enough.

Not reachable with dovecot: Gmail's own behaviour (`X-GM-EXT-1`, `[Gmail]/All Mail`).
