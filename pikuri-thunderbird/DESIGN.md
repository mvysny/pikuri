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
which is what keeps the trifecta broken even once compose exists. v2 adds the
two hand-off tools behind that gate, with a mechanical recipient guard
(Unicode/punycode/homoglyph rejection + a correspondence-graph novelty warn)
sanitizing what reaches the compose window. The full v2 rationale is in
`ideas/thunderbird.md`.

## Discovery

{Pikuri::Thunderbird::Profile} never guesses: it resolves one profile
unambiguously (parsing `profiles.ini`), raises with a fix if two install
roots both hold a profile (a stale apt profile left after an apt→snap
migration), or returns `nil` (tools simply not registered) when Thunderbird
isn't installed. An explicit `profile_dir:` override bypasses discovery.
Linux snap and apt roots are supported; flatpak is out of scope.
