# Local Thunderbird integration

Status: **v1 (five inbound tools) + v2 (compose, contact-search,
calendar-create) both shipped and validated against a real populated
Thunderbird profile.** Everything shipped has graduated: empirical storage
data → `pikuri-thunderbird/DESIGN.md`, per-symbol design + rationale (including
the rejected alternatives, inline beside the live design) → the class yardocs,
invariants → CLAUDE.md's *Thunderbird no-egress / no-send seam*.

What is left here is only work not done yet. When a line below is built or
answered, it graduates the same way and this note shrinks again.

## Related

- [`private-context-taint.md`](private-context-taint.md) +
  [`more-confirmers.md`](more-confirmers.md) — the "human as *author*, not
  *approver*" seat compose relies on.

## Open validation questions

Each needs a live install or a comm-central read; none blocks what ships.

- **Does importing an `.ics` with `ATTENDEE` lines onto a CalDAV calendar mail
  invites?** Import usually isn't an organize-action, so probably not — but
  unverified, and {Pikuri::Thunderbird::CalendarCreate}'s missing `attendees`
  param (below) waits on the answer: an autonomous invite would break the
  no-send seam.
- **Calendar WAL cadence.** A WAL DB's change counter bumps only on checkpoint,
  so the calendar staleness signal should eventually pair the counter with
  `-wal` size+mtime. Deferred until the calendar path takes live writes between
  polls (search + read themselves are confirmed working).
- **Gloda counter cadence across a real poll** — sizing only, for retry/backoff.
  If the ~1 s spurious rebuild ever bites, the fix is the content-triple
  de-churn (`max(id)` / `count(*)` / `sum(deleted)`) instead of the bare counter.
- **`CAL_ITEM_FLAG` mapping** — verify the recalled bitfield (esp. beyond bit 8)
  against comm-central. Read-path nicety only: create hands off an `.ics` and
  lets Thunderbird set its own flags on import.

## Deferred work

- **`attendees` on calendar-create** — gated on the CalDAV-invite question above.
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
  read allowlist** beyond Gloda + calendar, a deliberate seam decision — so build
  it only if the derived graph proves too thin in practice.
- **`.msf` (Mork), maildir, mbox fallbacks** — the `available?`-probed second arm
  for a Gloda-disabled host, and what would also unlock attachment *bodies*
  (Gloda gives names only). Build only when such a host is a real user.
- **Zero-disk snapshot medium.** An `:memory:` DB instead of the on-disk copy,
  for a host that must leave nothing on disk — a knob, not a default (see
  {Pikuri::Thunderbird::DatabaseSnapshot} for why on-disk wins otherwise).
