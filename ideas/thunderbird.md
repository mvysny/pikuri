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
  files, no network, desktop-specific) and may even *belong* there — see
  the placement question below.
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

## Thunderbird storage landscape (recalled — verify on a real install)

Grounding for the questions below. Thunderbird is **not** installed on
the dev box these notes were written on, so every path/format claim here
is from memory and must be confirmed against a live profile before it's
load-bearing.

- **Profile discovery.** A `profiles.ini` names the active profile.
  Locations differ by install method:
  - apt/deb: `~/.thunderbird/<hash>.default*/`
  - snap: `~/snap/thunderbird/common/.thunderbird/<hash>.default*/`
  - flatpak: `~/.var/app/org.mozilla.Thunderbird/.thunderbird/<hash>.default*/`
- **Mail folders.** Classic default is **mbox** — one flat file per
  folder (`Inbox`, `Sent`, …) under `Mail/<account>/` (local) and
  `ImapMail/<account>/` (IMAP-synced), each shadowed by a `.msf` Mork
  summary/index. Trivially splittable on `From ` separator lines; each
  message is RFC 5322. **maildir** (one file per message) is an opt-in
  alternative, not the default.
- **Gloda full-text index.** `global-messages-db.sqlite` — Thunderbird's
  own SQLite + FTS index of message bodies, kept fresh by Thunderbird
  itself. Powerful (search already built, always current) but the schema
  is undocumented and version-dependent, and it may be disabled.
- **Calendars.** Local + cached CalDAV events live in a SQLite store
  under the profile (`calendar-data/local.sqlite` / `cache.sqlite`);
  events are ICS. Address book is `abook.sqlite` (or legacy Mork `.mab`).
- **Compose hand-off.** `thunderbird -compose "to=…,subject=…,body=…"`
  opens a pre-filled compose window; the user sends. There is no
  CLI/documented path to *send* without a compose window and a click.
- **Concurrency.** Thunderbird locks its profile while running; mbox
  files are generally safe to read alongside it, but the SQLite stores
  may need read-only/immutable open modes to avoid lock contention.

## Open questions (list only — do not resolve here)

Take these one at a time in later sessions.

1. **Search backend — parse ourselves, query Gloda, or recoll?**
   Three candidate approaches, each with a different cost/robustness
   profile:
   - **Parse mbox/maildir ourselves** (e.g. the `mail` gem for RFC 5322
     + a trivial mbox splitter) — full control, no index build, but we
     own parsing + our own search (grep-grade, or feed pikuri-vectordb).
   - **Query Gloda's `global-messages-db.sqlite`** — reuse Thunderbird's
     existing FTS, always fresh, zero index build — against an
     undocumented, version-fragile schema that may be off.
   - **recoll** — indexes mail *and attachments*, but requires the user
     to install + configure + build an index (same trade-off recorded
     for the OS assistant's `Recoll` backend).
   Do we want a single approach or a swappable, `available?`-probed
   backend like `pikuri-os`'s file-index pair?

2. **Placement — new `pikuri-thunderbird` gem, or fold into
   `pikuri-os`?** It's offline, Linux-desktop-specific, reads local
   files — the exact profile of `pikuri-os`. Sibling gem vs. an extension
   under an existing gem vs. a new binary.

3. **Profile/install discovery.** How do we robustly locate the active
   profile across apt/snap/flatpak (parse `profiles.ini`? probe the known
   roots?), and how do we pick among multiple profiles/accounts?

4. **Mail format coverage.** mbox is the default; do we also handle
   maildir? What about `.msf` (ignore and re-scan, or read the Mork
   index)?

5. **Attachments.** Do we search/read attachment bodies (reusing
   `pikuri-extractors`)? recoll gives this for free; the other two
   backends don't.

6. **Calendar read.** Is reading the calendar SQLite viable and stable
   enough (schema, locking), and which ICS parser (`icalendar` gem)?

7. **Calendar event creation.** Write into Thunderbird's calendar DB
   (fragile, undocumented) vs. hand off a `.ics` file for Thunderbird to
   import vs. out of scope. CalDAV write is out of scope by the no-network
   rule.

8. **Compose hand-off mechanics.** `thunderbird -compose` argument
   quoting/escaping, attachments, HTML vs. plain; and invoking the binary
   under snap/flatpak confinement (`snap run thunderbird …`, flatpak
   equivalent) from our process.

9. **"Send it ourselves" — is it even possible without SMTP?**
   Thunderbird's CLI only *opens* a compose window; there's no documented
   send-without-click. So "sending ourselves" seems to require either
   SMTP (explicitly excluded) or UI automation (fragile, out of posture).
   Decide whether this capability survives at all, or collapses into #4
   (compose hand-off, user sends).

10. **Security / trifecta posture.** Email bodies + attachments are
    untrusted, attacker-authorable content — reading them ingests
    injection into context; composing/sending and event-creation are
    egress/action legs. How does this design break the trifecta (removal
    of egress? quarantined reader sub-agent? author-not-approver
    confirmer on compose?), and what must a wiring guarantee before it's
    safe? This gates whether egress-side capabilities (#3–#5 of the task)
    can ship on an agent that also has web/other egress.

11. **Concurrency with a running Thunderbird.** Read-only/immutable
    SQLite opens, mbox read-while-locked safety, and what happens if
    Thunderbird rewrites an mbox (compaction) mid-scan.

12. **Freshness.** If we build our own index (approach 1 + vectordb), we
    inherit a freshness problem (a `Watcher`-style daemon); Gloda and
    recoll each manage their own freshness. Bears on #1.

13. **Tool surface & naming.** What tools do we expose and how are they
    named (e.g. a search→read-full mail pair, a calendar search, a create
    tools), and which binary/agent wires them (a demo `bin/`, the OS
    assistant, or a new one)?
