# IMAP-only scenes in the Thunderbird testbed

Status: **not built.** The testbed's account is IMAP now (`pikuri-thunderbird/design/architecture.md`
§ The testbed), but its mail is the same shape a POP3 mailbox has. IMAP brings shapes of its own
that pikuri handles and only the owner's install exercises:

- **One message in two folders** → N Gloda rows, which `Gloda::Mail` dedups. Gmail's labels do
  this; dovecot can by serving a copy in a second folder. Changes the builder's done-count: N
  rows, not N messages.
- **A folder synced headers-only** (its Offline flag cleared) → the "not stored on this
  computer" answer. `Q_headers_only_gloda`: Gloda indexes such a message from headers alone, so
  does it list its attachments at all? If not, the answer is reachable only through a message
  whose body was offline when indexed and left since (an age-limited autosync), which is harder
  to stage.
- **A second account on the same host** → the `-1` store directory (`ImapMail/127.0.0.1-1/`),
  which `MessageStore` maps through `prefs.js`. A second dovecot user is enough.

Not reachable with dovecot: Gmail's own behaviour (`X-GM-EXT-1`, `[Gmail]/All Mail`).
