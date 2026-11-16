# Local Thunderbird integration

The inbound tools and the outbound hand-offs have shipped. Everything shipped
has graduated: empirical storage
data → `pikuri-thunderbird/design/architecture.md`, per-symbol design + rationale (including
the rejected alternatives, inline beside the live design) → the class yardocs,
invariants → `pikuri-thunderbird/AGENTS.md`'s *Thunderbird no-egress / no-send seam*.

What is left here is only work not done yet. When a line below is built or
answered, it graduates the same way and this note shrinks again.

## Related

- [`private-context-taint.md`](private-context-taint.md) — the "human as
  *author*, not *approver*" seat compose relies on.

## Open validation questions

Each needs a live install or a comm-central read; none blocks what ships.

- **Does an auto-scheduling CalDAV server honour `SCHEDULE-AGENT=CLIENT` on an
  imported `ATTENDEE`?** Thunderbird itself sends nothing on import
  (comm-central: `putItemsIntoCal` → `destCal.addItem` → a plain PUT, no
  iTIP). But an RFC 6638 `calendar-auto-schedule` server (Nextcloud/Sabre,
  iCloud, Fastmail) schedules *on the PUT* whenever the event has an
  `ORGANIZER` that is the owner, so the human's "import" click would mail
  invites the human never saw offered. RFC 6638 §7.1 says the server must not
  schedule an attendee marked `SCHEDULE-AGENT=CLIENT` (or omit `ORGANIZER`
  entirely, which makes it no scheduling object) — so the `attendees` param
  (below) is buildable once one real server is seen honouring it. Google's
  CalDAV is the likeliest to ignore it. The testbed can't answer it: its
  dovecot is IMAP only, and a CalDAV server that doesn't auto-schedule (Radicale)
  proves nothing. It needs Nextcloud/Sabre, Cyrus or a hosted account.


## Deferred work

- **Content-triple de-churn of the FTS5 rebuild.** Gloda's counter moves on
  read/star/tag flips too, so the ~1 s rebuild re-fires during triage. If that
  ever bites, gate the rebuild on `max(id)` / `count(*)` / `sum(deleted)`
  instead of the bare counter.

- **A correspondent allowlist** — restrict mail search/read to senders and
  recipients matching an address or domain, so a host can scope the mailbox
  instead of promising a scope in its prompt. The first host to want it is
  `bin/pikuri-briefing --with-mail` (`design/decisions.md` `D_briefing_with_mail`),
  whose prompt asks for "correspondence with that customer" while the search
  reaches everything Gloda indexed — a prompt promise, not an enforced
  boundary, and unlike the corpus's `trusted:` declaration this would be a
  real filter rather than a label. Two notes on its shape, so they are not
  re-derived: the filter belongs **inside the Gloda query, never as a
  post-filter over results** (results are ranked and capped, so dropping rows
  afterwards spends the cap on mail that is then discarded, and a scoped
  search quietly returns less than it should); and the `contacts` surface is
  its name→address resolver, which is part of why `surfaces:` keeps contacts
  separable (`D_thunderbird_surfaces`). Deferred on purpose — the honest
  whole-mailbox reading is what makes the severity lesson in
  `book/trifecta-detector.md` land — so build it when a week of real use
  makes the pool intolerable, and record it in `design/architecture.md` (it narrows the
  read surface) plus a `D_` entry if a fork turns out to be real.
- **`attendees` on calendar-create** — gated on the `SCHEDULE-AGENT` question
  above; each emitted `ATTENDEE` carries `SCHEDULE-AGENT=CLIENT`.
- **Attachments on compose** — the author-not-approver draft doesn't need them,
  and a path/URL reopens the staging problem.
- **Calendar date-filter timezone frame.** Bounds compare in the machine-local
  frame — right for timed events everywhere and for all-day events in UTC and
  eastern zones, but an all-day event (stored *floating* UTC-midnight) can slip
  a day boundary in a far-*western* zone. The full fix is per-event-type date
  extraction (all-day compared in its floating frame, timed in local). Low harm;
  see the comment in {Pikuri::Thunderbird::Calendar}.
- **Contact resolution: fuzzy/nickname matching** (`Jon` ↔ `Jonathan`; the
  all-terms filter already covers prefix cases) and **group/alias expansion**.
- **Thunderbird's address book proper** (`abook.sqlite` / the collected-addresses
  store) — a source *separate* from Gloda's derived participant graph, holding
  manually-curated contacts the user may never have mailed. It would **extend the
  read allowlist** beyond Gloda, calendar and the mbox store, a deliberate seam decision — so build
  it only if the derived graph proves too thin in practice.
- **`.msf` (Mork) and mbox fallbacks** — the `available?`-probed second arm
  for a Gloda-disabled host. Build only when such a host is a real user.
  Attachment bytes already come from the mbox store
  ({Pikuri::Thunderbird::MessageStore}).
