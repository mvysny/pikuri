# Local Thunderbird integration

Status: **brainstorm, not started.** This note is the task description +
the open-questions register. Nothing is decided yet — the open questions
below are listed, *not* answered; we'll take them one by one. As pieces
get settled they graduate (rationale → the gem's yardoc, narrative → the
book, invariants → CLAUDE.md) and get trimmed from here, per the
graduation pipeline in [`../CLAUDE.md`](../CLAUDE.md).

## Related

- [`os-assistant.md`](os-assistant.md) — the closest shipped analog: an
  offline, Linux-desktop-specific agent that reads local files through a
  swappable, `available?`-probed backend (`localsearch`/`recoll`) and
  never egresses. Thunderbird integration has the same shape (local
  files, no network, desktop-specific), so it **mirrors** that
  backend-abstraction pattern — but lives in its own gem, not folded in
  (Q2 decided: separate `pikuri-thunderbird`, no dependency on
  `pikuri-os`).
- [`trifecta-detector.md`](trifecta-detector.md) — email is the textbook
  trifecta: **private data** (your mailbox) + **untrusted content**
  (every message body/attachment is attacker-authorable) + **egress**
  (composing/sending, creating a calendar event). Any design here is
  bounded by this note.
- [`private-context-taint.md`](private-context-taint.md) +
  [`more-confirmers.md`](more-confirmers.md) — the "human as *author*,
  not *approver*" seat. Handing a pre-filled draft to Thunderbird for the
  user to send is exactly that shape; sending it ourselves is not.

## What we want to build

A way for a pikuri agent to work with the user's **local** Thunderbird
data — reading only from Thunderbird's own on-disk profile, never
connecting to IMAP/POP3/SMTP ourselves. Requires Thunderbird installed
locally. Capabilities, roughly in priority order:

1. **Search mail** (the core ask) — find messages in local Thunderbird
   folders by sender/subject/body/date, return enough to act on, and read
   a hit in full (parent-document-retrieval shape, like
   `vectordb_search`/`vectordb_read`). Local folders only.
2. **Search calendars** *(if feasible)* — find events in Thunderbird's
   local/cached calendars.
3. **Create a calendar event** *(if feasible)*.
4. **Compose a new email and hand it off to Thunderbird** so the user
   reviews and sends it themselves (the safe, author-not-approver path).
5. **Send it ourselves** *(stretch / maybe)* — flagged as in tension with
   the no-SMTP constraint; see open questions.

Constraints given up front:

- **Local folders only.** We read Thunderbird's stored mail; we do not
  speak IMAP/POP3/SMTP.
- **Linux only**, matching the project's Linux-first posture.
- **Both snap and apt installs** must be supported (profile lives in a
  different place for each; flatpak is a third layout worth noting).

## Thunderbird storage landscape

Grounding for the questions below. This section is being confirmed
against a live install incrementally (the user runs commands, we record
anonymized results). Confirmed facts are the spec; pending facts are
marked.

### Confirmed on a real install (snap; TB on Linux, 2026-07)

Profile probed: `~/snap/thunderbird/common/.thunderbird/ql3rk8ye.default/`.

