# Reading Thunderbird mail attachments

Status: **brainstorm, nothing built; storage assumptions validated** against a
real Thunderbird 157 profile's Gmail IMAP account (see § "Validation results").
Spun off from [`thunderbird.md`](thunderbird.md)'s last deferred bullet (".msf /
maildir / mbox fallbacks … would also unlock attachment *bodies*").

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
  - *Verified:* the key `[scheme, userName, hostname]` (scheme `imap` for
    `type=imap`, `mailbox` otherwise) → `directory-rel` with `[ProfD]`
    expanded resolved every Gloda folder of the IMAP account. Path segments
    map as `a/b/c` → `a.sbd/b.sbd/c`.
  - *Verified:* Gloda's `folderURI` is **not valid RFC 3986**. It holds raw
    `[Gmail]` brackets and spaces, so Ruby's `URI()` raises on it. Split it
    with a regex (`scheme://user@host/path`) and percent-decode the user
    (`%40`) and the path.
  - *Verified:* the store kind is **per server**
    (`mail.server.serverN.storeContractID`, `…/berkeleystore;1` = mbox).
    `mail.serverDefaultStoreContractID` was absent from `prefs.js`, so read the
    per-server pref, not the global default.
- **Within the folder:**
  - *IMAP mbox:* the offset (`storeToken`) is only in the `.msf` Mork summary.
    Parsing Mork is the gnarly road. **Decided:** a linear scan of the folder's
    mbox for the `Message-ID:` header, skipping copies whose
    `X-Mozilla-Status` has the expunged bit (`0x0008`) set. Measured at
    ~0.5 s for a 440 MB `[Gmail]/All Mail` (warm page cache), so **no
    `Message-ID → offset` memo**. Within one mbox a Message-ID can appear
    twice with neither copy expunged. All such copies seen were
    byte-identical, so the first live copy wins.
  - *Local `Mail/` mbox:* the architecture doc says `messageKey` is the offset
    here. **Not verified** (Local Folders was empty on the profile), and
    recent Thunderbird decouples the key from the `storeToken`. The
    Message-ID scan works on any mbox, so **use the scan for local folders
    too** and drop the seek-to-key path. That is one code path, and it trusts
    nothing about `messageKey`.
  - *Maildir:* one file per message under `cur/`. Scan the headers for the
    Message-ID, or use the `storeToken` filename if we ever read `.msf`.
    Not seen on the profile. Defer it until a maildir user shows up and fail
    loud on a non-berkeley store.
  - *Gmail label fan-out:* the same Message-ID sits in several folders, and
    Gloda has a row per folder (`[Gmail]/All Mail` plus a user label). Any
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

**Confirmed.** `attributeDefinitions` has `attachmentInfos` as id **51**
(`attachmentTypes` is 49). `messages.jsonAttributes["51"]` is a list of
**positional arrays**, not objects with named keys:

```
["<file name>", "application/pdf", 1357206, "1.2", null, false]
  name          contentType        size     part   externalUrl  isExternal
```

On the IMAP account: 1088 messages carry it, 1286 attachments in all, part
depth `1.N` (1238) or `1.N.M` (48). By type: `application/ics` 649 (Gmail
invites), `application/pdf` 506, images 67, `message/rfc822` 13, office formats
about 20, and a long tail. The findings go to the architecture doc's storage
section, next to the attribute ids 57–61 already recorded there.

- `thunderbird_mail_read` can list `invoice.pdf (application/pdf, 84 kB)` with
  no mbox access. That alone is a cheap, separate improvement.
- The **MIME part number** addresses the attachment exactly. All 1286 part
  numbers resolved to a leaf in an independent MIME walk of the stored
  message (Thunderbird numbering: root `1`, children `1.1`, `1.2`, …).
- **`contentType` is better than the MIME header.** In 7 cases the part says
  `application/octet-stream` and Gloda says `text/csv`, `text/x-patch`,
  `application/pkcs12`, … (it apparently sniffs the extension). Pass Gloda's
  value as the Extractor's `content_type:` hint.
- **`size` is the decoded size, with exceptions.** 1227 of 1286 matched the
  decoded bytes exactly, and every binary part did. `-1` means unknown (29,
  inline images). Every `message/rfc822` part has `0` (13). Text parts are off
  by a few percent (17, line-ending or charset normalization). Display it,
  never enforce it; the cap uses the encoded length (§ Caps).
- **`isExternal` is not the detached-stub flag** this file assumed. It is never
  set on the IMAP account (it marks a part whose bytes live at a remote URL), and
  no `text/x-moz-deleted` or `X-Mozilla-External-Attachment-URL` stub exists
  in its mboxes. Refuse detached stubs **in the MIME walk** by those markers.
  Still skip an `isExternal` entry when listing, because there are no local
  bytes to read.

### MIME parsing (`Q_mime_parser`)

The input is attacker-controlled by definition, and MIME is notoriously gnarly:
nested multiparts, RFC 2231 / encoded-word filenames, base64 vs
quoted-printable, `message/rfc822` forwards, broken boundaries.

