# pikuri-thunderbird — design & threat model

Audience: someone extending this gem or auditing its security posture.
Rationale for individual classes lives in their YARD headers; this file
covers the cross-cutting design and the threat model. The in-flight design
notes and still-open questions live in `ideas/thunderbird.md`.

## What it does

Gives a pikuri agent read-only access to the user's **local** Thunderbird
data — stored mail and cached calendars — by reading Thunderbird's own
on-disk profile. It never speaks IMAP/POP3/SMTP or CalDAV itself; it reads
files Thunderbird already wrote.

- **Mail** rides Thunderbird's Gloda index (`global-messages-db.sqlite`),
  which has already MIME-decoded, HTML-stripped, and split every message
  into body / subject / attachment-names / author / recipients. pikuri
  treats it as a pre-decoded corpus.
- **Calendar** reads the `calendar-data/*.sqlite` stores, whose events are
  normalized columns (no ICS parser for the common case).

## Threat model: the lethal trifecta

Email is the textbook lethal trifecta. The three legs:

1. **Private data** — the mailbox and calendars. Inherently present.
2. **Untrusted content** — every message body, subject, and attachment name
   is authored by whoever sent the mail, i.e. potentially an attacker.
   Inherently present.
3. **Egress** — the ability to send data out.

**v1 removes leg 3 entirely.** The only tools are `thunderbird_mail_search`,
`thunderbird_mail_read`, `thunderbird_calendar_search`, and
`thunderbird_calendar_read` — all inbound-only. An agent wired with just
these (plus, say, a calculator) has legs 1 and 2 but no way to send anything
anywhere, so a prompt injection buried in a message body has no exfiltration
channel. This is the same "trifecta broken by construction" posture as
`bin/pikuri-corpus` and `bin/pikuri-memory`. The bundled
`bin/pikuri-thunderbird` demo is exactly this wiring.

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
the live file. Instead {Pikuri::Thunderbird::Snapshot} takes a **bracketed
`cp --reflink=auto`**: it reads the SQLite change counter (header bytes
24–27) and checks for a rollback `-journal` before and after the copy, and
accepts the copy only if the counter didn't move and no journal was present
at either edge (otherwise it discards and retries). Reflink makes the copy a
near-free metadata-only extent share on a copy-on-write filesystem.

The validated change counter doubles as a freshness stamp: each query
compares the live counter against it and re-copies (and, for mail, rebuilds
the FTS5 index) only when it moved. One signal drives both consistency and
freshness.

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
backends touch only `global-messages-db.sqlite` and `calendar-data/*.sqlite`.

## Outbound is a human-gated v2, never an autonomous send

Composing a mail or creating a calendar event is egress (a send, an invite,
a CalDAV sync). The design invariant, locked in before any of it ships:

> **pikuri-thunderbird performs no network egress and no autonomous send.**
> Every outbound action is a hand-off to Thunderbird's own UI — a pre-filled
> compose window (via a `mailto:` URI) or an `.ics` import wizard — where the
> *human* reviews and commits. pikuri writes nothing to Thunderbird's stores
> and sends nothing itself. No send tool ever ships.

This converts egress from *agent-automatic* to *human-action-required*,
which is what keeps the trifecta broken even once compose exists.

