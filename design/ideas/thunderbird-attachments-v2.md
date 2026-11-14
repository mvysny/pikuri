# Thunderbird attachments: what v1 left out

`thunderbird_mail_attachment_read` reads an attachment's text (v1, see
`pikuri-thunderbird/design/architecture.md`). What it still can't do, each
answered with a message saying so; build one only when it is asked for. Images have
their own idea: `thunderbird-attachment-images.md`.

## Forwarded mails: their own attachments

A forward now reads as its headers, attachment list and text
(`Pikuri::Thunderbird::ForwardedMail`, 2026-11-14). Its attachments are only
*listed* ("open them in Thunderbird"), and that is the remaining gap: Gloda's
FTS `c2attachmentNames` carries the names inside a forward, so searching "CV"
finds `application-fwd`, and the CV can then be seen but not read.

Next step: number the forward's list and take a path handle,
`attachment: "1.2"` (forward 1, its attachment 2); the parameter becomes a
string, `"3"` still works. The walk then descends by path, so forwards of
forwards come free.

- `Q_fwd_handle` — string path (`"1.2"`) vs a second integer param
  (`attachment: 1, inner: 2`)? The path generalises to any depth and is one
  param; the integer pair is the more obvious schema for a small model. Lean:
  path, with an example value in the parameter description.
- `Q_fwd_listing_policy` — `ForwardedMail` mimics Gloda's rule (body = what
  sits under `alternative` / `related`, plus unnamed text/plain and text/html
  leaves), verified against the testbed and a synthetic spec, never against a
  real Outlook / Apple Mail forward. Check on the real box before numbering,
  since the numbers become handles.
- `Q_fwd_testbed` — the testbed has one forward, carrying one `.docx`. Add a
  forward carrying an image, a forward of an HTML mail with a `cid:` image
  (pins the listing policy end to end), and a forward of a forward (pins the
  recursion).

## Maildir and other stores

`MessageStore` raises on a non-`berkeleystore` server. Maildir is one file per
message under `<folder>/cur/`.

**What the testbed showed:** `storeContractID = …/maildirstore;1` on the POP
account in `user.js`, plus one file per message in `Inbox/cur/` instead of the
mbox, and the builder's existing reparse + `indexFolder` indexed all 187
messages (7.7 s). Thunderbird kept our file names, created no `tmp/` / `new/`,
and `messageKey` became a small sequence number. The current refusal fired as
designed. A prototype — read each file's header block (up to the first blank
line), match the same `Message-ID:` regex `scan` uses — found the invoice mail
in ~1 ms over 177 files, and the PDF extracted.

- `Q_maildir_lookup` — header scan per file (simple, O(folder) opens) vs the
  `.msf` `storeToken` (exact, but means reading Mork). Lean: scan; a 50k-file
  folder is ~50k small reads, measure on the testbed with noise turned up
  before reaching for Mork.
- `Q_maildir_testbed` — how the testbed keeps covering it. A build flag
  (`--maildir`) tests it only when someone remembers. Making **Local Folders**
  maildir and filing a few scene messages there (an `Archive` folder) covers
  both stores on every build without a second identity. Lean: Local Folders,
  if Gloda indexes it (check).
- `MessageStore` would pick the store per server: the mbox scan as today, the
  maildir scan as a sibling method — no store-strategy class until a third
  store exists.

Folder names with filesystem-illegal characters get hashed by Thunderbird
(`NS_MsgHashIfNecessary`); unhandled until a real folder hits it.

## Smaller ones

- **Extraction timeout (`Q_extract_timeout`).** None today: Ruby's `Timeout`
  is unsafe around native code, pikuri-pdf parses pages lazily, and the 40 MB
  message cap bounds the input. Revisit if a hostile PDF ever hangs a turn.
- **Paging the body.** `thunderbird_mail_read` still hard-truncates a body at
  40 KB; it could take `offset`/`limit` and answer through
  `Tool::Result.page` like the attachment reader does. The testbed's longest
  body is 487 bytes, so it needs one long scene before this is testable.
