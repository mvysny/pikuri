# pikuri-thunderbird — design & threat model

Audience: someone extending this gem or auditing its security posture.
Rationale for individual classes lives in their YARD headers; this file
covers the cross-cutting design and the threat model. The in-flight design
notes and still-open questions live in `design/ideas/thunderbird.md`.

## What it does

Gives a pikuri agent read-only access to the user's **local** Thunderbird
data — stored mail and cached calendars — by reading Thunderbird's own
on-disk profile. It never speaks IMAP/POP3/SMTP or CalDAV itself; it reads
files Thunderbird already wrote.

- **Mail** rides Thunderbird's Gloda index (`global-messages-db.sqlite`),
  which has already MIME-decoded, HTML-stripped, and split every message
  into body / subject / attachment-names / author / recipients. pikuri
  treats it as a pre-decoded corpus. Gloda never had attachment *bytes*, so
  reading one goes to Thunderbird's offline mbox store (§ "Mail: mbox on
  disk").
- **Calendar** reads the `calendar-data/*.sqlite` stores, whose events are
  normalized columns (no ICS parser for the common case).

## Threat model: the lethal trifecta

Email is the textbook lethal trifecta. The three legs:

1. **Private data** — the mailbox and calendars. Inherently present.
2. **Untrusted content** — every message body, subject, attachment name and
   attachment is authored by whoever sent the mail, i.e. potentially an
   attacker. Inherently present.
3. **Egress** — the ability to send data out.

**The default surface removes leg 3 entirely.** The six tools
`thunderbird_mail_search`, `thunderbird_mail_read`,
`thunderbird_mail_attachment_read`, `thunderbird_contact_search`,
`thunderbird_calendar_search`, and `thunderbird_calendar_read` are all
inbound-only, and they are all `Extension`
gives unless a host opts into an outbound leg. An agent wired with just these (plus, say, a calculator) has legs 1
and 2 but no way to send anything anywhere, so a prompt injection buried in a
message body has no exfiltration channel. That is the "trifecta broken by
construction" posture `bin/pikuri-corpus` and `bin/pikuri-memory` demo.

A host can also take *fewer* than six: `Extension.new(surfaces: %i[mail])`
wires the mailbox and neither the address book nor the calendar. That changes
nothing about legs 1 and 2 — mail search alone carries both, and presence is a
union — so the trifecta map prints the same advisory and the same leg count
either way. What it buys is severity: each surface is one more thing an
injected message can make the agent query over the private pool, and three
fewer query surfaces is three fewer. Since the detector cannot show that
(`design/decisions.md` `D_thunderbird_surfaces`), a host that narrows owes its user a
sentence naming what the remaining pool actually is — "your whole mailbox", not
"your correspondence with this customer".

**Attachments raise severity, not the leg count.** `thunderbird_mail_attachment_read`
pours an attachment's text into the context: the same leg 2 as a body, so
it carries the same legs as `thunderbird_mail_read`. It is worse in degree —
a PDF carries far more injection text than a body, and no human ever reads
it — and every attachment is a stranger's *file* fed to a parser, which a
workspace file mostly is not. The PDF arm the host picks is therefore a
posture choice: pikuri-pdf is pure Ruby, so memory-safe, and its realistic
risk is a parser DoS (no per-call timeout: Ruby's `Timeout` is unsafe around
native code, pages are parsed lazily, and `MessageStore`'s 40 MB message cap
bounds the input; revisit if a hostile PDF ever hangs a turn); pikuri-extractors runs native converters but in
a networkless one-shot container, the stronger choice for a mail host.
An HTML attachment renders through pikuri-html, which keeps text the markup
hides but labels it `[hidden in the original: …]`. It can't spot white-on-white,
so the label is evidence for whoever reads the transcript, not a defense.
An image goes to the model as the picture itself: pikuri only sniffs its
magic bytes and never decodes it — the model server does — but a vision
model reads text *drawn* into it, which no human reviews either.
Reading an attachment is *inbound*, so it does not touch the outbound "no
attachment ever ships" invariant below.

The bundled `bin/pikuri-thunderbird` deliberately goes one step further — it
wires both outbound `allow_` flags to demo the *whole* surface — so it does
carry leg 3. But that leg is human-gated: compose can only open a Thunderbird
compose window the user Sends themselves (below), so there is an egress leg yet
no *autonomous* egress. A poisoned message can influence a draft, but cannot make it leave the
machine without the user clicking Send on a window they can see. So the demo's
trifecta is *intact-but-gated*, not severed — an honest smoke-alarm, not a
firewall.

Defense in depth on leg 2: **Spam/Junk/Trash are not searched.** On the
Gloda path this is *free* — Gloda already assigns those folders indexing
priority `-1` (never indexed), so the search backend structurally cannot
return them. This attenuates but does **not** sever leg 2: a *targeted*
injection lands in the Inbox (a reply, a newsletter, a calendar invite), not
in Spam. Record it as a mitigation, never a boundary. Honest wrinkle
(confirmed on a live box): Gmail's account-level Trash folders are `-1`, but
the `[Gmail]/Trash` *label* folder is indexed at priority 20, so a handful of
trashed Gmail messages can surface — the free skip is nearly, not perfectly,
complete.

## The snapshot mechanism