Gloda's `attachmentInfos` already supplies the decoded name, the content type
and the part number, so what is left is "walk to part `1.2`, undo the transfer
encoding". A hand-rolled walker for that is about 20 lines and matched all 1286
part numbers in validation. It still loses to the `mail` gem, because v2's
`message/rfc822` rendering needs RFC 2047 header decoding, which stdlib lacks.
A hand-rolled walker would be thrown away then.

**Decided: the `mail` gem, parse-only.** It is the de-facto Ruby MIME library
(ActionMailbox sits on it), which fits the "popular dependency is OK" rule. The
whole walk is one line:

```ruby
part = gloda_part.split('.').drop(1).reduce(mail) { |node, i| node.parts.fetch(i.to_i - 1) }
part.decoded  # base64 / quoted-printable undone
```

Measured on the profile with `mail` 2.9.1: on a 1.87 MB message the walk
returned the PDF part with its exact Gloda size.

- **Dependency graph:** `mail` → `mini_mime`, `logger`, `net-smtp`,
  `net-imap` (→ `date`), `net-pop`. The three `net-*` → `net-protocol` →
  `timeout`. On Ruby 3.3 only `mail` and `mini_mime` are new: the `net-*` are
  bundled gems and the rest are default gems.
- **Size:** `mail` is a 387 KB .gem, 4 MB unpacked, 66K lines of which ~54K
  are Ragel-generated tables under `lib/mail/parsers/`. `mini_mime` is 34 KB.
- **Load and parse:** `require 'mail'` takes ~80 ms (`sqlite3`: ~12 ms).
  Parsing the 1.87 MB message plus decoding the PDF took ~110 ms. Both are
  fine per tool call.
- **An SMTP client in the no-egress gem.** `require 'mail'` eagerly loads
  `Net::SMTP` (IMAP and POP load lazily). No tool reaches it, so it is not a
  trifecta leg, but at graduation the architecture doc's no-egress seam says in
  so many words: `mail` is parse-only, `deliver` / `delivery_method` are never
  called. It is a sentence, not a tripwire (the set is closed).

## The tool

**Shape:** like `read` / `fileindex_read`, a line-paged cat-n window over
`Pikuri::Extractor.extract_paged(StringIO.new(bytes), content_type:)`. Gloda's
`contentType` is the `content_type:` hint, because it beats the part's own
header (see `Q_gloda_attachment_infos`). The registry still sniffs, so a PDF
mislabelled `application/octet-stream` still gets claimed by pikuri-pdf's
`%PDF-` check.

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
  *same* list in the *same* order, so both must come from one source.
  **Decided:** Gloda's `attachmentInfos`, whose `part` the reader then looks
  up in the MIME tree, so `thunderbird_mail_read` never touches the mbox.
  Switch `thunderbird_mail_read`'s listing off `c2attachmentNames` at the same
  time. That column **omits `message/rfc822` parts**: 13 messages list a
  forwarded mail in `attachmentInfos` but have an empty name list. In every
  other case the order of the two matched. A wrong index gets an error listing the attachments, the
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
- **`message/rfc822`** (a forwarded mail as an attachment): **v2**, refused in
  v1 with a message saying so. v2 renders it as headers + text body, using
  `mail`'s encoded-word decoding. Its *nested* attachments need a path handle
  (`2.1`), not an index, so they are a later step again. Gloda records every
  such part with `size` `0`.
- **Refuse:** archives, `winmail.dat` (TNEF), S/MIME / PGP encrypted parts (and
  never touch the OpenPGP key material to decrypt them), and detached / deleted
  attachment stubs.

### Caps

- **A decoded-size cap** (say 25 MB, roughly a typical provider's attachment
  limit) is checked *before* decoding where the encoded length tells us, so a
  hostile 2 GB part never lands in memory. It uses the encoded length, never
  Gloda's `size`, which can be `-1` or `0`.
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

## Validation results

Run against a real Thunderbird 157 profile (snap), scoped to its Gmail IMAP
account. Gloda was read from a copy, since Thunderbird was running, and the
mboxes were read live.

1. `Q_gloda_attachment_infos`: **holds**, with positional arrays. Details in
   that section.
2. **Offline store present, with full bodies.** The Gmail mboxes under
   `ImapMail/imap.gmail.com/` are populated. All 1088 attachment-bearing
   Gloda rows were found by Message-ID in their own folder's mbox, with every
   attachment part fully present (base64 decodes to the exact Gloda size,
   `%PDF-` magic intact). No copies carried the expunged bit. The mbox is CRLF
   with a `From - <ctime>` separator, as the architecture doc says. So no
   headers-only or parts-on-demand stubs were found, though the "not stored
   offline" error stays for accounts configured otherwise.
3. **Scan speed:** one Message-ID scan of the 440 MB `[Gmail]/All Mail` took
   0.4–0.5 s. Indexing every Message-ID in it took 0.55 s. Page cache was warm,
   and a cold-disk figure wasn't measurable without root. No memo is needed.
4. **mbox.** Every server says `berkeleystore` in its own `storeContractID`,
   and the global `mail.serverDefaultStoreContractID` is unset (see
   `Q_locate`).
