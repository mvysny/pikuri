# Reading Thunderbird mail attachments

Status: **brainstorm, nothing built.** Spun off from
[`thunderbird.md`](thunderbird.md)'s last deferred bullet (".msf / maildir /
mbox fallbacks … would also unlock attachment *bodies*").

## The gap

`thunderbird_mail_read` lists attachment *names* (Gloda's `c2attachmentNames`)
and its description says outright "attachment contents are not opened". So "what
does the invoice from Acme say?" dead-ends at `invoice.pdf` when the answer is
in the PDF. The model needs a tool that opens one attachment and returns its
text, through the same `Pikuri::Extractor` registry `read` uses, so pikuri-pdf
or pikuri-extractors (whichever the host registered) does the format work.

## The hard part: Gloda never had the bytes

Gloda gives decoded body text and attachment *names*, nothing else. The bytes
exist only in Thunderbird's **offline message store**: an mbox per folder under
`ImapMail/<server>/` (IMAP) and `Mail/` (Local Folders), or one file per message
with the maildir store. So this feature is mostly **"locate one message's raw
RFC 822 bytes on disk"**, then a MIME walk, then an Extractor call. That makes
it the first pikuri-thunderbird code to read outside the two SQLite stores, so
it **widens the read allowlist** (`pikuri-thunderbird/design/architecture.md`
§ "Files never touched"). That is a deliberate seam change and gets recorded
there at graduation.

What the architecture doc already pinned down about mbox (§ "Mail: mbox on
disk"): CRLF; a `From - <ctime>` separator; server-defined folder names; the
`X-Mozilla-Status` deleted-but-not-compacted bit; and **`messageKey` is the
IMAP UID under `ImapMail/`, a byte offset only under local `Mail/`**. That last
fact is why a general Gloda→mbox seek was rejected for *reading bodies*. Bodies
didn't need it then (Gloda has them); attachments do need it now.

### Locating the message (`Q_locate`)

The Gloda row we already fetch gives `folderID → folderLocations.folderURI` plus
`messageKey` and `headerMessageID`. From there:

- **Folder URI → store path.** `imap://user@imap.gmail.com/INBOX/Sub` maps to
  `ImapMail/<serverdir>/INBOX.sbd/Sub`. `<serverdir>` is usually the hostname,
  but a second account on the same host gets `imap.gmail-1.com`, and only
  `prefs.js` (`mail.server.serverN.directory-rel` / `.hostname` / `.userName`)
  says which account owns which directory. Reading `prefs.js` is a second
  allowlist entry. It is a `user_pref("k", v);` line file (no passwords, which
  live in `logins.json`), parsed with one regex. **Lean:** read `prefs.js` and
  fail loud when it doesn't resolve, rather than guess between `-1` siblings.
  Folder names with filesystem-illegal characters get hashed by Thunderbird
  (`NS_MsgHashIfNecessary`). Defer that until a real folder hits it.
- **Within the folder:**
  - *Local `Mail/` mbox:* `messageKey` is the offset. Seek there, check that a
    `From - ` line starts there and that the `Message-ID:` matches, and read up
    to the next separator.
  - *IMAP mbox:* the offset (`storeToken`) is only in the `.msf` Mork summary.
    Parsing Mork is the gnarly road. **Lean:** a linear scan of the folder's
    mbox for the `Message-ID:` header. It is grep speed, and Gmail's
    `[Gmail]/All Mail` is the worst case at a few GB. Skip rows whose
    `X-Mozilla-Status` has the expunged bit set. Add a per-folder
    `Message-ID → offset` memo, invalidated by size+mtime the way the FTS
    rebuild is, only if the scan proves slow in practice.
  - *Maildir:* one file per message under `cur/`. Scan the headers for the
    Message-ID, or use the `storeToken` filename if we ever read `.msf`.
  - *Gmail label fan-out:* the same Message-ID sits in several folders. Any
    copy works, so try the row's own folder first, then the other Gloda rows
    for that `headerMessageID`.
- **Not stored offline.** This happens when the account has "Keep messages on
  this computer" off, or the size limit or sync hasn't run, or the message was
  compacted away since Gloda indexed it. Answer
  `Tool::Result.error("this message isn't stored on this computer — open it in
  Thunderbird")`. **Never fetch it over IMAP**: the no-egress seam forbids it,
  and it's the one shortcut someone will be tempted to take.

**Consistency without a snapshot.** The SQLite snapshot dance exists because of
`locking_mode=EXCLUSIVE`. An mbox has no such lock, and copying a multi-GB file
per read is absurd. Two Thunderbird writes could still race the read. An append
doesn't disturb earlier bytes. Compaction writes a new file and renames it over
the old one. So **open the mbox once, then scan and read from that one fd**: the
inode it holds stays self-consistent. A message appended right now isn't in
Gloda yet anyway. This needs one line in the architecture doc saying why the
mbox read is safe live.

### Gloda may already know the MIME parts (`Q_gloda_attachment_infos`)

From memory of comm-central, not verified: Gloda's fundamental attributes include
`attachmentInfos`. Each entry is a serialized `GlodaAttachment`
(`name, contentType, size, part, externalUrl, isExternal`), stored in
`messages.jsonAttributes` under that attribute's id from
`attributeDefinitions`. If a live profile confirms it:

- `thunderbird_mail_read` can list `invoice.pdf (application/pdf, 84 kB)` with
  no mbox access. That alone is a cheap, separate improvement.
- The **MIME part number** (`1.2`) addresses the attachment exactly in the MIME
  tree, so there is no name matching during the walk.
- `isExternal` (a detached / "deleted attachment" stub) can be refused up front.

**To verify:** dump `attributeDefinitions` and one `jsonAttributes` of a
message with a PDF on the real box. The findings go to the architecture doc's
storage section, next to the attribute ids 57–61 already recorded there.

### MIME parsing (`Q_mime_parser`)

The input is attacker-controlled by definition, and MIME is notoriously gnarly:
nested multiparts, RFC 2231 / encoded-word filenames, base64 vs
quoted-printable, `message/rfc822` forwards, broken boundaries.

- **Hand-rolled walker.** Stdlib does the decoding (`unpack1('m')` /
  `unpack1('M')`), so the walker is roughly 100 lines and stays "readable in an
  evening". But every edge case becomes ours, on adversarial input.
- **The `mail` gem.** It is the de-facto Ruby MIME library (ActionMailbox sits
  on it), well-known and widely used, which fits the "popular dependency is OK"
  rule. It is heavy for one call site, and pikuri-thunderbird currently depends
  only on `sqlite3`.

**Lean: the `mail` gem**, for parse-only use (`Mail.read_from_string`, walk
`#attachments` / `#parts`, `#decoded`). A parser bug on hostile input is
exactly where an evening's code loses. Revisit if its load time or footprint
bites.

## The tool

**Shape:** like `read` / `fileindex_read`, a line-paged cat-n window over
`Pikuri::Extractor.extract_paged(StringIO.new(bytes), content_type:)`. The MIME
part's `Content-Type` is the `content_type:` hint, and the registry still
sniffs, so a PDF mislabelled `application/octet-stream` still gets claimed by
pikuri-pdf's `%PDF-` check.

```
thunderbird_mail_attachment_read(message_id:, attachment:, offset: 1, limit: 2000)
```

- **Name** (`Q_tool_name`): the `thunderbird_mail_*` family plus a verb, as
  `thunderbird_mail_attachment_read`. The alternative is to fold it into
  `thunderbird_mail_read` as an optional `attachment:` param. The body would
  then gain `offset`/`limit` for free, fixing today's hard 40 KB truncation, but
  the existing tool's output and description would change, and one tool would do
  two jobs. **Lean: a separate tool.** A crisp name and description serve a small
  local model better. `thunderbird_mail_read`'s output then says which tool and
  handle open an attachment, the way it already names `thunderbird_mail_search`.
- **Attachment handle** (`Q_attachment_handle`). Names collide (two
  `image001.png`), contain anything, and come from the sender. Options:
  1-based index as listed by `thunderbird_mail_read`; exact filename; MIME part
  number. **Lean:** the listing numbers them (`1. invoice.pdf …`) and the param
  takes that **index**. That is unambiguous and short, and the model copies it
  from the listing. This only holds if the listing and the reader enumerate the
  *same* list in the *same* order, so both must come from one source: Gloda's
  `attachmentInfos` if `Q_gloda_attachment_infos` holds, or the MIME walk if
  not (and then `thunderbird_mail_read` also has to touch the mbox, which I'd
  rather avoid). A wrong index gets an error listing the attachments, the
  `directory_refusal` move, so the model recovers in one step.
- **Display line.** The summary is `"Read 120 lines of a PDF attachment"`, never
  the filename, for the same reason `MailRead` reports a size and not the
  subject: the name is whatever the sender wrote.
- **Trifecta legs:** `INBOUND_LEGS`, the same as `thunderbird_mail_read`.
  Attachment text is leg 2 just like the body, and no new leg is added. The
  mail `SURFACE_USAGE` paragraph's untrusted-content clause should mention
  attachments in so many words.
- **Wiring:** part of the `:mail` surface, registered whenever mail is. A
  message that isn't stored offline answers it per call (the calendar's
  self-explaining-empty-state precedent), so we don't need a whole-store
  `available?` probe.
- **Sharing:** `P_shared_locked` if it goes through the `Gloda` backend for the
  row lookup, as `MailRead` does. The mbox read itself is stateless.

### What it reads

- **Anything the Extractor registry claims:** PDF (pikuri-pdf *or*
  pikuri-extractors), office/EPUB/RTF (pikuri-extractors), HTML and plain text
  (core). The thunderbird gem takes **no** dependency on either PDF gem, since
  the registry is in core. An unregistered format answers
  `Extractor::Unsupported` → `"no reader for application/pdf on this host"`.
  `bin/pikuri-thunderbird` should then require one PDF arm. Check what it loads
  today.
- **Images** (`Q_images`): `read` attaches PNG/JPEG/GIF/WebP as a
  `RubyLLM::Attachment`, but it needs a file path, so we'd stage the decoded bytes
  under `Paths.new_temp`. **Lean: v2.** The text formats are the asked-for case,
  and staging is a decision of its own (see the privacy caveat below).
- **`message/rfc822`** (a forwarded mail as an attachment): render it as
  headers + text body via the same MIME walk. Its *nested* attachments are out
  of v1, because addressing them needs a path handle (`2.1`), not an index.
- **Refuse:** archives, `winmail.dat` (TNEF), S/MIME / PGP encrypted parts (and
  never touch the OpenPGP key material to decrypt them), and detached / deleted
  attachment stubs.

### Caps

- **A decoded-size cap** (say 25 MB, roughly a typical provider's attachment
  limit) is checked *before* decoding where the encoded length tells us, so a
  hostile 2 GB part never lands in memory.
- **Paging** caps the output, as for `read`. pikuri-pdf parses lazily, so a
  500-page PDF's first window parses a handful of pages.

## Threat model notes

- **Legs unchanged.** This adds an inbound read over data already in the pool:
  the attachment was always in the mailbox. It does raise severity: a PDF can
  carry far more injection text than a body, and no human ever reads it. That
  is the same "one more query surface" point `D_thunderbird_surfaces` makes, so
  it is not a new leg.
- **Hostile parsers.** Every attachment is attacker-authored. pikuri-pdf is pure
  Ruby, so it is memory-safe and the realistic risk is DoS (decompression bombs,
  pathological object graphs). pikuri-extractors runs native converters but in
  a networkless one-shot container. **The workspace `read` never had this
  posture problem to the same degree**, because a workspace file is usually the
  user's own and every mail attachment is a stranger's. Worth a sentence in the
  thunderbird architecture doc and maybe the host-picks-one-PDF-arm guidance:
  for a mail host, the containerized arm is the stronger choice. Is a per-call
  timeout needed for pikuri-pdf? (`Q_extract_timeout`)
- **Not a crack in the "no attachment ever ships" invariant.** That invariant is
  about the *outbound* hand-off. Reading an attachment's text into context is
  inbound. Say so in the gem's `AGENTS.md` line at graduation, so a future
  reader doesn't think one contradicts the other.
- **Privacy caveat.** v1 decodes in memory only, so no new at-rest copy is
  made. If `Q_images` stages files, they go under `Paths.new_temp` (`0700`,
  reaped), the same trust level as the snapshot copies.

## Prerequisite refactor: hoist the page renderer (`Q_hoist_render_page`)

`render_page` (cat-n body + "Use offset=N to continue" trailer) already exists
twice: `Pikuri::Workspace::Read` and `Pikuri::Os::FileindexRead`, near-identical.
This tool would be the third copy. **Lean:** hoist it into core next to
`Extractor::Page`. One option is `Extractor::Page#render(empty_note:)`
returning a `Tool::Result`, with kind-specific wording (`PDF lines`, the
scanned-PDF hint) carried by `page.kind`. All three readers then share the
exact trailer phrasing the model is trained on. That is its own small commit
before this feature.

## Validation before building

All of these need the real profile (none was found on this dev box):

1. `Q_gloda_attachment_infos`: dump `attributeDefinitions` and a PDF-bearing
   message's `jsonAttributes`.
2. Does the Gmail IMAP account actually have an offline store, i.e. are
   `ImapMail/imap.gmail.com/*` mboxes populated, and with full messages
   including attachments (not headers-only / MIME-parts-on-demand)?
3. How long does a Message-ID scan of `[Gmail]/All Mail` take (for the
   `Q_locate` memo decision)?
4. Is it mbox or maildir on that profile (`mail.serverDefaultStoreContractID`
   in `prefs.js`)?
