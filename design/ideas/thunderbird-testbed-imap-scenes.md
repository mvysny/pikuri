# IMAP-only scenes in the Thunderbird testbed

Status: **1 and 2 built** (`pikuri-thunderbird/design/architecture.md` § The testbed); **3 and 4 not.** The testbed's account is IMAP now
(`pikuri-thunderbird/design/architecture.md` § The testbed), but its mail is the same shape a
POP3 mailbox has. IMAP brings shapes of its own that pikuri handles and only the owner's install
(or a one-off probe) exercises. All four can be staged with the build-time dovecot:

1. **One message in two folders** → N Gloda rows, which `Gloda::Mail` dedups, and whose read
   prefers the copy whose body was downloaded. Gmail's labels do this; dovecot does it when the
   builder writes the same bytes into two Maildir folders (a `mail.yml` scene listing two
   `folder:`s). The builder's done-count becomes copies, not messages.
2. **A folder synced headers-only** (its Offline flag cleared) → `thunderbird_mail_read` saying
   the body isn't downloaded and naming the setting. Gmail's shape: `[Gmail]/All Mail`, served
   by dovecot with the `/` separator and `special_use = \All`, never marked for offline use.
   One folder serves both scenes: a message in INBOX and All Mail (the read prefers INBOX's
   body), a message only in All Mail (archived; headers only), and with `[Gmail]/Starred`
   beside it the nested bracketed path `[Gmail].sbd/Starred` for `MessageStore`'s URI mapping
   (All Mail itself has no mbox). The done-count splits in two: rows,
   and rows with a body; else the build waits forever for bodies that never come.
3. **"Not stored on this computer"** (`MessageStore` answering `nil`) needs a copy gone from the
   offline store after Gloda indexed it with a body. Probe first, best candidate first:
   - `folder.msgStore.deleteMessages([hdr])` over Marionette after the index: for mbox it
     should set the expunged bit in `X-Mozilla-Status` (which `MessageStore#expunged?` reads as
     gone) without the folder notifications Gloda listens to, so Gloda's row stays.
   - Retention's "delete bodies older than N days" (`cleanupBodiesByDays`), if IMAP honours it;
     it may be news-only.

   Hand-editing the mbox is out: the builder writes inputs, Thunderbird writes its stores. With
   neither probe working, the answer stays covered by specs alone.
4. **A second account on the same host** → the `-1` store directory (`ImapMail/127.0.0.1-1/`),
   which `MessageStore` maps through `prefs.js`. Dovecot's static passdb already accepts any
   login, but every login shares one Maildir; a per-user `mail_path` (`%{user}`) and a second
   account in `user.js` on the same `127.0.0.1:10143` do it. A second "me" identity in Gloda
   comes along, as on real installs.

Not reachable with dovecot: Gmail's own extension, `X-GM-EXT-1`. Advertising it
(`imap_capability`) would make Thunderbird fetch `X-GM-MSGID`/`X-GM-LABELS`, which dovecot
answers with BAD; so Thunderbird's Gmail-only paths (sharing one offline body across labels)
stay untested.
