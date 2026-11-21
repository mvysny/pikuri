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

## To decide: `attendees` on calendar-create

An `attendees:` parameter: the model names guests (resolving "Bob" through the
`contacts` surface), the `.ics` carries one `ATTENDEE` each, the human imports.

**What's known** (2026-11-21, Thunderbird 160, Cyrus 3.12 on the testbed; the
evidence is in `pikuri-thunderbird/design/architecture.md` § Hand-off
mechanics):

- Thunderbird's import sends nothing itself: `CalendarFileImporter.startImport`
  is one `addItem` per item, a plain PUT.
- An auto-scheduling CalDAV server (RFC 6638) schedules on that PUT when the
  `ORGANIZER` is the calendar's owner. An unmarked import mailed the guest an
  invitation, put a same-server guest's straight into their calendar, and a
  later DELETE mailed a cancellation. Pressing **Import** sent invitations.
- `SCHEDULE-AGENT=CLIENT` on each `ATTENDEE` stops all of it, and the import
  keeps the mark. So does leaving `ORGANIZER` out: no scheduling object at all,
  and Thunderbird's import adds none.
- **A later edit in Thunderbird's event dialog strips the mark**
  (`cal.itip.adaptScheduleAgent`, called by the dialog's Save, never by import).
  The server then mails every guest a *first* invitation, on whatever edit comes
  first, even a typo fix days later.
- The wizard selects the first event itself and shows its details, the guest
  list included, so the guests are on screen when Import is pressed.
- Google: no documentation. Reports are mixed. Mozilla bug 997784 says Google
  notified the guests despite the mark. Others say Google's CalDAV sends no
  invitations at all. iCloud and Sabre (Nextcloud, Baikal) are not seen;
  Sabre's answer is readable in sabre/vobject's `ITip\Broker`.
- The book doesn't need it. The secretary's offsite and dentist scenes make
  their point with events that have no guests.

**What it would buy:** the guests' addresses pre-filled, resolved from a name by
the model, so the human doesn't type them into Thunderbird's dialog.

**What it costs:**

- **Done safely, it invites nobody.** With the mark, the event *lists* Bob,
  but Bob hears nothing until the human's first dialog edit, which then invites
  him, on whatever edit that is. The useful version, invitations on Import, is
  exactly the send the hand-off rule forbids: the human pressed Import, not
  Send.
- **It adds a reach the tool doesn't have.** Today an event goes only to the
  human's own calendar server, which an injector can't read. Guests are third
  parties' inboxes, and the injector can be a guest. "Tell Bob" is already
  covered by `thunderbird_mail_compose`, whose compose window shows what leaves
  more plainly than an event's details pane.
- **Its safety rests on code we don't own:** a server honouring the mark
  (Google unknown), and Thunderbird's importer never calling
  `adaptScheduleAgent`. That has to be re-checked after every Thunderbird
  upgrade, against a CalDAV server the testbed has no script for yet.
- **`D_gem_placement`:** it's a feature that fixes no bug, closes no promise
  hole, and neither the secretary nor the book needs it.

Open only if it's built: `Q_no_organizer`, whether to emit no `ORGANIZER` as
well, which would cover a Google that ignores the mark (unverified: whether
the dialog's Save then adds the calendar's identity as organizer); and
`Q_dialog_edit_reschedules`, whether that dialog offers a "notify attendees"
choice on an auto-scheduling calendar.

**Leaning: don't build.** If that's the decision, this section goes. The
calendar-create yardoc's attendees note becomes the one-paragraph why-not,
since the trap is invisible in the code and silent under test, and the
architecture doc keeps the finding.

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