Thunderbird holds its SQLite DBs open with `locking_mode=EXCLUSIVE`, so a
plain read fails "database is locked" while it runs, and a lock-bypassing
`immutable=1` read of the live file risks a torn read. pikuri never queries
the live file. Instead {Pikuri::Thunderbird::DatabaseSnapshot} takes a **bracketed
`cp --reflink=auto`** of the main file, then its `-wal` if there is one. It
reads the *generation* (the SQLite change counter at header bytes 24–27, plus
the `-wal`'s salt and size) and checks for a rollback `-journal` before and
after the copy, and accepts the copy only if the generation didn't move and
no journal was present at either edge (otherwise it discards and retries).
The copy is opened normally, so SQLite applies the copied WAL. Reflink makes
the copy a near-free metadata-only extent share on a copy-on-write
filesystem.

The validated generation doubles as a freshness stamp: each query compares
the live one against it and re-copies (and, for mail, rebuilds the FTS5
index) only when it moved. One signal drives both consistency and freshness.
The WAL parts are why it is not the counter alone: a WAL store bumps the
counter only on a checkpoint.

**Mail search index.** Gloda's own full-text index (`messagesText`) is an
fts3 virtual table behind Mozilla's custom `mozporter` tokenizer, which the
`sqlite3` gem cannot open. So pikuri builds its *own* ephemeral FTS5 index
over the decoded columns (`messagesText_content`) inside the snapshot copy —
external-content, so it stores only the index, not a second copy of the
text. Rebuilt (~1 s) only when the Gloda generation moves.

### Privacy caveat

The snapshot is the decoded mailbox/calendar landing **outside** the
Thunderbird profile, in a `0700` dir under `~/.cache/pikuri/thunderbird/`.
This is a second at-rest copy — but at the *same trust level* as the source:
the Gloda and calendar DBs are already unencrypted plaintext on disk in the
profile, and the copy is user-owned with the same permissions. It is not a
new exposure class. The copy is `Pikuri::Finalizers`-reaped on a clean exit;
a crash can strand it until it's next overwritten or the dir is cleared
(re-derivable data, low harm).

The credential stores that share the profile directory (`logins.*`,
`key4.db`, `cert9.db`, `openpgp.sqlite`, …) are **never** opened — the
backends touch only the allowlist in § "Files never touched".

The attachment reader adds **no** at-rest copy: it decodes in memory, from
the mbox Thunderbird already keeps in plaintext.

## Outbound is a human-gated v2, never an autonomous send

Composing a mail or creating a calendar event is egress (a send, an invite,
a CalDAV sync). The design invariant, locked in before any of it ships:

> **pikuri-thunderbird performs no network egress and no autonomous send.**
> Every outbound action is a hand-off to Thunderbird's own UI — a pre-filled
> compose window (via a `mailto:` URI) or an `.ics` import wizard — where the
> *human* reviews and commits. pikuri writes nothing to Thunderbird's stores
> and sends nothing itself. No send tool ever ships.
>
> **And no attachment ever ships.** The outbound surface carries only fields
> that *render literally*: a plain-text body, a subject, addresses. No
> attachment of any kind (`.png`, `.zip`, `.txt` — the extension is
> irrelevant), no HTML body, no iCalendar `ATTACH` property.

This converts egress from *agent-automatic* to *human-action-required*. Note
what that does and does not buy — the leg is **downgraded, not removed**, and
the threat-model section above is the authority: once an `allow_` flag is on,
leg 3 is present. Only the default surface (both flags off) severs it.

What the downgrade rests on is narrow and worth naming, because it's the one
property a rubber-stamping human can't destroy: **the human sees the exact
bytes that leave.** The compose window shows the literal recipient, subject
and body that will be sent; the `.ics` wizard shows the event that will be
imported. Contrast a shell agent that asks "run `curl …`?" — there the human
approves a *program*, and what it actually uploads was never on screen. So a
poisoned message can influence a draft, but every byte of that draft was
displayed to someone before it moved.

That is a real reduction and not a boundary: it kills *silent* exfil — every
byte was on a screen — and leaves the covert channel, a secret spelled into
prose the reader skims past, sent as a reply to the injector (see "What the
body guards do *not* close" below).

**Resist the temptation to call the survivors low-bandwidth.** They aren't.
A first-letter acrostic carries roughly one letter per word, and a secret is
already text — so an agent *transcribes* it rather than computing anything.
Price the channel that way, since this gem wires no shell and no calculator:
a pasted `id_ed25519` is its ~400 base64 characters, so ~400 words; a whole
RSA PEM ~1600. A thread, not a wall — and the mailbox is exactly where
someone pasted the key "just to have it" five years ago. (An agent that
*does* hold local compute prices it lower still, by the secret's entropy —
~55 words for that ed25519 key; a network-severed sandbox cuts egress, never
arithmetic. See `book/os-assistant.md` §"Why 'too big to hide' is not a
defense".) The bytes-visible property is worth stating because it is
structural; "the payload is too big to hide" is not, and shouldn't be
offered as reassurance.

### Why no attachments — it's the same invariant as plain-text-only

An attachment is the cleanest way to defeat the whole gate. A key encoded in
the low bits of a `.png` is invisible to any reader: the human approves a
*filename* and a thumbnail, never the bytes. That is exactly the shape of a
shell agent asking "run `curl …`?" — an approved *reference* to content
nobody saw — and it would demote this hand-off from "human sees the payload"
to the same class as an autonomous send, no matter how careful the human is.

So "plain text only" and "no attachments" are not two policies but one:
**the outbound surface may contain only fields whose rendering is their
content.** HTML fails it (`<span style="display:none">`), attachments fail it,
and so would any richer field added later. Today this is enforced by
construction rather than by filtering — {Pikuri::Thunderbird::MailtoUri}
*builds* an allowlist of five parameters (`to`/`cc`/`bcc`/`subject`/`body`),
so there is no `attach=` to strip, and {Pikuri::Thunderbird::IcsEvent} emits
no `ATTACH` property. Enforced-by-absence is fragile against a future
"improvement" — `mailto:?attach=` was a real Thunderbird feature — which is
why the invariant is written down rather than left implied by the code.

**Compose is shipped, opt-in.** `thunderbird_mail_compose`
({Pikuri::Thunderbird::MailCompose}) is wired only when a host passes
`Extension.new(allow_compose_mail: true)` — off by default, so an unopted wiring has no
egress leg *by construction*. `bin/pikuri-thunderbird` opts in (to demo the
full surface). Turning compose on re-introduces leg 3, but only as a
human-committed hand-off: the tool opens a
`mailto:` compose window ({Pikuri::Thunderbird::MailtoUri} percent-encodes every
field so a body can't smuggle `&bcc=`), the body is plain-text-only (no hidden
content, no remote beacons), and a mechanical recipient guard
({Pikuri::Thunderbird::ComposeGuard}) runs first: a suspicious *body* fails
closed; suspicious/non-ASCII/punycode *recipients* are dropped for the human to
retype; a recipient domain the user has never sent mail to (per
{Pikuri::Thunderbird::Gloda::Contacts#domains_sent_to}) is flagged, not blocked; and a body
carrying a long base64 *blob* earns a located soft-warn (see
{Pikuri::Thunderbird::ComposeGuard#body_blob_note}). The launch
is detached (`setsid --fork`) so closing the agent never kills the user's
Thunderbird.

**What the body guards do *not* close.** They raise attention on the lazy exfil
— a control-byte/homoglyph body fails closed, a base64/hex/base32 dump earns a
note — but
they are not a barrier against an *adaptive* injector, who splits the blob with
whitespace or spells it in prose for free (the same injection payload carries
the evasion). A reply to the injector is flagged, since only domains the user has
*sent* to count as known and an attacker can't earn that by writing first. It
stays silent where the attacker writes from a domain the user has mailed before:
a compromised contact's account, or a shared provider's domain (`gmail.com`),
because the check is per-*domain*.

**What each guard really buys is a rung, not a wall.** Every check here
narrows the *form* the payload may take, never the payload itself, so an
adaptive injector simply steps down: fail the body on control bytes,
zero-width joiners and homoglyphs, and it drops to plain ASCII; note a
base64 dump and it moves to hex, then base32, then splits the run below the
threshold; catch those and what remains is **linguistic steganography** — the
secret spelled out by the first letters of an innocuous sentence ("I think
dogs are super cute"), by word choice, by sentence count. That bottom rung
reads as ordinary prose to the guards *and* to the human, which is where an
injector who has read this file starts. It is slower, and slow is not a
barrier: `book/os-assistant.md` §"Why 'too big to hide' is not a defense"
prices what fits. The human-gated, irreversible-send compose window — not the
guard — is the backstop all of this leans on.

**Create-event is shipped, opt-in.** `thunderbird_calendar_create`
({Pikuri::Thunderbird::CalendarCreate}) is wired only when a host passes
`Extension.new(allow_create_calendar_event: true)`. Same human-gated shape:
it builds an event `.ics` ({Pikuri::Thunderbird::IcsEvent} RFC-5545-escapes
every field so a description can't inject a second `VEVENT`), stages it where a
snap-confined Thunderbird can read it ({Pikuri::Thunderbird::Profile#outbox_dir}),
and hands it to TB's import wizard, where the human picks the destination
calendar (local-vs-CalDAV = their no-egress-vs-egress choice) and confirms.
Both outbound tools launch via the shared {Pikuri::Thunderbird::Launcher}. The
full v2 rationale + open questions are in `design/ideas/thunderbird.md`.

## Discovery

{Pikuri::Thunderbird::Profile} never guesses: it resolves one profile
unambiguously (parsing `profiles.ini`), raises with a fix if two install
roots both hold a profile with a mail account (a stale apt profile left after
an apt→snap migration), or returns `nil` (tools simply not registered) when Thunderbird
isn't installed. An explicit `profile_dir:` override bypasses discovery.
Linux snap and apt roots are supported; flatpak is out of scope.

## Storage landscape (empirically confirmed)

The reference data the design rests on, probed against a live snap install
(Thunderbird 152.0, Linux, 2026-07). It's here — not in the class yardocs —
because it spans the whole gem and is expensive to re-derive (it needs a real,
populated Thunderbird). The per-symbol *why* lives in the class yardocs; this
is the shared evidence base, and the ground truth a v2 builder will need.

Caveat: all of this is one real install (snap; Gmail + iCloud IMAP; CalDAV
calendars); the attachment facts were re-probed on it at Thunderbird 157
(2026-10), against the Gmail account. The specs run against synthetic fixtures
built to this schema; the testbed (§ below) adds a profile a real Thunderbird
159 built, with an IMAP account synced from a local dovecot — generic IMAP,
not Gmail's labels-as-folders, and with every body offline, so on-demand IMAP
attachments are still checked only on that one install.

### Profile & install roots

- `profiles.ini` is a small INI; the active profile is the `Default=1`
  section (`Path`, relative when `IsRelative=1`). The confirmed real file has
  **no `[Install…]` sections** (Firefox's per-install mechanism), so the plain
  `Default=1` scan suffices.
- Roots: **snap** `~/snap/thunderbird/common/.thunderbird/` (confirmed),
  **apt** `~/.thunderbird/` (recalled). Flatpak
  (`~/.var/app/org.mozilla.Thunderbird/…`) is out of scope.
- `.parentlock` at the profile root is Thunderbird's running-instance lock — a
  cheap "is TB open?" probe. The `lock` symlink beside it (`lock ->
  <ip>:+<pid>`) **outlives a clean exit**, so its presence proves nothing.
- `thunderbird -profile <dir>` runs on any directory and neither creates nor
  touches `profiles.ini`.
- **The snap launcher links its root to an existing `~/.thunderbird`.** Started
  while `~/.thunderbird` existed and the snap root didn't, snap 159 created
  `~/snap/thunderbird/common/.thunderbird -> ~/.thunderbird`. For a user
  migrated from the deb, both roots are then one directory, so discovery
  compares roots by realpath.

### Mail: the Gloda index (`global-messages-db.sqlite`) — the v1 source

A complete, pre-decoded search index. Tables that matter:

- **`messagesText`** — an FTS3 virtual table over `body`, `subject`,
  `attachmentNames`, `author`, `recipients` (already MIME-decoded,
  HTML-stripped, attachment *names* extracted). Its backing store is the plain
  table **`messagesText_content(docid, c0body, c1subject, c2attachmentNames,
  c3author, c4recipients)`**.
- **`messages`** — `id` (= FTS `docid`), `folderID`, `messageKey`,
  `conversationID`, `date` (**PRTime = µs since epoch**, ÷1e6 for Unix
  seconds, second granularity), `headerMessageID` (the RFC822 `Message-ID`),
  **`deleted`**, `jsonAttributes`, `notability`.
- **`folderLocations`** — `id`, `folderURI`, `dirtyStatus`, `name`,
  **`indexingPriority`**: `-1` = never indexed (Gloda's sentinel), else `20`
  (normal) / `50` (INBOX) / `60` (Sent). Resolves a hit's `folderID` → folder.
- **`contacts` / `identities` / `contactAttributes`** — the email↔name
  correspondence graph. `contacts` is **dead for resolution** — `frecency` /
  `popularity` are 0 for every row and `name` is unreliable (often a bare
  address or junk), so {Pikuri::Thunderbird::Gloda::Contacts#resolve} reads the
  *decoded* `c3author` / `c4recipients` columns instead (name + address
  together, with a natural per-message frequency). `identities(kind, value)` is
  unused too: it holds **every author**, so a domain that only ever wrote *to*
  the user would count as known the moment its mail is indexed, and an attacker
  earns that by writing first. {Gloda::Contacts#domains_sent_to}, the
  recipient-novelty check, reads `c4recipients` of Sent-folder messages instead
  (on the testbed the look-alike `northwlnd-bank.example` and the attacker's
  `kettle-co-payments.example` now warn, `lumo-studio.example` doesn't).
- **A literal `undefined` in the author/recipient text.** Thunderbird 159
  writes `Mira Koskinen <mira@lumo-studio.example> undefined` into
  `c3author` / `c4recipients` for every address but the owner's own as
  author (the owner as a recipient gets it too), probably an address-book
  field for a contact that isn't in the address book. The readers pass it on
  today; stripping it is `design/ideas/gloda-undefined-author.md`.
- **Gloda keeps at most ~20 KB of each body part.** It indexes with
  `saneBodySize` (`MAX_SANE_BODY_PART_SIZE = 20 * 1024`,
  `MimeMessageEmitter.sys.mjs`), so a longer body is cut mid-sentence
  (testbed's `house-rules`: 20632 bytes kept), and an HTML part is cut
  before its markup is stripped. `thunderbird_mail_read` ends a body that
  reached the cap with a note to open it in Thunderbird; it doesn't fetch the
  rest from the mbox, since a mail that long is rare and the fallback would
  cost a store scan per read.
- **The FTS subject drops `Re:`** — a reply's `c1subject` is the bare subject,
  so a search by subject can't tell a thread's replies from its opener.
- A `messages` row with a null `folderID` is a **ghost**: Gloda's placeholder
  for a message a thread references but the store doesn't hold. Counting real
  messages means `WHERE folderID IS NOT NULL`.
- **`attributeDefinitions` / `messageAttributes`** — extensible per-message
  attributes; ids seen: 57 `tag`, 58 `star`, 59 `read`, 60 `repliedTo`,
  61 `forwarded`. (Relevant to churn — see the change counter below.) Ids are
  assigned per profile, so code looks one up by `name`.
- **`attachmentInfos`** (id 51 there) — the attachment list, stored in
  `messages.jsonAttributes` under the attribute's id as **positional arrays**
  `[name, contentType, size, part, externalUrl, isExternal]`. Verified over
  all 1286 attachments of the IMAP account: every `part` resolved to the right
  leaf of the stored message (root `1`, children `1.1`, `1.2`, …); `contentType`
  beats the part's own header (7 parts said `application/octet-stream` where
  Gloda, going by the file name, said `text/csv` etc.); `size` is the decoded
  size for every binary part, but `-1` when unknown, a few percent off for
  text, and noise for a `message/rfc822`: `0` for every one on the Gmail
  account, an unrelated non-zero number on the testbed's dovecot account (526
  to 6941, Thunderbird 159). `isExternal` marks a part
  whose bytes are at a remote URL — never set on IMAP, and **not** the flag
  for a detached attachment (that is a `text/x-moz-deleted` part). The FTS
  column `c2attachmentNames` **omits forwarded mails**, which is why the
  listing numbers this list instead — yet it *carries* the names of the
  attachments inside a forward, at any depth, which this list omits
  (testbed, 159: a forward of a forward still indexes the CV two levels
  down), so a search can find a mail by an attachment name its listing
  never shows. The forward's own listing shows it, numbered under the
  forward's handle (`D_attachment_path_handle`).
- **What `attachmentInfos` lists** (testbed, 159). Thunderbird's C++
  MIME code decides this, so the rule is measured, not read off source;
  `ForwardedMail` follows it, and `dev/testbed/mail/*.eml` holds the
  Apple Mail, Outlook and odd-leaf trees it was measured on;
  `dev/testbed/compare-forwards` re-checks the two agree.
  - A **file name, or `Content-Disposition: attachment` alone**, lists a
    leaf at any depth: Apple Mail's PDF inside
    `alternative > mixed > [html, pdf, html]` too. A leaf with no name
    is listed as `Part 1.2`, after its part path.
  - **Inside `multipart/related`, nothing** is listed, named or not: an
    image an HTML part shows by `cid:` (Outlook's `image001.png`). The
    same image `inline` under `mixed` is listed.
  - An **unnamed leaf** is body when it is text/plain or text/html, under
    `mixed` too (a trailing footer). Any other unnamed leaf is listed,
    unless it is an `alternative`'s rendition, like an invitation's
    `text/calendar`. So the HTML half of a newsletter's `alternative` is
    never listed.
  - A forward's text body is appended to the outer message's `c0body`
    with no separator, at any depth.
- Ignore: `imConversations*`, `ext_mimeTypes`.

**The mozporter sharp edge.** Both FTS tables use Mozilla's custom `mozporter`
tokenizer, so a stock SQLite (CLI *or* the `sqlite3` gem) cannot `… MATCH …`
against them — it errors *"unknown tokenizer: mozporter"*. Worse, the gem's
precompiled SQLite (3.53.2) is built **FTS5-only**, so it can't even *open*
Gloda's fts3 `messagesText` (`no such module: fts3`). Registering a mozporter
tokenizer `.so` was tested and is a dead end on the default stack (it needs a
bespoke FTS3-compiled SQLite build, not just a loadable tokenizer). Escape:
read the plain `messagesText_content` columns directly (openable fine) and
build our own FTS5 over them — which is exactly what {Pikuri::Thunderbird::Gloda}
does. (`c0body LIKE '%invoice%'` scanned cleanly, 234 hits, on the real box.)

**Freshness/consistency: the change counter.** `journal_mode=delete` (classic
rollback journal, no WAL), `user_version=30` (a drift anchor). The file change
counter (header bytes 24–27) is authoritative per commit here, bumped only on
unlock-after-write (a read never moves it). Measured: it bumps on *any* Gloda
write — **including read/star/tag flips during triage** (marking one message
unread advanced it +1), not only new-mail arrivals — because Gloda indexes
those as attributes. Consequence for the FTS5 rebuild: it re-fires during
ordinary triage, not just after a poll (a ~1 s papercut; a future optimization
gates the rebuild on a content triple `(max(id), count(*), sum(deleted))`
instead of the raw counter). The `-journal` is **transient, not persistently
retained** (probed: present in 1 of 3 idle samples, exactly while the counter
was mid-bump), so its presence is a valid "write in flight → retry" signal for
the snapshot bracket.

**Gmail label fan-out (why dedup is mandatory).** Gmail exposes each label as
an IMAP folder, so a message with N labels yields N Gloda rows.
**`[Gmail]/All Mail` is indexed** (`indexingPriority` 20, **5974 messages** —
the largest folder, vs. 8239 distinct Message-IDs / 9654 total rows → ~1415
duplicate rows). Search dedups by `headerMessageID` before the top-N cap. The
7 `-1` never-indexed folders are exactly Trash/Spam/Junk/Unsent across the
accounts — so the "skip Spam" leg-2 attenuation is free on the Gloda path —
**except `[Gmail]/Trash` is indexed at prio 20** (5 msgs), so that skip is
nearly, not perfectly, complete. (Also seen: 1571 rows with a null/blank
`folderID` — irrelevant to Gloda-only reads, which take the body from
`c0body`.)

### Mail: mbox on disk — where attachment bytes live

Read only by {Pikuri::Thunderbird::MessageStore}, for
`thunderbird_mail_attachment_read`; search and body reads stay on Gloda. Mail
is **mbox** (extensionless files, `file(1)` "Mailbox text"), under
`ImapMail/<server>/` (IMAP, subfolders nest via `<Folder>.sbd/`) and `Mail/`
(Local Folders, Feeds), each shadowed by a `<Folder>.msf` **Mork** summary.

- **Format:** CRLF line endings; the dash-prefixed `From - <ctime>` separator
  (not classic `From <addr>`); server-defined folder names (Gmail INBOX is
  uppercase — never hardcode); the `X-Mozilla-Status` **expunged** bit
  (`0x0008`) marks a deleted-but-not-compacted copy — common enough that a
  reader must skip it.
- **Which directory:** `prefs.js` is the only map from an account to its store
  directory (`mail.server.serverN.directory-rel` / `.hostname` / `.userName` /
  `.type`); a second account on one host gets a `-1` directory. The store kind
  is per server (`.storeContractID`, `…/berkeleystore;1` = mbox,
  `…/maildirstore;1` = one file per message); the global
  `mail.serverDefaultStoreContractID` was absent from `prefs.js` because
  Thunderbird ships it as mbox for every account type, POP3 and IMAP alike
  (159's `defaults/pref/mailnews.js`). Maildir is a per-account opt-in, so
  only mbox is read and a Maildir account is refused with a message. Should
  that change, the testbed indexes Maildir as-is (one file per message
  dropped into `<folder>/cur/`), and a `Message-ID:` header scan over its
  177 files took ~1 ms. Gloda's `folderURI`s are
  **not RFC 3986** (raw `[Gmail]` brackets and spaces — Ruby's `URI()` raises),
  so they are split by regex and percent-decoded.
- **Which message:** `messageKey` is the IMAP UID under `ImapMail/`, and the
  byte offset lives only in the `.msf`; whether it is an offset for local
  `Mail/` was not re-verified. So the reader finds a message by **scanning for
  its `Message-ID:` header**: ~0.5 s through a 440 MB `[Gmail]/All Mail` (warm
  page cache), fast enough that no offset memo is kept. A `Message-ID:` line
  inside a *body* (a forwarded mail) is skipped; the few Message-IDs seen twice
  in one mbox were byte-identical copies, so the first live one wins.
- **Coverage:** all 1088 attachment-bearing IMAP messages were in the offline
  store with full bodies. A message whose body was never offline doesn't reach
  this store at all: Gloda indexes it from headers alone, with `c0body` NULL
  and no `attachmentInfos`, even with the server reachable (testbed, 159: 14
  attachment mails in a folder with its Offline flag cleared). A NULL
  `c2attachmentNames` is the tell — a parsed message with none has `""` — so
  `thunderbird_mail_read` says the body isn't downloaded and names the setting
  to change ({Pikuri::Thunderbird::Gloda::Mail#read}). Downloading the folder
  later makes Gloda re-index them with body and attachment list. "Not stored" is left for a copy gone from the offline
  store after Gloda indexed it with a body.
- **Read live, without a snapshot:** an mbox has no SQLite-style lock, and a
  multi-GB copy per read is absurd. Thunderbird appends new mail and compacts
  by renaming a new file over the old, so one fd held for the whole scan stays
  self-consistent; a message appended mid-read is not in Gloda yet anyway.

### Calendar stores (`calendar-data/`)

Three sibling DBs: **`cache.sqlite`** (cached network/CalDAV calendars),
**`local.sqlite`** (`storage`-type local calendars), `deleted.sqlite`
(`cal_deleted_items` sync tombstones). **The data gate:** a CalDAV calendar
keeps events **in memory only** unless "Offline Support" (`cache.enabled` in
`prefs.js`) is on — so all three can be empty while the UI shows full
calendars. Enabling it populated `cache.sqlite` to **62 MB / 5414 events** and
it mirrors `local.sqlite`'s schema exactly (`cal_calendar_schema_version=23`;
`user_version` is 0 — gate on the table, not the pragma). This is why the
calendar tools register regardless and self-explain the empty state.

`cal_events` is normalized columns, not opaque ICS:

- `cal_id` (the calendar's registry UUID → `prefs.js`
  `calendar.registry.<uuid>.{name,type,uri,cache.enabled}` for human name +
  `storage`/`caldav` type), `id` (event UID), `title`.
- `event_start`/`event_end` — **PRTime µs of the UTC instant** (confirmed on
  5414 events: sane 2010→2031 histogram; times read as business hours only
  under UTC→local; user-confirmed against the live UI — a 10:00 meeting reads
  10:00 local, not 07:00 UTC). Displayed via the `_tz` column.
- `event_start_tz`/`event_end_tz` — a tzid string, and the two **can differ**
  (cross-zone events). Valid forms, all meaningful: Olson names
  (`Europe/Helsinki` dominant), literal **`floating`** (wall-clock; every
  all-day event uses it), **`UTC`**, rare fixed-offset **`GMT+0300`**. Default
  defensively even though no null was observed. An imported `DTSTART` without
  a `TZID` is stored `floating`; an Olson `TZID` with no `VTIMEZONE` block is
  resolved by name (Thunderbird 159).
- `flags` = calStorageCalendar's `CAL_ITEM_FLAG` bitfield (verify against
  comm-central at v2 impl): 2=attendees, 4=properties, **8=all-day**,
  16=recurrence, 32=exceptions, 64=attachments, 128=relations, 256=alarms,
  512=recurrence-id-all-day. **All-day = bit 8** — airtight (a clean diagonal:
  126 rows, `flags&8` ⟺ midnight-aligned start ⟺ `tz=floating`, zero
  off-diagonal). All-day DTEND is iCal **exclusive** (1-day event spans exactly
  1 day), so render `[start, end − 1 day]` and don't zone-convert.
- `ical_status`, `priority`, `privacy`, recurrence fields. **`recurrence_id`**
  is the fold key: a recurring series is stored as a *master* row
  (`recurrence_id` NULL, `flags & 16` set, RRULE in `cal_recurrence`) **plus one
  row per modified occurrence** ("exception") — same event UID, distinct
  `recurrence_id` (the occurrence's PRTime), and *no* `flags & 16` bit. So a
  per-row recurrence filter on `flags & 16 = 0` leaks every occurrence under
  "single" and floods plain search with the same event; `Calendar#search` folds
  rows by UID (`#fold_series`) and classifies the *series* recurring if any row
  is a master or an occurrence.

Companions: `cal_todos` (VTODO, same shape); `cal_properties(item_id, key,
value)` (DESCRIPTION, LOCATION, …); `cal_recurrence`/`cal_attendees`/
`cal_alarms`/`cal_relations`/`cal_attachments` (iCal-shaped `icalString`
fragments — parse with the `icalendar` gem only if wanted).

### SQLite locking

Thunderbird opens its DBs with `locking_mode=EXCLUSIVE`, so a plain
`-readonly` open fails *"database is locked (5)"* while it runs — **even for
WAL stores** (the calendar DBs are WAL, and WAL readers are still shut out).
`immutable=1` is the universal lock-bypass; for a WAL store it reads
as-of-last-checkpoint. Right after the 62 MB sync the `-wal` held ~1 MB and
`immutable=1` saw all 5414 events — but that is a busy DB. **A handful of new
rows stays in the `-wal` until Thunderbird quits** (testbed, Thunderbird 159: an
event added live sat in a 2.3 MB `-wal`, invisible to `Calendar#search`, and
appeared after the clean quit's checkpoint). So an `immutable=1` read misses
it, and {Pikuri::Thunderbird::DatabaseSnapshot} copies the `-wal` beside the
main file and opens the copy normally. With `locking_mode=EXCLUSIVE` there is
no `-shm` to copy; SQLite rebuilds it from the WAL, even on a read-only open.
Live check: `dev/testbed/js/add-event.js` during a session, then
`Calendar#search` for "Live event".

### Platform confinement (snap `home` interface)

Mapped by staging a probe `.ics` in three spots and opening each in a
snap-confined Thunderbird:

| Location | Readable by snap TB? |
|---|---|
| snap-owned area (`~/snap/thunderbird/common/…`) | **yes** |
| hidden home dir (`~/.cache/…`) | **no** |
| non-hidden home (`~/…`) | **yes** |

The recalled dotfile restriction is real: the `home` interface grants
non-hidden `$HOME` files, not dotfiles. **Sharp UX edge:** a blocked path does
*not* error — the `.ics` import wizard opens and reports "no events available"
(it read an empty file) — so staging correctness can't lean on error
detection. Consequence: the v1 snapshot lives in hidden `~/.cache` (read by
*pikuri*, unconfined — fine), but a v2 `.ics` hand-off must stage where the
confined TB reads (snap-owned area, or a non-hidden `$HOME` dir); the two dirs
can't be shared on snap.

### Hand-off mechanics — for the v2 egress tools

- **Compose → `mailto:` URI (built).** `thunderbird 'mailto:to@…?cc=…&bcc=…&subject=…&body=First%0ASecond'`
  opens a pre-filled compose window, percent-decoding cleanly (`%0A`→newline,
  `%20`→space), populating subject + cc + **bcc**, reusing the running
  instance. Chosen over `-compose`, which **cannot do multiline** (`body='A%0AB'`
  rendered the literal `A%0AB`). Because the transport is a URI, every field
  value must be percent-encoded so an attacker-authored body can't smuggle a
  hidden `&bcc=` — see {Pikuri::Thunderbird::MailtoUri}. pikuri launches it
  detached (`setsid --fork`) so the agent's exit-sweep can't SIGTERM the user's
  Thunderbird, and so a not-yet-running Thunderbird doesn't block the tool on
  the GUI.
- **Create event → `.ics` import (built).** `thunderbird <path.ics>` opens TB's
  "Import Calendar file" wizard as a new tab (running-instance reuse): a 4-step
  flow ending in **Confirm**, with a **target-calendar picker** at step 3.
  **No silent import** — Cancel leaves nothing behind. So TB's UI owns the
  commit *and* the human picks local-vs-CalDAV (i.e. no-egress-vs-egress). The
  `.ics` is built by {Pikuri::Thunderbird::IcsEvent} (RFC-5545 field escaping is
  the injection defense), staged in {Pikuri::Thunderbird::Profile#outbox_dir}
  (confined-readable, **not** the hidden `~/.cache` snapshot dir — see § "Platform
  confinement"), and handed off by the shared {Pikuri::Thunderbird::Launcher}
  (the same detached `setsid --fork` launch compose uses).

Both are the human-gated hand-off shape the no-send seam requires: pikuri
opens a window, the human reviews and commits.

Re-confirmed on Thunderbird 159 under Xvfb (testbed, 2026-11-13):
{Pikuri::Thunderbird::Launcher}'s `setsid --fork thunderbird mailto:…` remoted into the running instance and
opened a compose window with From, To, Subject and the multi-line body intact;
an `.ics` path opened the import wizard. No second instance started.

### Files never touched

The guarantee is an **allowlist, not a blocklist**: the backends open only
`global-messages-db.sqlite` and `calendar-data/*.sqlite` (plus their snapshot
copies), discovery reads `profiles.ini`, and the attachment reader reads
`prefs.js` (its `mail.server.*` lines only — passwords live in `logins.json`,
not there) and the mbox files under `ImapMail/` and `Mail/`. Nothing else in
the profile directory is ever opened — so no enumeration of what-to-avoid is load-bearing,
and a wrong name below changes nothing.

For orientation, the profile dir (the same dir as the Gloda file) also holds
the credential/secret stores pikuri stays clear of: the NSS key/cert databases
`key4.db` + `cert9.db`, saved passwords `logins.json` + `logins-backup.json`,
and Thunderbird's OpenPGP key material (including
`encrypted-openpgp-passphrase.txt`). These names are **recalled from the
Firefox/Thunderbird profile layout, not probe-confirmed and not exhaustive**
(verify against a real profile if it ever matters — but it doesn't, given the
allowlist). Browser/telemetry cruft (`places.sqlite`, `cookies.sqlite`,
`favicons.sqlite`, `storage/`, `datareporting/`, …) is likewise untouched.

## The testbed: a real Thunderbird with no real mail (dev only)

`dev/testbed/` builds the profile this gem is tested against on the dev VM, and drives a running Thunderbird for live tests. Why it exists and why it is shaped
so: `D_thunderbird_testbed`. The scripts' headers say how to run them; this is the picture
across them.

**Setting up the dev VM.** Ubuntu packages only, plus the Thunderbird snap Ubuntu ships:

```
sudo snap install thunderbird
sudo apt install xvfb ffmpeg libreoffice dovecot-imapd
sudo systemctl disable --now dovecot.service dovecot.socket
```

`xvfb` and `ffmpeg` serve `session --display` and its screenshot; LibreOffice renders the demo
documents (`dev/demo-home/`); dovecot is the IMAP server below. Ubuntu's package enables and
starts the system dovecot on install, listening on 143 and 993 on every interface; the testbed
never uses it (it runs its own), hence the `disable --now`, which stops it, keeps it off at
boot, and stops socket activation from waking it. `ss -ltn | grep -E ':(143|993)\b'` printing
nothing confirms it.

**We write the inputs, Thunderbird writes its stores.** The builder writes only what
Thunderbird reads as input — `user.js`, mbox files, an `.ics`, and the mail an IMAP server
serves — and a real headless Thunderbird builds `prefs.js`, the IMAP offline store, the `.msf`
summaries, Gloda and `calendar-data/cache.sqlite` from them. Alex's account is IMAP
(`alex@novak.example`, the login an address as on Gmail, so its folder URIs carry `%40`),
synced from a dovecot on loopback into `ImapMail/127.0.0.1/`; it is not Local Folders, which has
no identity, so Gloda would have no "me", no Sent folder and no correspondence graph. Local
Folders holds an `Archive` (CI mail older than 90 days), so `Mail/` is a real store too. Every
domain is RFC 2606-reserved, so a Send clicked by mistake fails.

**The IMAP server: a rootless dovecot, up only during a build** (`builder/dovecot.rb`). An IMAP
folder's `.msf` and its UIDs come from the server's replies, so the mail has to be downloaded
for real (why a real server: `D_thunderbird_testbed`). Dovecot 2.4 (Ubuntu's; most guides online
are 2.3 syntax) runs as the caller with `chroot =` on the login service, only the plain `imap`
listener (port 10143, fixed because it is in `user.js` and so in the cache key), a static
passdb whose password Thunderbird gets over Marionette, and every file in one fresh `/tmp`
directory, since a socket path over 108 bytes fails. It serves **Maildir**, not mbox: its mbox
driver rewrites the file to add `X-UID`, which failed on the CRLF mbox ("Sync failed for mbox"),
and Thunderbird took the failed body fetch as success. A Maildir file is never rewritten, and
its mtime is the message's `INTERNALDATE`.

After the build nothing listens on 10143, so the account has `check_new_mail`,
`login_at_startup` and `autosync_offline_stores` off; a session on the cached profile opens no
connection at all (20 s under `MOZ_LOG`, 2026-11-15). Clicking an IMAP folder in a `--display`
session would try to connect and fail.

**The demo world** is the repo root's `dev/demo-home/`: one facts file (`facts.yml`) and the
demo `~/Documents` (`documents/`) rendered from it. The testbed reads both — the scene mail
(`mail.yml`) and the calendar from the same facts, the mail's attachments from those documents —
so its `build` writes `~/Documents` too, with the same `--today`; every date is an offset from
the build day. The dependency runs one way: the demo home knows nothing of Thunderbird. Seeded
noise (`builder/noise.rb`) gives search something to rank past. `mail.yml`'s comments say which
scene each message serves.

**Driving Thunderbird: Marionette.** Release Thunderbird ships Marionette, Mozilla's remote
protocol, and in *chrome context* — Mozilla's word for the application's own privileged JS — a
script can call Thunderbird's APIs (`MailServices`, Gloda, `cal.manager`).

- It needs `--marionette` and the env var `MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1`; on 159 the
  `--remote-allow-system-access` flag alone isn't enough. `marionette.port = 0` makes it pick a
  free port and write it to `<profile>/MarionetteActivePort`.
- The wire is length-prefixed JSON over TCP (`len:[0, id, "Name", {params}]`, reply
  `len:[1, id, error, result]`); `builder/marionette.rb` is the whole client. One WebDriver
  session at a time, so a client must `DeleteSession` before the next can connect.
- **The IMAP sync is driven too**, since with mail checks off nothing connects:
  `MailServices.imap.discoverAllFolders`, then per folder `setFlag(Offline)` and
  `downloadAllForOffline`, which selects the folder, syncs its headers and fetches every body.
  An account from `user.js` lacks the Offline flag on INBOX (the account wizard's "keep
  messages on this computer" sets it), and without it INBOX's bodies are never fetched. A
  separate `updateFolderWithListener` first is a trap: its listener heard the discovery URL end,
  the download found the folder busy, and fetched nothing without an error. So the step checks
  every header carries the Offline flag.
- **A dropped mbox is never picked up on its own:** with mail checks off nothing opens a
  folder, so no `.msf` appears and Gloda's sweep skips it (four minutes, zero rows). The index
  step reparses each Local Folders folder (`getDatabaseWithReparse`, which throws
  `NS_ERROR_NOT_INITIALIZED` to mean "reparse started") and then queues every folder
  (`GlodaMsgIndexer.indexFolder(folder, {force: true})`); `indexFolder` alone indexes
  nothing. Done is detected by count, not by Gloda's internals: the builder knows it wrote N
  messages and counts a copy of the Gloda DB until it holds N with a body — an IMAP message
  Gloda reaches before its body is offline is indexed from its headers alone, and counts too
  early.
- A clean quit is a script that resolves and then dispatches
  `Services.startup.quit(eAttemptQuit)`: about two seconds, the WAL stores checkpointed, and
  open compose windows discarded without a prompt.
- A process starts as `thunderbird` and renames itself `thunderbird-bin` once the launcher
  execs the real binary; a lookup checks both names (`pgrep -x` matches the 15-character name).
  Never `pkill -f thunderbird`: it matches the agent's own shell, whose command line holds the
  word.
- `MOZ_CRASHREPORTER_DISABLE=1`, or the crash helper creates `~/Downloads/thunderbird.tmp/`.

**Hand-offs on a headless machine.** A session started with `--display` runs on its own Xvfb
and accepts remote commands, so `DISPLAY=:N` on the agent's side makes a real hand-off land in
it (§ Hand-off mechanics). `js/compose-windows.js` reads the open compose windows back as
Thunderbird parsed them; `session screenshot` grabs the screen (`ffmpeg -f x11grab`). There is
no window manager, so windows stack; clicking goes through Marionette, not the screen.

**A quiet first run.** `user.js` carries the network prefs from Marionette's own
`RecommendedPreferences.sys.mjs` (inside Thunderbird's `omni.ja`, under
`chrome/remote/content/shared/`), among them `services.settings.server =
"data:,#remote-settings-dummy/v1"`, which stops the remote-settings fetch a plain first run
makes. `strace` can't follow into a snap without root (snap-confine is setuid), so the check is
Mozilla's logging: `MOZ_LOG="nsHostResolver:5,nsSocketTransport:5,nsHttp:3"
MOZ_LOG_FILE=~/snap/thunderbird/common/moz.log dev/testbed/build --rebuild` showed no
DNS lookup and no HTTP channel, only Marionette's loopback socket and, since the IMAP account,
dovecot's `127.0.0.1:10143` (2026-11-15, 159). Re-run it after a Thunderbird upgrade; a fetch on
a later timer would slip past a build that lasts seconds.

**Byte-stable inputs, so the cache hits.** The indexed profile is tarred under
`Paths.cache/thunderbird-testbed/`, keyed by Thunderbird's version and a digest of every input.
That needs inputs that repeat: the `mail` gem's random multipart boundaries are replaced by ones
derived from the Message-ID, zips get fixed times, and LibreOffice output (which stamps a fresh
date and ID into every PDF) is cached by source digest, under `Paths.cache/demo-home/` so the
demo home's own build reuses it. Measured on 159: 194 messages sync and index in
~9 s, a cached build takes 2 s.

**The guard.** Every demo directory carries a `.pikuri-demo` marker. The build refuses while
either root holds an unmarked profile, or while Thunderbird runs, and checks the demo home's
own guard (`~/Documents` non-empty and unmarked) before writing anything; it never deletes
anything unmarked and never stops a Thunderbird it didn't start.

**Not covered:** Gmail's own IMAP (labels as folders, `X-GM-EXT-1`), a message in two
folders, a folder synced headers-only, and the `-1` directory of a second account on one host;
`design/ideas/thunderbird-testbed-imap-scenes.md`.