- **Profile discovery.** `~/snap/thunderbird/common/.thunderbird/profiles.ini`
  is a small INI. The active profile is the section with `Default=1`
  (here `[Profile0]`, `Name=default`, `Path=ql3rk8ye.default`,
  `IsRelative=1`). `IsRelative=1` means `Path` is relative to the
  `profiles.ini` directory; `[General] StartWithLastProfile=1` is the
  tiebreaker when several profiles exist. So discovery = parse
  `profiles.ini`, resolve `Path` (relative when `IsRelative=1`). The
  confirmed file, verbatim — note there are **no `[Install…]` sections**
  (Firefox's per-install default-profile mechanism), so the plain
  `Default=1` parse suffices:

  ```ini
  [Profile0]
  Name=default
  IsRelative=1
  Path=ql3rk8ye.default
  Default=1

  [General]
  StartWithLastProfile=1
  Version=2
  ```
- **Install-root layout (snap).** Everything lives under
  `~/snap/thunderbird/common/.thunderbird/`. (apt/flatpak roots differ —
  see "still recalled" below.)
- **Mail folders = mbox** (confirmed: extensionless files whose
  `file(1)` type is *"Mailbox text"*; each message opens with a
  `From - <ctime date>` separator line — Thunderbird's dash-prefixed
  variant, e.g. `From - Tue May 05 17:15:53 2026`, **not** the classic
  `From <addr> <date>`). **No maildir** on this box. Two mail trees:
  - `ImapMail/<server>/` — one dir per IMAP account
    (`imap.gmail.com/`, `imap.mail.me.com/`). Subfolders nest via
    `<Folder>.sbd/` directories; each folder is an extensionless mbox
    file shadowed by a `<Folder>.msf` **Mork** summary index
    (*"Mozilla Mork database, version 1.4, Mail Summary file"*). There's
    also an account-root summary one level up (`ImapMail/imap.gmail.com.msf`).
  - `Mail/` — non-IMAP accounts: `Mail/Local Folders/`, `Mail/Feeds/`.
  Implication: the folder→file walk is `{ImapMail,Mail}/*/` then recurse
  through `*.sbd/`, treating each extensionless (non-`.msf`) file as an
  mbox; `.msf` (Mork) can be ignored and the mbox re-scanned instead of
  parsing Mork.
- **mbox parsing quirks (confirmed on `INBOX`):**
  - **Folder file names are server-defined, not fixed** — the Gmail inbox
    file is `INBOX` (uppercase), not `Inbox`. Never hardcode canonical
    folder names; enumerate what's on disk. Special-folder identity
    (which file is Sent/Drafts/Trash) is a mapping to resolve later, not
    a name to assume.
  - **CRLF line endings** — lines end `\r\n` (the `^M` before each break).
    The parser/splitter must not assume `\n`-only.
  - **Thunderbird injects `X-Mozilla-Status` / `X-Mozilla-Status2`
    headers** at the top of each stored message (before the real RFC 5322
    headers) — per-message flag bitfields (read/unread, and a
    **deleted-but-not-yet-compacted** bit). A correct reader parses these
    to skip messages flagged deleted, since Thunderbird leaves them in the
    mbox until folder compaction. Bears on Q11.
- **Gloda full-text index — schema confirmed** (`global-messages-db.sqlite`,
  command #4). It's a real, complete search index:
  - **`messagesText`** — FTS3 virtual table over five columns:
    **`body`, `subject`, `attachmentNames`, `author`, `recipients`**.
    Thunderbird has already MIME-decoded, HTML-stripped, and extracted
    each — including *attachment file names*. Backing store is
    **`messagesText_content(docid, c0body, c1subject, c2attachmentNames,
    c3author, c4recipients)`** with the raw decoded text per column.
  - **`messages`** — `id` (= FTS `docid`), `folderID`, `messageKey`,
    `conversationID`, `date` (**PRTime = µs since epoch**, confirmed
    — ÷1e6 for Unix seconds, stored at second granularity),
    `headerMessageID` (the RFC822 `Message-ID`), **`deleted`** flag
    (confirmed present + populated), `jsonAttributes`, `notability`.
    Indexed on `(folderID, messageKey)`, `headerMessageID`, `date`,
    `deleted`.
  - **`messageKey` semantics are folder-type-dependent** (confirmed by
    query (c): folderID 18 had keys `26449`/`26450` — *consecutive
    integers*, impossible for mbox byte offsets). It's the nsMsgKey =
    the **IMAP UID** for `ImapMail/` folders, and a **byte offset** only
    for local `Mail/` mbox folders. So there's no single "seek by
    messageKey" that works everywhere — see the hybrid caveat in Q1.
  - **`folderLocations`** — `folderID` → `folderURI` + `name`, so a hit
    resolves to its folder (and thence the mbox file on disk).
  - **`conversations` / `conversationsText`** — threading (subject FTS).
  - **`contacts` / `identities` / `contactAttributes`** — the email↔name
    graph with popularity/frecency (could resolve "mail from Bob").
  - **`attributeDefinitions` / `messageAttributes`** — Gloda's extensible
    per-message attributes (tags, starred, …).
  - Ignore: `imConversations*` (chat/IM logs), `ext_mimeTypes`.

  **Sharp edge — `tokenize mozporter`.** Both FTS tables use Mozilla's
  *custom* tokenizer, so a stock `sqlite3` (CLI **or** the Ruby `sqlite3`
  gem) **cannot** run `… MATCH …` — it errors *"unknown tokenizer:
  mozporter"*. (`.schema` works because it only reads `sqlite_master`.)
  Escape: query the plain **`messagesText_content`** columns
  (`c0body` …) directly with `LIKE`/our own matcher — no tokenizer, no
  `MATCH`. So Gloda is usable externally as a *pre-decoded corpus*, just
  not as a drop-in FTS engine. **Both confirmed** (commands (a)/(b)):
  `MATCH` errors *"unknown tokenizer: mozporter"*, and a
  `messagesText_content … c0body LIKE '%invoice%'` scan returned 234
  hits cleanly.
- **Calendar store — schema confirmed, data story corrected** (probed
  2026-07-14: schema battery via `immutable=1` with TB stopped; the
  lock matrix re-verified with TB running). It's **three sibling
  DBs** under `calendar-data/`, not one: `local.sqlite` holds only
  **`storage`-type (local) calendars**; **`cache.sqlite`** is where
  cached network calendars would land; `deleted.sqlite`
  (`cal_deleted_items`) is sync tombstones. **On the probed box all
  three hold zero events:** the one local calendar ("Home") is unused,
  and every CalDAV calendar has **`cache.enabled=false`** in prefs.js →
  TB keeps those events **in memory only — nothing on disk to read**,
  even while the TB UI shows fully-populated calendars (the trap this
  finding names). Verified exhaustively: every table 0 rows except the
  two version singletons; the 819 KB file is pure schema overhead
  (Mozilla builds with **32 KB pages** — 25 × 32768 exactly, freelist
  0); `deleted.sqlite` tombstones also 0, so no events ever lived here.
  So calendar tools are data-dependent: they need a used local calendar
  or per-calendar "Offline Support" (cache.enabled) turned on — a
  one-click fix (confirmed 2026-07-14: enabling it on the real CalDAV
  calendars populated cache.sqlite to 62 MB / 5 414 events within
  minutes; it **mirrors local.sqlite's schema exactly**, same
  `cal_calendar_schema_version=23`, all cached calendars in the one DB
  partitioned by `cal_id`). Locking matches Gloda, not the WAL hope: a plain
  `-readonly` open fails **"database is locked (5)" while TB runs even
  though the DB is WAL** (mozStorage opens with
  `locking_mode=EXCLUSIVE`); `immutable=1` bypasses it fine. Version
  anchor: **`cal_calendar_schema_version` = 23** (`user_version` is 0 —
  unlike Gloda, gate on the table, not the pragma). Schema
  (`local.sqlite`, classic `calStorageCalendar`):
  - **`cal_events`** — normalized columns, *not* opaque ICS: `cal_id`,
    `id` (event UID), `title`, `event_start` / `event_end` (INTEGER
    **PRTime µs, stored as the UTC instant** — confirmed on 5 414 real
    events: the µs reading gives a sane 2010→2031 histogram (ms/s
    overflow to NULL), and the next-8-events cross-check reads as
    normal business hours only under UTC→local (+3h EEST) — 07:00 UTC =
    10:00 Helsinki — so times are stored UTC and **displayed via the
    `_tz` column**, the standard Mozilla convention. Both endpoints
    carry their own tzid — `event_start_tz` / `event_end_tz` — and
    **they can differ** (1/5414: a cross-zone event like a
    Helsinki→NYC flight), so treat them independently, never "one zone
    per event." The tzid is a **string in several valid forms, none of
    it junk:** Olson/IANA names (`Europe/Helsinki` dominant), the
    literal **`floating`** (= no zone, wall-clock; **every all-day
    event uses it** — the 126 `floating` rows *are* the 126 all-day
    rows), **`UTC`**, and rare **fixed-offset forms** (`GMT+0300` =
    EEST, from a client lacking the Olson name — *not* corruption); no
    null/empty tz observed, but a robust reader still defaults
    defensively. `ical_status`, `priority`, `privacy`, `flags`,
    `time_created`, `last_modified`, recurrence fields. So basic reads
    (title/when/status) are a plain `SELECT` — no ICS parser needed.
    `flags` decodes as calStorageCalendar's `CAL_ITEM_FLAG` bitfield
    (recalled mapping, consistent with all observed combos — verify
    against comm-central at implementation): 2=attendees,
    4=properties, **8=all-day**, 16=recurrence, 32=exceptions,
    64=attachments, 128=relations, 256=alarms, 512=recurrence-id
    all-day. **All-day detection = bit 8** (confirmed airtight: a clean
    diagonal — `flags&8` set ⟺ midnight-aligned start, 126 rows, zero
    off-diagonal), never span heuristics. All-day dates are **zoneless
    (`floating`) UTC-midnight starts with an exclusive DTEND** (a 1-day
    event's `event_end - event_start` = exactly 1 day, iCal-style), so
    render an all-day span as `[start, end − 1 day]` and don't
    zone-convert it.
  - **`cal_todos`** — VTODO tasks, same shape (`todo_entry`/`todo_due`/
    `todo_completed`).
  - **`cal_properties(item_id, key, value)`** — the per-event extras
    (DESCRIPTION, LOCATION, …) as key/value.
  - **`cal_recurrence` / `cal_attendees` / `cal_alarms` / `cal_relations`
    / `cal_attachments`** — the genuinely iCal-shaped parts stored as
    `icalString` fragments (RRULE, attendees, VALARM) — parse only if
    wanted (the `icalendar` gem).
  - `cal_id` = the calendar's **registry UUID** (confirmed): prefs.js
    `calendar.registry.<uuid>.{name,type,uri,cache.enabled}` maps it to
    the human-readable name + `storage`/`caldav` type — name/type
    resolution reads prefs.js, exactly as Q13 anticipated.
- **Address book is SQLite, not Mork:** `abook.sqlite` + `abook-1/-2`
  (each with `-wal`) — modern schema; no legacy `.mab`.
- **Most SQLite DBs run in WAL mode** (pervasive `-wal`/`-shm` siblings:
  calendar `local.sqlite`, `abook*.sqlite`, …) — but WAL does **not**
  buy live readonly access: TB locks them anyway (probed 2026-07-14:
  plain `-readonly` on the calendar DB → "database is locked (5)" while
  TB runs; mozStorage opens with `locking_mode=EXCLUSIVE`, which shuts
  out WAL readers too). `immutable=1` is the universal bypass.
  **Gloda is the exception:** `global-messages-db.sqlite` has **no**
  `-wal` sibling and a plain `sqlite3 -readonly` open **fails with
  "database is locked" while Thunderbird is running** (confirmed
  2026-07). `PRAGMA journal_mode` = **`delete`** (classic rollback
  journal, not WAL) confirms why; `PRAGMA user_version` = **`30`** (a
  schema-version anchor Gloda-reading code can gate on and fail loud if
  it drifts). So TB holds a blocking lock — Gloda reads live only via a
  lock-free `immutable=1` open (torn-read risk) or with TB closed. This
  is a real strike against the "query Gloda" option (Q1), since the user
  normally has TB open exactly when searching mail. (Resolved: Q11
  sidesteps live SQL entirely — a settled *snapshot copy*, bracketed by
  the change counter, is what gets queried.)
- **`.parentlock`** at the profile root is Thunderbird's running-instance
  lock — a cheap "is TB open right now?" probe.
- **Compose hand-off works** (TB 152.0, snap; command #6). `thunderbird
  -compose "to='…',subject='…',body='…'"` opens a pre-filled compose
  window and **reuses the already-running instance** (no duplicate, no
  complaint). **Single-quoting each value** is the correct escaping: a
  comma inside the subject survived as one field, and punctuation
  (em-dash, period) came through intact. Only output was a harmless
  `Gtk-Message: … Not loading module "atk-bridge"` warning. Nothing is
  sent — the user reviews and sends. (Still untested: embedding
  **newlines** in `body` — a known `-compose` limitation; see Q8.)
- **Credential/secret stores to never touch** (they sit in the same
  profile dir): `logins.db` / `logins.json` / `logins-backup.json`,
  `key4.db`, `cert9.db`, `openpgp.sqlite`,
  `encrypted-openpgp-passphrase.txt`, `settings/data.safe.bin`. Any
  file-access scoping for this feature must be confined to the mail +
  calendar + address-book stores and exclude these — bears on Q10.
- **Ignore (browser/telemetry cruft, not mail):** `places.sqlite`,
  `favicons.sqlite`, `cookies.sqlite`, `formhistory.sqlite`,
  `content-prefs.sqlite`, `webappsstore.sqlite`, `storage/`, `crashes/`,
  `minidumps/`, `datareporting/`, `saved-telemetry-pings/`.

### Still recalled / pending confirmation (commands 3+)

- **apt/deb root:** `~/.thunderbird/<hash>.default*/`; **flatpak root:**
  `~/.var/app/org.mozilla.Thunderbird/.thunderbird/<hash>.default*/`
  (only the snap root is confirmed).
- **Calendar detail** — `event_start` time encoding (Gloda uses PRTime µs;
  calendar very likely the same by Mozilla convention, but unverified) +
  `_tz` handling, and how `cal_id` separates local vs. cached-CalDAV
  calendars.
- **`-compose` newlines** — embedding real newlines in `body` (known
  `-compose` limitation; single-line worked). Bears on Q8.
- **Concurrency detail** — mbox read-while-TB-compacts safety.

## Open questions (list only — do not resolve here)

Take these one at a time in later sessions.

1. **Search backend — parse ourselves, query Gloda, or recoll?**
   **DECIDED (v1, empirical — measured on a real 700 MB / ~10-year
   mailbox, 2026-07): family A, Gloda-only** (search *and* read from the
   decoded columns), with **family B (mbox-parse) as the
   `available?`-probed fallback** for Gloda-disabled / non-GNOME hosts —
   the exact `localsearch → recoll` pattern from `pikuri-os`. The
   measurements that settled it:
   - **Fresh:** Gloda's newest message was minutes old, oldest 2016 —
     Thunderbird keeps it live, so we inherit freshness for free (Q12
     doesn't bite family A).
   - **Full bodies present:** `messagesText_content.c0body` had only 17
     empty rows of 8084, max 58k / avg 4.4k chars — the decoded body is
     really stored, so Gloda-only serves *reads*, no mbox parse needed.
   - **Index beats scan at this size:** 700 MB on disk → a raw family-B
     grep is ~0.5–1 s/query and worsens over time; Gloda is a prebuilt
     index. (Small mailboxes would let B off the hook — but not this one.)
   - **Gloda's exclusions align with ours:** 7 folders are `-1`
     never-indexed (Gloda's sentinel) — almost certainly Spam / Trash /
     Gmail "All Mail" (the dup folder), i.e. the folders Q10 skips anyway.
   Caveats, now resolved/refined by the `folderLocations` dump:
   (a) **the 7 excluded folders are entirely benign** — all Trash / Spam
   / Junk / Unsent across the three accounts (`local Trash`, `local
   Unsent Messages`, `IMAP Deleted Messages`, `IMAP Junk`, `Gmail Trash`,
   `Gmail [Gmail]/Spam`, `Feeds/Trash`); no real-mail folder is excluded.
   **Synergy:** Gloda already *never indexes* Spam/Junk/Trash, so Q10's
   "skip Spam" untrusted-leg attenuation is **free on the Gloda path** —
   we inherit it, don't build it (the mbox fallback would have to
   replicate it). (b) **searchable set ~8084 vs ~11 655 on-disk** — the
   gap is those never-indexed folders + any not-yet-downloaded IMAP
   bodies; fine for v1.
   - **Gmail label→folder dedup (implementation note).** Gmail exposes
     each label as an IMAP folder, so a message with N labels appears in
     N folders → N Gloda rows. Search must **dedup by `headerMessageID`**
     (the RFC Message-ID, which Gloda stores). Also verify `[Gmail]/All
     Mail` isn't subscribed+indexed (it would duplicate nearly
     everything); not among the `-1` set here, but confirm it's simply
     absent rather than indexed at prio 20.

   The families below are kept for the record (they bound the decision
   and document the dead-ends); the *decision* above supersedes them.
   Candidate approaches, grouped into four families (the fuller menu
   below folds in web-Claude's suggestions — several land in buckets we
   already had; two are new; two are recorded *as* dead-ends so we don't
   re-litigate them):

   **A. Reuse Thunderbird's own Gloda index (`global-messages-db.sqlite`).**
   TB has *already* decoded bodies + attachment names + author/recipients
   and keeps them fresh for free. Now-known costs (confirmed above):
   (i) **locked while TB runs** → live reads need `immutable=1`
   (torn-read risk); (ii) **`mozporter` blocks external `MATCH`** → we
   read the plain `messagesText_content` columns with our own matcher,
   not the FTS; (iii) undocumented schema, but `user_version=30`-gateable;
   (iv) depends on Gloda being enabled + caught up (indexing lag) + honoring
   the `deleted` flag. Two shapes:
   - **Gloda-only** (find *and* read from the decoded columns) — no mbox
     parsing at all; costs: no raw message/attachments, the `immutable=1`
     lock dance.
   - **Hybrid: Gloda to *find*, mbox to *read*.** Search the decoded
     columns, get `folderID` + `headerMessageID`, then pull the
     authoritative full message from the mbox. **Read-path caveat (query
     (c)):** `messageKey` is *not* a universal byte offset — IMAP UID for
     `ImapMail/` folders (no clean seek), byte offset only for local
     `Mail/` folders; so IMAP lookup is by `Message-ID` (scan/one-time
     index) or the Mork `.msf` UID→offset map we hoped to skip. Dulls the
     appeal vs. Gloda-only unless we specifically want raw
     headers/attachments.

   **B. Scan/parse the mbox directly** (no Gloda dependency — no lock, no
   `mozporter`, works even with Gloda disabled). Three grades:
   - **Ruby parse** (`mail` gem for RFC 5322 + a `From `-splitter honoring
     CRLF + `X-Mozilla-Status` deleted flags) — full control, in-process,
     no external dep; but we own MIME decoding *and* the search (grep-grade,
     or build/maintain our own index → a freshness daemon, Q12) *and*
     attachment extraction.
   - **raw `grep`/`ripgrep`** over the mbox files — zero setup, zero index,
     but **line-oriented and structure-blind**: no message boundaries, and
     it misses base64/quoted-printable bodies (won't decode
     transfer-encodings) and can't do headers-aware matching. A crude
     fallback, not a real search.
   - **message-aware mbox CLI (`grepmail` / `mboxgrep`)** — purpose-built,
     parse message boundaries + match headers/body per-message. Better than
     raw grep, but still a **linear scan** (no index) and a **non-Ruby
     system dependency** — against the self-contained/audit posture when we
     could parse mbox in Ruby ourselves. Record as considered.

   **C. Third-party mail indexer.**
   - **recoll** — has a Thunderbird/mbox filter; indexes subject/body/
     **attachment bodies**, CLI via `recollq` (already used by `pikuri-os`)
     or `recoll -t`. Cost: user installs + configures + builds an index
     (same trade-off as the OS assistant's `Recoll` backend).
   - **notmuch** — fast Xapian indexer, but **Maildir-oriented**; mbox
     support is poor (it wants one-file-per-message). Our storage is mbox,
     so notmuch is a **poor fit** without converting to maildir — recorded
     as a near-dead-end for this storage shape.

   **D. Desktop file indexer — GNOME Tracker / `localsearch`** (the
   `pikuri-os` file-index backend). **Poor fit for mail, twice over:**
   (i) it doesn't index the snap Thunderbird path by default, and (ii)
   even if pointed at it, Tracker has **no mbox awareness** — it'd treat a
   folder file as one opaque text blob (or mime-gate it out), never
   per-message. So the `pikuri-os` `localsearch`/`recoll` pair does *not*
   transfer to mail as-is; only its *recoll* half (family C) is relevant.
   Recorded as a dead-end to stop the "reuse pikuri-os's indexer" reflex.

   Cross-cutting: single approach, or a swappable `available?`-probed
   backend like `pikuri-os`'s file-index pair (e.g. Gloda-when-present,
   mbox-parse fallback)? And Q12 (freshness) only bites family B's
   own-index arm — Gloda, recoll, notmuch each manage their own.

2. **Placement — DECIDED: a new `pikuri-thunderbird` gem** shipping an
   opt-in `Thunderbird::Extension` + tools, with its **own
   `bin/pikuri-thunderbird` demo** (search-only + no-egress first, which
   sidesteps Q10 until its posture is settled). Chosen over folding into
   `pikuri-os` for four reasons: (i) mbox/MIME/SQLite parsers are attack
   surface for *untrusted* email content, which must not land in the
   deliberately-minimal audit-first OS gem; (ii) the new deps (SQLite
   access, a mail parser, maybe `icalendar` — none exist in the project
   today) don't belong in `pikuri-os` or core; (iii) different *purpose*
   (OS diagnosis vs. personal comms/PIM) → different gem, per the
   one-gem-per-domain precedent; (iv) email's trifecta earns its own
   `DESIGN.md` threat model (like `pikuri-memory` / `pikuri-vectordb`).
   **Mirror, don't depend on, `pikuri-os`:** reuse its swappable
   `available?`-probed backend *pattern* (the `LocalSearch`/`Recoll`
   duck type) for the Q1 search families, but take no dependency — both
   stay independently-wireable extensions that compose on one agent.
   Follow-on opens spun out of this: the `sqlite3` *gem* vs. shelling out
   to the `sqlite3` CLI through the existing `Subprocess` chokepoint (a
   Q1-implementation detail — the CLI route avoids a native-extension
   dep); and the exact gem dep set (`pikuri-core` certainly;
   `pikuri-extractors`/`-pdf` only if we extract attachment bodies, Q5;
   `pikuri-subagents` only if Q10 wants a quarantined reader).

3. **Profile/install discovery — DECIDED (v1).** One rule at every
   level: **discovery never guesses** — it succeeds unambiguously, raises
   with instructions, or is explicitly overridden.
   - **Roots probed:** snap (`~/snap/thunderbird/common/.thunderbird/`,
     confirmed) + apt (`~/.thunderbird/`, recalled). **Flatpak deferred**
     — root recalled but unconfirmed; add when someone actually runs a
     flatpak TB.
   - **Both roots exist → raise**, naming both paths and telling the user
     to delete the obsolete one. Rationale: an apt→snap migration leaves
     a stale-but-plausibly-active `~/.thunderbird` behind, so any
     mtime/liveness heuristic would guess wrong on exactly the common
     case; the fix (delete the stale folder) is trivial and one-time.
   - **No root → the tools simply aren't registered** (the
     `available?`-probed `Os::Extension` pattern). A tool constructed
     anyway with a nil/dummy profile path raises — errors are loud, no
     limping.
   - **Within a root:** parse `profiles.ini`, take the `Default=1`
     section, resolve `Path` per `IsRelative`. Multiple profiles with no
     `Default=1` → raise naming the candidates. The confirmed
     `profiles.ini` (verbatim in the storage section above) has **no
     `[Install…]` sections**, so the plain `Default=1` parse suffices —
     revisit only if a real-world TB ini shows one.
   - **Escape hatch: explicit `profile_dir:`** on both the Extension and
     the tool constructors — auto-discovery stays the zero-config
     default, and both raise cases (plus the flatpak deferral) become
     resolvable without deleting anything. Pre-shapes Q8's
     binary-discovery answer (same override pattern for the
     `thunderbird` executable).

4. **Mail format coverage.** mbox is the default; do we also handle
   maildir? What about `.msf` (ignore and re-scan, or read the Mork
   index)?

5. **Attachments.** Do we search/read attachment *bodies* (reusing
   `pikuri-extractors`)? Coverage differs sharply by Q1 family: recoll
   (C) indexes attachment bodies for free; Gloda (A) gives attachment
   *names* only (`attachmentNames` column), not bodies; mbox-parse (B)
   we'd have to extract them ourselves via `pikuri-extractors`. So the
   attachment answer is partly downstream of the backend choice.

6. **Calendar read.** *Schema feasible; on-disk data availability is
   the real gate* (probe 2026-07-14). Core event fields are normalized
   columns → a plain `SELECT` on `cal_events` (no ICS parser for the
   common case; `icalendar` gem only for `icalString` fragments), and
   reads ride Q11's snapshot path (the live-WAL-read idea is falsified
   — see Q11 / the storage section).
   - **Answered — `cal_id`:** it's the calendar's registry UUID;
     prefs.js `calendar.registry.<uuid>.{name,type,uri,cache.enabled}`
     resolves human name + `storage`(local)/`caldav` type.
   - **New finding — the data gate:** `local.sqlite` holds only
     local-type calendars (probed box: zero events), and non-cached
     CalDAV calendars (`cache.enabled=false` — all five on the probed
     box) keep events **in memory only, nothing on disk**. Cached ones
     would land in the sibling `cache.sqlite` (0 bytes here). So the
     calendar tools need an `available?`-style data probe:
     **DECIDED — actionable-empty over silent-absent:** the calendar
     tools **register regardless**, and when the on-disk corpus is
     empty (all calendars memory-only) they return a *helpful
     observation* — "no calendar events are cached to disk; enable
     Offline Support on each calendar (right-click → Properties →
     Offline Support) so they can be searched" — rather than silently
     returning nothing or not registering. The empty state is thus
     self-explaining and self-fixing (the user's one-click fix,
     confirmed to populate `cache.sqlite`). **Two layers:** the fact
     also lives in the calendar tools' `description:` — so the LLM
     knows it *upfront* and can guide the user proactively when they
     merely ask "why can't you find my events?", before any empty
     search fires; the runtime observation is the after-the-fact
     backstop. (Description-level mechanics are fine per the tool-doc
     convention — this is the tool's own doc, not a main prompt.)
     Contrast the mail path:
     it stays `available?`-gated on the Gloda file existing, because
     mail has no equivalent one-click enable — absence there is
     genuinely "not available," not "flip a setting."
   - **Answered (2026-07-14, real CalDAV data in cache.sqlite after
     flipping Offline Support):** encoding = **PRTime µs** (strong: a
     clean 2010→2031 histogram, ms/s overflow to NULL); `_tz` = valid
     tzid strings in several forms (Olson / `floating` / `UTC` /
     fixed-offset `GMT±HHMM`), all meaningful — see the storage
     section; all-day = **`flags` bit 8** (correlates perfectly with
     midnight-aligned whole-day spans in the probe), never span
     heuristics; `cache.sqlite` = exact schema mirror of `local.sqlite`
     (version 23).
   - **Closed by the follow-up probe (2026-07-14):** (i) `event_start`
     is the **UTC** instant, displayed via `_tz` (next-8 events read as
     business hours only under UTC→local); (ii) all-day `event_end` =
     iCal **exclusive** DTEND (1-day span = exactly 1 day); (iii) no
     null/empty `_tz` on this box (default defensively anyway). Bonus:
     start/end tz can differ (cross-zone events — handle independently),
     and all-day ⟺ `flags` bit 8 ⟺ `tz=floating`. **Q6 fully closed.**
     (Only-if-refuted: if TB actually shows those events at 07:00 not
     10:00, (i) flips to local storage — but the pattern makes UTC
     near-certain.)

7. **Calendar event creation.** The schema makes the *hazard* concrete: a
   direct DB write is just SQL, but `local.sqlite` is WAL and **TB holds
   it open** — a live write is invisible to the running TB's in-memory
   cache and can be clobbered, and a write to a *cached-CalDAV* calendar
   would never sync back. So the candidates are: (a) **hand TB an `.ics`
   to import** (the safe analog of the compose hand-off — TB owns the
   write + any sync); (b) direct DB write **only with TB closed**;
   (c) out of scope. CalDAV write over the network stays out of scope by
   the no-network rule. Leaning (a), but recorded as open.

8. **Compose hand-off mechanics.** *Core mechanics confirmed* (see the
   storage section): single-quoted `key=value` values escape correctly
   (comma in subject + punctuation survive), snap TB reuses the running
   instance, nothing is sent. Residual opens: embedding **newlines** in
   `body` (known `-compose` limitation — needed for a real draft body);
   **attachments** (`attachment=` URL/path field); **HTML vs. plain**
   body; and the **flatpak** invocation (only snap confirmed). Also: does
   the caller need to *find* the right binary (snap vs. apt vs. flatpak
   `thunderbird`), mirroring the profile-discovery problem (Q3)?

9. **"Send it ourselves" — is it even possible without SMTP?**
   Thunderbird's CLI only *opens* a compose window; there's no documented
   send-without-click. So "sending ourselves" seems to require either
   SMTP (explicitly excluded) or UI automation (fragile, out of posture).
   Decide whether this capability survives at all, or collapses into #4
   (compose hand-off, user sends).

10. **Security / trifecta posture.** Email is the textbook lethal
    trifecta (see [`trifecta-detector.md`](trifecta-detector.md)). Map
    the three legs onto this agent:
    - **Private (leg 1):** the mailbox + calendar — inherently yes.
    - **Untrusted (leg 2):** email bodies + attachments are
      attacker-authorable — inherently yes. *Attenuation you flagged:*
      **skip the Spam/Junk folder** — the densest attacker-controlled
      subset (unsolicited mail from arbitrary senders). Real defense in
      depth, but it **attenuates, doesn't sever** leg 2: a *targeted*
      injection lands in the Inbox (a reply, a forward, a newsletter, a
      calendar invite), not in Spam. Record it honestly as a mitigation,
      never sold as a boundary. **Free on the Q1 Gloda path:** Gloda
      already `-1` never-indexes every Spam/Junk/Trash folder (confirmed
      in the `folderLocations` dump), so the search backend simply can't
      return them — no per-account Junk-folder identity to compute. The
      mbox-parse *fallback* would have to replicate the skip explicitly.
    - **Egress (leg 3):** search + read are **inbound-only** (no egress);
      only **compose** (send) and **create-event** (invites / CalDAV
      sync) are egress. Note create-event *is* egress when the event has
      attendees (TB mails invites) or lands on a synced CalDAV calendar.

    **v1 = the decided posture: search-only + no-egress** (Q2's demo).
    Legs 1+2 present, leg 3 absent → trifecta broken by construction,
    the *exact* model as `bin/pikuri-corpus` (vectordb) and
    `bin/pikuri-memory`. Cleanly shippable now, no new machinery.

    **Adding egress later — your second insight: human-gated by
    construction.** Never write the mbox / calendar DB ourselves; every
    mutation is handed to **Thunderbird's own CLI** (`-compose` window;
    `.ics` import) where TB opens a window and **the human reviews the
    recipient + body and clicks Send/Save**. This converts egress from
    *agent-automatic* to *human-action-required* — the agent alone cannot
    exfiltrate. It's precisely the shipped `pikuri-os` posture (network
    severed for the agent; the one egress path — the `RESEARCHER` task —
    is human-confirmed and *authored*, not rubber-stamped; see the
    `bin/pikuri-os-assistant` wiring and
    [`private-context-taint.md`](private-context-taint.md) §"the human is
    the only clean post-taint egress").

    **Why the compose gate is a *stronger* human barrier than bash /
    web-search** (the full principle now lives in
    [`more-confirmers.md`](more-confirmers.md) §"The barrier is not
    uniform"). Confirmer strength varies by action, on three compounding
    axes, and email is at the strong end of all three: **rare** (few mails
    sent → no fatigue, unlike bash's 40-a-session), **fully legible**
    (natural-language recipient/subject/body the human actually
    understands, unlike an opaque pipeline), and **ceremonial /
    irrevocable** (sending is weighty and unrecallable, so people re-read
    meticulously — whereas `web_search` reads as harmless and gets waved
    through). So leaning on the compose gate is not a cop-out; it's the
    strongest human barrier available.

    **The knife-edge that keeps this open, not closed** (from
    [`more-confirmers.md`](more-confirmers.md) /
    [`assistant.md`](assistant.md) §"forced-authorship handoff"): the
    strength above holds only if the human **authors**, not
    **rubber-stamps** — and it comes with a sharp caveat. Ceremony is a
    *quality-assurance* mindset (make the mail **good**), not a
    *security-audit* one (detect exfil): a meticulous re-read catches a
    blatantly-wrong recipient (`to=attacker@evil.com`) and gross gibberish,
    but **not** secrets laundered into plausible prose, nor a subtle
    channel (BCC, Reply-To, look-alike domain). So the barrier is strong on
    the **recipient** + **gross** content, soft on **subtle body-exfil** —
    and per private-context-taint's fetch analysis the **recipient is the
    attack**, which the ceremony guards well. The corollary that resolves
    the pre-fill question below: **a fully pre-filled polished draft erodes
    the ceremony** (flips author→editor, invites "looks good, send"), so
    the strength premium is *conditional on not fully pre-filling*.

    **Mechanical outbound guard on the recipient — the machine covers the
    invisible, the human covers the visible.** The "look-alike domain" hole
    above is the *one* soft spot with a cheap, deterministic fix (a
    mechanical check, never an AI verdict — consistent with the project's
    "code + human decide" invariant). Two layers:
    - **Everywhere (subject/body/address): route through
      {Pikuri::Sanitizer}** — neutralize/flag control bytes, bidi,
      zero-width, and mixed-script welds (`Pаypal`). The body keeps
      legitimate Unicode (emoji, accents); Sanitizer flags only the attack
      classes.
    - **Address fields only (`to`/`cc`/`bcc`/`reply-to`): additionally
      enforce ASCII-only.** This closes exactly the confusable class
      Sanitizer *declares out of scope* — whole-script homoglyphs and
      Latin-diacritic look-alikes like **`@mícrosoft.com`** (`í` is Latin,
      so there's no script-mix for Sanitizer to catch). It's affordable
      *because it's scoped to the address*: ASCII-only wrongly rejects rare
      internationalized (EAI / RFC 6531) addresses, but the fallback is
      "the human types it in TB," and ASCII-only on free-text body would be
      absurd (kills emoji/accents). So the field where the blunt rule has
      tolerable false positives is exactly the field that needs it.

    **Degrade gracefully, don't silently clear:** on a flagged recipient,
    *omit it* from the `-compose` pre-fill (keep subject/body) and return
    the offense as a loud observation. The human lands in Thunderbird with
    a **blank To they must fill** — the forced-authorship seat again; the
    spoof degrades into "type the recipient yourself."

    **Honest residual — pure-ASCII look-alikes.** `rnicrosoft.com` (rn→m),
    `microsoft.net` (TLD swap), `paypa1.com` (l→1) are all pure ASCII —
    neither Sanitizer nor the ASCII rule catches them; they stay the
    human's job (the ceremony guards the *visible*, which is what these
    are). Deferred data-driven enhancement: **flag a recipient domain the
    user has never corresponded with**, read cheaply from Gloda's
    `contacts`/`identities` table.

    Open sub-questions this raises:
    - Does compose pre-fill the body at all? Purest authorship = hand off
      an empty/subject-only draft the human writes; convenience =
      pre-filled draft the human edits (rubber-stamp risk). The reasoning
      above *leans against* a full pre-fill (it spends email's ceremony
      premium), but the exact middle ground — subject-only? a bullet
      skeleton the human prose-ifies? — is the open knife-edge decision.
    - Is CLI-hand-off + search-only-first enough for v1, or do we also
      need the (still-unbuilt) taint/detector machinery to gate a
      combined-legs wiring? When compose *is* wired, the trifecta
      detector should tag compose/create-event `:egress` and
      mail-read `:untrusted`+`:private` — the agent would then trip the
      all-three warning, correctly.
    - The residual is honest: human-gated ≠ severed. Document as a
      smoke-alarm-grade improvement, not a firewall.

11. **Concurrency with a running Thunderbird — DECIDED (amended
    2026-07-14): settled-snapshot copies for BOTH Gloda and the
    calendar DBs.** (The original "live WAL reads for the calendar" arm
    is falsified — see the calendar bullet below.) Headline
    simplification: we **never run queries against the live Gloda** —
    the only live-file touch is a bracketed `cp --reflink` copy (below),
    and every actual query runs on the settled on-disk snapshot we own.
    The `immutable=1` sharp edges are sidestepped entirely: the copy is
    reflink/byte-level, not a SQL read, and the bracket catches any
    torn copy.
    - **Why Gloda tears but the calendar doesn't.** In rollback-journal
      mode (Gloda's confirmed `journal_mode=delete`) a writer modifies
      the *main DB file in place, mid-transaction* — the `-journal`
      holds the *old* pages for undo; commit = journal delete. So the
      file is transiently inconsistent for the whole write, and only the
      locking protocol protects readers; TB holds that lock persistently,
      and `immutable=1` works precisely by *bypassing* locks — i.e.
      forfeiting the one protection. Torn reads manifest as (A) loud
      errors (`SQLITE_CORRUPT` "malformed", `SQLITE_IOERR_SHORT_READ`),
      (B) silent snapshot skew (JOIN orphans — a `messages` row whose
      `messagesText_content` partner is older; missing/duplicated rows
      when a B-tree rebalances mid-scan) — plausible-looking,
      undetectable from results, and (C) garbled long bodies
      (overflow-page chains mixing generations; often invalid UTF-8 or a
      corrupt error, sometimes plausible garbage). WAL inverts the
      layout: writers *append new pages to the `-wal`* (redo, not undo),
      the main file changes only at reader-aware checkpoints, and each
      reader pins a read mark in `-shm` → genuine snapshot isolation on
      a normal readonly open, nothing forfeited. **But that theory is
      moot in practice** (probed 2026-07-14): mozStorage opens its DBs
      with `locking_mode=EXCLUSIVE`, which shuts out even WAL readers —
      a plain `-readonly` open of the calendar DB fails "database is
      locked (5)" while TB runs. (The earlier "confirmed live calendar
      reads" was an inference from the WAL siblings, never an actual
      live read — falsified.) `immutable=1` bypasses the lock here just
      like on Gloda.
    - **Gloda snapshot mechanics — bracket the copy.** Read the change
      counter (header bytes 24–27) + check `-journal` absence → copy
      the whole DB → re-check both. Counter unchanged ∧ journal absent
      at both ends → settled; else discard, short backoff, retry. The
      validated counter value is the snapshot's generation stamp, so
      the per-search freshness check (Q12/Q13) = compare the live
      file's counter against it; differ → new snapshot → rebuild the
      FTS5. **One signal — the change counter — drives freshness *and*
      consistency.**
    - **Snapshot medium — DECIDED (amended 2026-07-14): an on-disk
      snapshot file, NOT `:memory:`.** (Fable's original
      `:memory:`-via-backup-API choice is reversed — see "why the flip"
      below.) Mechanics: `cp --reflink=auto` the live DB (via the
      `Subprocess` chokepoint) into a 0700 dir on the *same
      filesystem* (reflink can't cross filesystems, so not tmpfs
      `/tmp` — e.g. `~/.cache/pikuri/thunderbird/`), degrading to
      `IO.copy_stream` on non-COW filesystems; build the FTS5 index
      **into that on-disk copy** (it's our writable file); query it
      with a **normal** connection, reopened per call. Finalizer-reaped
      (the workspace ephemeral-umbrella pattern).
      - **Why the flip — pinned RAM vs. a near-zero privacy gain.**
        `:memory:` is **pinned, unreclaimable heap for the agent's
        whole life**: the entire Gloda DB (~70–94 MB) + our FTS5
        (~15 MB) for mail, ~62 MB for calendar → **~150 MB held while
        the tool idles**, and a Pikuri session can run for days (Q12).
        The privacy win Fable traded it for — "no decoded mailbox on
        disk" — barely exists: the decoded mailbox is *already*
        unencrypted on disk in the profile (that's exactly what Gloda +
        `cache.sqlite` are), so a 0700 copy in `~/.cache` sits at the
        **identical trust level**, not a new exposure class. The only
        real delta is a second at-rest copy + crash-stranding, both
        minor (re-derivable data; finalizer-reaped). An on-disk
        snapshot queried normally uses the **OS page cache** —
        reclaimable under pressure, cold-evicted while idle, re-warmed
        on next search → **idle pinned RAM ≈ 0**. Same consistency, same
        freshness mechanism; ~150 MB pinned → ~0.
      - **reflink makes the copy near-free:** `FICLONE` is a
        metadata-only extent share (~ms, ~0 extra disk until TB
        rewrites blocks), and it's **atomic w.r.t. concurrent
        writes** — but **file-atomicity ≠ DB consistency**: a clone
        taken mid-transaction faithfully photographs a torn DB, so the
        bracket stays load-bearing on every medium.
      - **`:memory:` survives as the documented zero-disk option**
        (space-constrained / read-only FS, or a user who wants no
        at-rest copy and can spend the RAM) — reached via
        `SQLite3::Backup` (probed 2026-07, gem 2.9.5: backup a
        `file:…?immutable=1` handle into `:memory:`, ~0.2–0.3 s for
        94 MB, then ~0.6 s FTS5 build). Not the default; wire a knob
        only when someone needs it.
      - **Dead ends, recorded against re-litigation:**
        `Database#serialize`/`#deserialize` (the `sqlite3_deserialize`
        zero-disk route) is **not exposed by gem 2.9.5** (probed:
        methods absent) — mooted anyway now that disk is the default.
        And **"a file open for reading is frozen in time" is false** —
        a regular-file fd is a live window (reads see others' later
        writes); the freezing intuition is the write-temp+`rename()`
        pattern where the *writer* abandons the old inode, but SQLite
        writes in place (same inode), so an open fd buys nothing.
      - **Debug bonus of disk:** the snapshot file is directly pokeable
        with the `sqlite3` CLI (the RAM option was not — it needed a
        `VACUUM INTO` dump).
    - **Why whole-file copy, not bracket-the-one-bulk-read:** follow-up
      queries (`thunderbird_mail_read`'s full `c0body` fetch by id, any
      later SELECT) would each hit the live file and each need its own
      bracket + retry; the copy pays the consistency cost once per
      generation and every subsequent query is torn-proof by
      construction. Search and read also stay coherent — the FTS5 index
      and `mail_read` serve the *same* snapshot (refresh on *search*
      only), so a search hit can't dangle mid-conversation.
    - **Burst behavior:** if TB is mid-sync and the counter won't sit
      still, retries exhaust → keep serving the previous snapshot
      (stale-but-consistent beats torn) + loud log; no previous snapshot
      → the tool returns an `Error:` observation.
    - **Privacy caveat (→ the gem's DESIGN.md threat model):** the disk
      snapshot is the decoded mailbox/calendar landing outside the TB
      profile — but at the *same trust level* as the source (both
      user-owned, and the profile DBs are already unencrypted plaintext
      at rest), so it's a second copy, not a new exposure class. 0700
      dir + `Pikuri::Finalizers` reaping; a crash can strand it until
      reboot (re-derivable data, low harm). The zero-disk `:memory:`
      option removes even this second copy for anyone who wants it.
    - **Honest residual:** a write transaction that begins *and* fully
      rolls back inside the copy window, with its journal invisible at
      both bracket edges, passes the check while the copy read dirty
      bytes — vanishingly rare (a Gloda rollback inside ~0.2 s), and it
      mostly degrades into the loud class-A errors anyway.
    - **Calendar joins the snapshot path (the 2026-07-14 amendment):**
      same on-disk reflink copy, same discard-and-retry
      bracket — one mechanism for both stores. Two WAL-specific
      wrinkles: (i) `immutable=1` ignores the `-wal`, so the snapshot
      is **as-of-last-checkpoint** — un-checkpointed commits are
      invisible (looks benign in practice: right after cache.sqlite's
      62 MB initial sync its `-wal` held only 1.1 MB and `immutable=1`
      saw all 5 414 events — TB checkpoints aggressively); (ii) a WAL DB's change counter
      bumps only on **checkpoint**, not per commit, so the calendar's
      bracket/staleness signal must pair the counter with the **`-wal`
      file size + mtime**. Exact tuning deferred until the calendar
      data story settles (see Q6 — on the probed box there's no on-disk
      calendar data to read at all, so the mail path leads).
    - **Tuning probes (pending — sizing, no longer load-bearing):** does
      a persistent `-journal` sit beside Gloda while TB runs?
      (`locking_mode=EXCLUSIVE` can retain it between transactions,
      which would neuter the journal half of the bracket — the counter
      half still works.) And the counter-bump cadence across a real mail
      poll, to size the retry/backoff policy.
    - **mbox compaction mid-scan:** only matters for the family-B
      mbox-parse *fallback* — deferred along with it.

12. **Freshness.** *Resolved.* Thunderbird keeps Gloda live (measured
    newest-message minutes old), so v1 inherits freshness for free — no
    `Watcher`-style daemon. The Q13 search decision (b) builds its own
    FTS5 index, but **ephemerally** (a disposable index inside Q11's
    snapshot, discarded with it), rebuilt on demand: a per-search check
    of Gloda's **file change counter** (DB header bytes 24–27; *not*
    per-session — an agent lives for days) rebuilds only after real mail
    activity. A disposable derivative that carries *no* freshness
    obligation. Only genuinely re-opens if either the family-B
    mbox-parse *fallback* or a future *persistent* FTS5 cache (the
    deferred scale option) grows a **maintained, long-lived** index that
    outlives the snapshot.

13. **Tool surface & naming.** *Mostly settled — the shape below is
    decided; only the search-matching approach (sub-decision 1) is open.*

    Six tools, capability-paired (search→read parent-document-retrieval,
    like `vectordb_search`/`vectordb_read`), named **`thunderbird_*`**:

    | Tool | v1? | Egress | Params | Returns |
    |---|---|---|---|---|
    | `thunderbird_mail_search` | ✅ | inbound | `query` (free text over body/subject/author/recipients/attachment-names) + optional `from`, `to`, `subject`, `after`, `before`, `folder` | ranked hits: `message_id`, date, from, to, subject, folder, **snippet**; deduped by `Message-ID` |
    | `thunderbird_mail_read` | ✅ | inbound | `message_id` | full decoded body (Gloda `c0body`, already HTML-stripped plain text) + headers + attachment names |
    | `thunderbird_mail_compose` | ⛔ v2 | **egress (human-gated)** | `to`, `cc`, `bcc`, `subject`, `body` | hands off to `thunderbird -compose`; Q10 recipient guard applied; human reviews + sends |
    | `thunderbird_calendar_search` | ✅ | inbound | `query` (title/description/location) + `after`, `before` | events: `event_id`, title, start, end, location |
    | `thunderbird_calendar_read` | ✅ | inbound | `event_id` | full event: description, location, attendees, recurrence (from the `icalString` side-tables) |
    | `thunderbird_calendar_create` | ⛔ v2 | **egress (human-gated)** | title, start, end, location, description, attendees | hands off `.ics` for TB import; human confirms |

    **v1 no-egress demo** wires the 4 inbound tools + `calculator` → legs
    1+2 present, leg 3 absent, trifecta broken (same as `bin/pikuri-corpus`).
    v2 adds the two egress tools behind the human-authored CLI hand-off.

    Settled sub-decisions:
    - **Naming `thunderbird_*` (not `mail_*`/`gloda_*`)** — names the
      *stable source*, not the *swappable backend* (Gloda-now /
      mbox-fallback), exactly as pikuri-os's `fileindex_*` names the
      capability over `localsearch`/`recoll`. Also keeps the trust
      boundary legible in the name: a future `gmail_*` connector is a
      *different* tool with *network* egress, and must not blur with
      local Thunderbird.
    - **`calendar_read` kept separate** — events can carry a long
      description / (rarely) attachments; cheap to keep, nuke later if
      unused.
    - **No `calendar` filter param** — `cal_id` is an opaque UUID and the
      human-readable calendar name lives in `prefs.js`
      (`calendar.registry.<uuid>.name`), not `local.sqlite`; the LLM would
      omit the param overwhelmingly anyway. Search all calendars. (Revisit
      only if multi-calendar scoping is wanted — it'd ride Q3's profile
      parsing.) *Asymmetry:* the mail `folder` filter **is** feasible in
      v1 — Gloda's `folderLocations` stores the folder `name`.

    Design details:
    - **`message_id` handle = `headerMessageID`** (the RFC Message-ID) —
      stable across reindex and it's how we dedup; fall back to Gloda `id`
      when absent.
    - **Ranking without FTS:** recency (`date DESC`) + field weight
      (subject-hit > body-hit) + term coverage. Recency is the right
      email default.
    - **`mail_read` returns clean text** — a Gloda-path bonus: `c0body` is
      pre-decoded + HTML-stripped, so no MIME parsing and no markup noise
      into the LLM.
    - Which binary wires them: the decided `bin/pikuri-thunderbird` demo
      (Q2), search-only + no-egress.

    **OPEN — sub-decision 1: the search-matching approach** (shapes
    `thunderbird_mail_search`). No *directly* usable FTS: Gloda's
    `messagesText` is a real stemmed FTS3 index, but locked behind the
    custom `mozporter` tokenizer, which a stock `sqlite3` can't resolve
    (`MATCH` → "unknown tokenizer: mozporter"). Three candidates:
    - **(a) LIKE + structured filters + own recency ranking + agent
      iteration** — substring over Gloda's decoded columns, no stemming;
      structured filters (`from`/`to`/date) are exact and carry most real
      email lookups; agent reformulates for topic search (the pikuri-os
      `localsearch` "iteration ≥ stemming" philosophy). Leanest — can even
      **shed the `sqlite3` gem** by shelling out to the `sqlite3` CLI via
      the `Subprocess` chokepoint (the Q2 follow-on), keeping v1
      dependency-free.
    - **(b) rebuild our own ephemeral FTS5 index from Gloda's decoded
      text** (its medium — on-disk snapshot, not `:memory:` — settled
      in Q11) — real Porter stemming + `bm25()` ranking + phrase queries,
      **in-language with zero authored C**. *Empirically confirmed*
      (2026-07, gem 2.9.5): FTS5 is compiled into the gem's SQLite and a
      stemmed `MATCH` matched "invoice"→"invoices" out of the box.
      ~1 s rebuild per session (Gloda is fresh → no daemon). Commits to
      the `sqlite3` gem. (Both (a) and (b) read Gloda's *plain*
      `messagesText_content` table — openable fine on the gem; only the
      *virtual* `fts3` table is blocked, which neither uses.)
    - **(c) register the real `mozporter` tokenizer via a C loadable
      extension** — vendor Mozilla's `mailnews/extensions/fts3/src/fts3_porter.c`
      (Porter + Unicode accent/case folding + CJK bigramming), implement
      the `sqlite3_tokenizer_module` vtable, and in the extension's init
      call `sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER,
      1, 0)` (off by default since SQLite 3.12) then
      `sqlite3_fts3_tokenizer(db, "mozporter", &module)`. Then `MATCH`
      against Gloda's *existing* index works, exact-parity, no rebuild.
      Prior art: `node-sqlite3-mozporter`. **DECLINED for v1** — and
      **empirically a non-starter on the default stack** (probed 2026-07,
      `sqlite3` gem 2.9.5 / SQLite 3.53.2, the precompiled
      `x86_64-linux-gnu` build a `gem install sqlite3` yields): that
      SQLite is compiled with **FTS5 only — no FTS3/FTS4/FTS3_TOKENIZER**.
      So `fts3_tokenizer()` doesn't even exist (kills the (c') alias
      outright), and — decisively — there's **no FTS3 module for a
      mozporter `.so` to register into**: Gloda's `messagesText` is an
      `fts3` virtual table, so the gem can't *open* it at all (`no such
      module: fts3`), tokenizer or not. (Extension loading *is* enabled,
      so the `.so` could load — but into nothing.) (c) would thus require
      shipping a *bespoke SQLite build with FTS3 compiled in*, not merely
      a loadable tokenizer — far heavier than the research implied. Note
      the divergence: the system `sqlite3` **CLI** *has* FTS3 (its error
      was `unknown tokenizer: mozporter`), but the **gem** lacks it
      entirely — two different SQLite builds. Two re-litigation guards:
      (i) `sqlite3_db_config(SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER)` does
      *not* rescue it — it can't add a missing module, isn't callable from
      SQL/CLI (C-only), and even unlocked only lets SQL point a name at an
      *already-loaded* C tokenizer; (ii) the only SQL-reachable trick
      (build permitting) is aliasing the built-in `porter` as `mozporter`
      — porter-only (no accent-fold/CJK), needs the gated setter, fragile.
      *Tested and dead* (2026-07, confirmed directly on the `sqlite3` CLI
      binary 3.46.1 *and* its `libsqlite3`; `ENABLE_FTS3_TOKENIZER=0`):
      `fts3_tokenizer('mozporter', fts3_tokenizer('porter'))` →
      **`Error: stepping, fts3tokenize disabled`**. The
      function exists but is gated (`ENABLE_FTS3_TOKENIZER` off), and the
      gate is C-only — un-flippable from any SQL statement or CLI flag.
      So even the degraded CLI alias is closed on default builds; (c) is
      empirically finished.
      And **FTS5 ≠ FTS3** (separate modules, on-disk formats, tokenizer
      APIs) — so having FTS5 gives no access to Gloda's fts3 index;
      option (b) builds a *fresh* FTS5 index over `messagesText_content`,
      it does not reuse Gloda's. Beyond the empirics, the
      ethos reasons still hold: (1) it's the project's
      *first* native/C code + a vendored Mozilla source + a per-platform
      `.so` build + comm-central drift-tracking, landing in the very gem
      that parses untrusted content — squarely against "pure Ruby, audit
      in an evening"; (2) its unique wins (reuse the prebuilt index; exact
      CJK/folding parity) only pay off at *scale* or heavy-CJK, and the
      measured mailbox is 8k msgs / 700 MB where LIKE (~0.5 s) and FTS5
      rebuild (~1 s) are both fine; (3) **(b) already captures ~95%** of
      its quality (stemming + bm25) in-language, so (c)'s marginal gain
      doesn't justify its cost. The "cheap hack" of SQL-aliasing built-in
      `porter` as `mozporter` is a mirage here — it needs the *same*
      `SQLITE_ENABLE_FTS3_TOKENIZER` gate the stock gem doesn't enable,
      and porter-only diverges from how the index was built. Keep (c) as
      the documented exact-parity / huge-mailbox option, and a candidate
      `available?`-probed upgrade *if* a prebuilt `libmozporter.so` ever
      exists (mirrors the Gloda→mbox fallback).
    **DECIDED: (b) — our own ephemeral FTS5 index** (built into Q11's
    on-disk snapshot, rebuilt when Gloda's change counter moves).
    Rationale
    (recall-over-agent-discipline): (a) leans on the agent *remembering*
    to reformulate/multi-query, and — the deeper flaw — LIKE **can't
    rank**, so a generous (a) floods the agent with an *unordered* pile
    while a stingy one starves it into a false "no such email" conclusion
    (a hallucination class that matters when *every email can matter*).
    (b)'s `bm25()` breaks that dilemma: **OR-match broadly for recall
    *and* surface the best hits first**, then cap output — the LLM sorts a
    *ranked* list, which is what it's good at. Honest caveat: stemming
    closes *morphology* (`universities`↔`university`, which LIKE-substring
    misses) but **not synonymy** (`invoice`↔`bill`); some agent
    reformulation still helps in either option — (b) just raises the
    single-query floor.

    **Index mechanics (the "technical dragons," tamed):**
    - **Where:** an *ephemeral* FTS5 index in pikuri's own snapshot —
      **never** in Thunderbird's DB. Built **inside Q11's on-disk
      snapshot file** (probed 2026-07: the snapshot is our writable
      copy): `CREATE VIRTUAL TABLE … USING fts5(…,
      content=messagesText_content, …)` + `INSERT INTO fts(fts) VALUES
      ('rebuild')` — an *external-content* FTS5 that stores only the
      index (no second text copy), maps hits back by rowid for free,
      and lets search + `mail_read` run on one connection. ~0.6 s build
      on a 94 MB test DB. Living in the on-disk snapshot (not
      `:memory:`) is what keeps idle RAM ≈ 0 — the index is
      page-cached, not pinned heap (Q11's medium flip). Gloda is
      untouched — never queried live; the only live touch is the
      bracketed reflink copy.
    - **Freshness — staleness checked per search, *not* per session.**
      ("Session" in Pikuri = agent lifetime, which can be *days* — so
      "rebuild per session" would go badly stale.) Instead: **lazy first
      build**, then on **every search** compare Gloda's **file change
      counter** (DB header bytes 24–27, big-endian) against our
      last-built value and rebuild only if it moved. A 4-byte
      `File.binread` — no SQL, no connection, no lock. Cheap enough every
      search; since Thunderbird polls mail ~every 15 min the check almost
      always says "unchanged," and the ~1 s rebuild is paid only right
      after real mail activity (occasionally mid-conversation —
      desirable, the agent then sees new mail). No daemon; the only disk
      footprint is Q11's snapshot file (finalizer-reaped), and reflink
      keeps even that near-zero until TB rewrites blocks.
      **Why the change counter, not mtime or `max(date)`** (settled by a
      probe, 2026-07): the file-format spec increments the change counter
      *only when the DB is unlocked after a modification* — so a **read
      cannot move it** (a format *guarantee*, not a behavior). Measured:
      200 `SELECT`s on both a normal *and* an `immutable=1` connection
      left it untouched; one write bumped it +1, monotonically. mtime
      *also* survived the read test (SQLite writes nothing to the main DB
      on a rollback-journal read, no auto-`ANALYZE`), but it rests on
      SQLite *behavior* + is exposed to fs-metadata quirks
      (`relatime`, granularity, spurious touches), so the change counter
      is the more defensible load-bearing signal. And *not*
      `max(messages.date)` — Gloda's `date` is the message *Date header*
      (send time), so it silently misses **backdated/imported mail,
      deletions, moves**; the content-level fallback is
      `(max(id), count(*), sum(deleted))`. (Change counter is authoritative
      per commit here because Gloda is `journal_mode=delete`; a WAL DB
      would only bump it on checkpoint. A torn 4-byte read mid-commit → at
      worst one harmless spurious rebuild, self-correcting next search.)
    - **Cost:** ~1 s for the measured 8k-msg / ~35 MB-text mailbox, paid
      once per session and only if mail is searched. *Scale caveat:* a
      100k+ msg mailbox makes the rebuild slow enough to reconsider a
      persistent disk-cached index keyed on Gloda's mtime/count — but that
      reintroduces staleness logic (the deferred dragon); wait for a real
      complaint.
    - **Recall-first tuning:** OR-of-terms + `bm25` rank + top-N cap
      (bm25's idf de-weights stopwords so they don't dominate); structured
      filters (`from`/`to`/date/`folder`) apply as exact predicates
      alongside the `MATCH`. Store Gloda `messages.id` / `headerMessageID`
      as the FTS5 rowid/unindexed column so a hit maps back for
      `thunderbird_mail_read`.
    - Commits to the `sqlite3` gem (the Q2 follow-on: (b) is what pulls it
      in; the CLI-shell-out that (a) allowed is moot now).