**Compose is shipped, opt-in.** `thunderbird_mail_compose`
({Pikuri::Thunderbird::MailCompose}) is wired only when a host passes
`Extension.new(compose: true)` — default off, so the bundled
`bin/pikuri-thunderbird` demo has no egress leg *by construction* and its
"trifecta broken" claim above stays literally true. Turning compose on
re-introduces leg 3, but only as a human-committed hand-off: the tool opens a
`mailto:` compose window ({Pikuri::Thunderbird::MailtoUri} percent-encodes every
field so a body can't smuggle `&bcc=`), the body is plain-text-only (no hidden
content, no remote beacons), and a mechanical recipient guard
({Pikuri::Thunderbird::ComposeGuard}) runs first: a suspicious *body* fails
closed; suspicious/non-ASCII/punycode *recipients* are dropped for the human to
retype; a never-corresponded-with recipient domain (per
{Pikuri::Thunderbird::Gloda#domains_seen}) is flagged, not blocked. The launch
is detached (`setsid --fork`) so closing the agent never kills the user's
Thunderbird. **Create-event** (`thunderbird_calendar_create`) remains designed
but unbuilt. The full v2 rationale + open questions are in
`ideas/thunderbird.md`.

## Discovery

{Pikuri::Thunderbird::Profile} never guesses: it resolves one profile
unambiguously (parsing `profiles.ini`), raises with a fix if two install
roots both hold a profile (a stale apt profile left after an apt→snap
migration), or returns `nil` (tools simply not registered) when Thunderbird
isn't installed. An explicit `profile_dir:` override bypasses discovery.
Linux snap and apt roots are supported; flatpak is out of scope.

## Storage landscape (empirically confirmed)

The reference data the design rests on, probed against a live snap install
(Thunderbird 152.0, Linux, 2026-07). It's here — not in the class yardocs —
because it spans the whole gem and is expensive to re-derive (it needs a real,
populated Thunderbird). The per-symbol *why* lives in the class yardocs; this
is the shared evidence base, and the ground truth a v2 builder will need.

Caveat: all of this is one real install (snap; Gmail + iCloud IMAP; CalDAV
calendars). The code is otherwise tested only against synthetic fixtures built
to this schema — a first run against a real profile is still the true smoke
test.

### Profile & install roots

- `profiles.ini` is a small INI; the active profile is the `Default=1`
  section (`Path`, relative when `IsRelative=1`). The confirmed real file has
  **no `[Install…]` sections** (Firefox's per-install mechanism), so the plain
  `Default=1` scan suffices.
- Roots: **snap** `~/snap/thunderbird/common/.thunderbird/` (confirmed),
  **apt** `~/.thunderbird/` (recalled). Flatpak
  (`~/.var/app/org.mozilla.Thunderbird/…`) is out of scope.
- `.parentlock` at the profile root is Thunderbird's running-instance lock — a
  cheap "is TB open?" probe.

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
  correspondence graph (frecency/popularity). *Unused in v1;* the v2
  recipient-novelty warn will read it.
- **`attributeDefinitions` / `messageAttributes`** — extensible per-message
  attributes; ids seen: 57 `tag`, 58 `star`, 59 `read`, 60 `repliedTo`,
  61 `forwarded`. (Relevant to churn — see the change counter below.)
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

### Mail: mbox on disk (the unbuilt fallback's substrate)

Not used by v1 (Gloda serves it fully); recorded for the deferred family-B
fallback. Mail is **mbox** (extensionless files, `file(1)` "Mailbox text"),
under `ImapMail/<server>/` (IMAP, subfolders nest via `<Folder>.sbd/`) and
`Mail/` (Local Folders, Feeds); each mbox is shadowed by a `<Folder>.msf`
**Mork** summary (ignorable — Gloda has the decoded text + folder map). A
correct mbox reader would need: CRLF line endings; the dash-prefixed
`From - <ctime>` separator (not classic `From <addr>`); server-defined folder
names (Gmail INBOX is uppercase — never hardcode); and honoring the
`X-Mozilla-Status`/`Status2` **deleted-but-not-compacted** bit. `messageKey`
is *not* a universal seek offset — IMAP UID for `ImapMail/`, byte offset only
for local `Mail/` — which is why a Gloda→mbox hybrid read was rejected.

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
  defensively even though no null was observed.
- `flags` = calStorageCalendar's `CAL_ITEM_FLAG` bitfield (verify against
  comm-central at v2 impl): 2=attendees, 4=properties, **8=all-day**,
  16=recurrence, 32=exceptions, 64=attachments, 128=relations, 256=alarms,
  512=recurrence-id-all-day. **All-day = bit 8** — airtight (a clean diagonal:
  126 rows, `flags&8` ⟺ midnight-aligned start ⟺ `tz=floating`, zero
  off-diagonal). All-day DTEND is iCal **exclusive** (1-day event spans exactly
  1 day), so render `[start, end − 1 day]` and don't zone-convert.
- `ical_status`, `priority`, `privacy`, recurrence fields.

Companions: `cal_todos` (VTODO, same shape); `cal_properties(item_id, key,
value)` (DESCRIPTION, LOCATION, …); `cal_recurrence`/`cal_attendees`/
`cal_alarms`/`cal_relations`/`cal_attachments` (iCal-shaped `icalString`
fragments — parse with the `icalendar` gem only if wanted).

### SQLite locking

Thunderbird opens its DBs with `locking_mode=EXCLUSIVE`, so a plain
`-readonly` open fails *"database is locked (5)"* while it runs — **even for
WAL stores** (the calendar DBs are WAL, and WAL readers are still shut out).
`immutable=1` is the universal lock-bypass; for a WAL store it reads
as-of-last-checkpoint (Thunderbird checkpoints aggressively — right after the
62 MB sync the `-wal` held ~1 MB and `immutable=1` saw all 5414 events). This
is why {Pikuri::Thunderbird::Snapshot} works against a *copy*, not the live
file. (WAL caveat for calendar freshness: a WAL DB's change counter bumps only
on checkpoint, so calendar staleness should eventually pair the counter with
`-wal` size+mtime — deferred; v1 uses the counter.)

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
- **Create event → `.ics` import.** `thunderbird <path.ics>` opens TB's
  "Import Calendar file" wizard as a new tab (running-instance reuse): a 4-step
  flow ending in **Confirm**, with a **target-calendar picker** at step 3.
  **No silent import** — Cancel leaves nothing behind. So TB's UI owns the
  commit *and* the human picks local-vs-CalDAV (i.e. no-egress-vs-egress).

Both are the human-gated hand-off shape the no-send seam requires: pikuri
opens a window, the human reviews and commits.

### Files never touched

The guarantee is an **allowlist, not a blocklist**: the backends open only
`global-messages-db.sqlite` and `calendar-data/*.sqlite` (plus their snapshot
copies), and discovery reads `profiles.ini`. Nothing else in the profile
directory is ever opened — so no enumeration of what-to-avoid is load-bearing,
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
