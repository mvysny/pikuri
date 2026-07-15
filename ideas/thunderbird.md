# Local Thunderbird integration

Status: **v1 shipped and validated against a real profile; v2 (egress) in
flight.** The `pikuri-thunderbird` gem ships the four inbound, no-egress tools
(`thunderbird_mail_search` / `_mail_read` / `_calendar_search` /
`_calendar_read`) + profile discovery + the snapshot / ephemeral-FTS5 machinery
+ a one-call `Thunderbird::Extension` + `bin/pikuri-thunderbird`, all under test
and confirmed working end-to-end against an actual Thunderbird install
(the external-content FTS5 rebuild + column assumptions held).

This note has been trimmed per the graduation pipeline
([`../CLAUDE.md`](../CLAUDE.md)). Where the substance now lives:

- **Empirical data** (confirmed Gloda/calendar schema, encodings, locking,
  snap confinement, hand-off mechanics, the measured numbers) →
  `pikuri-thunderbird/DESIGN.md` § "Storage landscape (empirically
  confirmed)" — the durable evidence base, especially for the v2 builder.
- **Per-symbol rationale** → the class yardocs ({Pikuri::Thunderbird::Profile},
  {Snapshot}, {Gloda}, {Calendar}, the four tools, {Extension}).
- **Invariants** → CLAUDE.md (the gem inventory + the *Thunderbird
  no-egress / no-send seam*).

What remains here: the origin map, the still-in-flight **v2 egress design**,
and the open validation questions. When v2 ships, its design graduates the
same way and this note shrinks again.

## Related

- [`os-assistant.md`](os-assistant.md) — the shipped analog: an offline,
  desktop-specific agent over an `available?`-probed backend that never
  egresses. pikuri-thunderbird mirrors the *pattern* (not the
  GNOME-dependence) but is its own gem.
- [`trifecta-detector.md`](trifecta-detector.md) — email is the textbook
  trifecta: private mailbox + attacker-authorable content + egress. v1
  removes the egress leg entirely; v2 must keep it human-gated.
- [`private-context-taint.md`](private-context-taint.md) +
  [`more-confirmers.md`](more-confirmers.md) — the "human as *author*, not
  *approver*" seat that the v2 compose hand-off relies on.

## v1 — shipped (search-only, no egress)

The 13 original design questions are all decided; the reasoning graduated to
the homes above. Origin map (question → where the answer now lives):

- **Q1 search backend** → Gloda-only, our own ephemeral FTS5 over the decoded
  columns (mozporter/fts3 unusable; family-B mbox parse deferred as the
  `available?` fallback). {Gloda} + DESIGN.md.
- **Q2 placement** → a separate `pikuri-thunderbird` gem (its own threat
  model; untrusted-parser deps out of the audit-first `pikuri-os`). Shipped.
- **Q3 discovery** → never-guess (snap/apt roots, raise on ambiguity, `nil`
  when absent, `profile_dir:` override). {Profile}.
- **Q4 format coverage** → Gloda-only in v1; no mbox/maildir/Mork reader. {Gloda}.
- **Q5 attachments** → names only (Gloda's `attachmentNames`); bodies deferred
  with the mbox parser. {MailSearch}/{MailRead}.
- **Q6 calendar read** → plain `SELECT` on normalized columns; PRTime µs UTC,
  all-day = `flags` bit 8; empty-corpus self-explains (enable Offline
  Support). {Calendar} + DESIGN.md.
- **Q11 concurrency** → never query the live locked DB; a bracketed on-disk
  reflink snapshot copy (change-counter + `-journal` bracket). {Snapshot} +
  DESIGN.md. (The `:memory:` medium was considered and reversed — on-disk keeps
  idle RAM ≈ 0 via the page cache; `:memory:` stays a documented zero-disk
  knob, unbuilt.)
- **Q12 freshness** → inherit Gloda's (TB keeps it live); per-search
  change-counter check triggers the ~1 s FTS5 rebuild, no daemon. {Gloda} +
  DESIGN.md.
- **Q13 tool surface** → four inbound tools named `thunderbird_*`; mail ORs
  words + bm25-ranks (recall-first), calendar ANDs words across
  title/description/location (precision-first, no ranker). The shipped tools.

## v2 — outbound, human-gated (compose shipped; calendar-create designed)

The egress half. The load-bearing invariant (now also the CLAUDE.md seam):
**pikuri performs no network egress and no autonomous send; every outbound
action is a hand-off to Thunderbird's own UI where the human commits.** No
send tool ever ships. Confirmed hand-off mechanics are in DESIGN.md §
"Hand-off mechanics".

### `thunderbird_mail_compose` — **shipped** (first cut)

Built as opt-in (`Extension.new(compose: true)`, default off so the demo stays
no-egress by construction). The design graduated to source and yardoc:

- **{Pikuri::Thunderbird::MailCompose}** — the tool: `mailto:`-URI hand-off,
  full-body pre-fill, the directed pre-send checklist, detached `setsid --fork`
  launch (so closing the agent never SIGTERMs the user's Thunderbird), the
  `thunderbird_bin:` override.
- **{Pikuri::Thunderbird::MailtoUri}** — percent-encodes every field value
  (the injection defense; a smuggled `&bcc=` is defused to body text).
- **{Pikuri::Thunderbird::ComposeGuard}** — the two-tier recipient guard (below).

Still open / deferred here:
- *Rejected (kept for the reasoning):* bullet-skeleton pre-fill (theater —
  unenforceable, doesn't close body-exfil, worse draft) and subject-only/empty
  body (guts the feature) — both lost to full-body pre-fill, since the
  forced-authorship seat binds to the **recipient + intent-to-send**, not the
  prose ("the recipient is the attack"; a leaked body only ever reaches the
  intended recipient).
- **Attachments** deferred to a later pass (the author-not-approver draft
  doesn't need them, and a path/URL reopens the staging problem).
- **Plain-text-only** is enforced by never emitting an HTML body — no HTML knob
  exists, so the two HTML-only exfil vectors (hidden content, remote beacons)
  can't arise. (Rationale in the {MailCompose} yardoc.)
- **A compose wiring needs a drafting-for-review prompt.** The inbound-only
  `prompts/thunderbird.txt` says the agent "cannot send mail" — true with
  compose off, and it would keep the tool unused if reused with compose on. The
  compose wiring ships its own `prompts/thunderbird-compose.txt` (drafting
  stance + hardened untrusted-content paragraph). `bin/pikuri-thunderbird` now
  wires `compose: true` with that prompt — the demo carries a *human-gated*
  egress leg on purpose (low risk: no autonomous send). The `Extension` default
  stays `compose: false`, so downstream inbound-only wirings are unchanged.

### `thunderbird_calendar_create` — hand off an `.ics` to import (designed, not built)

- **Decided: hand TB an `.ics`** (`thunderbird <path.ics>` → the human-gated
  import wizard; TB owns the commit *and* the human picks the destination
  calendar, i.e. local-vs-CalDAV = no-egress-vs-egress is the human's choice).
  *Rejected:* direct DB write (TB holds the DBs `EXCLUSIVE`; a live write is
  invisible/clobberable and never syncs).
- **Staging the `.ics`** (decided by the snap-confinement probe, DESIGN.md):
  stage under the discovered variant's own readable root — snap →
  `~/snap/thunderbird/common/…`, apt → the (unconfined) profile root; **not**
  the hidden `~/.cache` snapshot dir. Finalizer-reap after hand-off.

### The recipient guard (Q10) — **shipped**

The two-tier mechanical guard (hard-reject: Sanitizer everywhere + body
fail-closed + address ASCII-only/no-punycode; soft-warn: correspondence-graph
novelty) graduated to {Pikuri::Thunderbird::ComposeGuard}, backed by the new
{Pikuri::Thunderbird::Gloda#domains_seen} identity-graph query. What stays here:

- **Honest residual (unchanged by shipping):** pure-ASCII look-alikes of a
  domain you've *never* used, thin-history mailboxes, and a human who waves the
  warning through. That's why the observation urges a human-driven out-of-band
  check — the last line, outside the agent's trust boundary (adds no egress leg).
- **Novelty-check schema is unverified against a real box** — see Open
  validation questions.

### `thunderbird_*` trifecta detector wiring (when compose is added)

When compose *is* wired, the (still-unbuilt) trifecta detector should tag
compose/create-event `:egress` and mail-read `:untrusted`+`:private`, so a
combined-legs wiring trips the all-three warning correctly. Document the
posture honestly as smoke-alarm-grade (human-gated ≠ severed), not a firewall.

## Open validation questions

Need a real populated install or future work; none blocks v1. (The
real-install smoke test — the headline question here — is now **resolved**:
v1 ran end-to-end against an actual Thunderbird profile, working well.)

- **Calendar WAL cadence.** Calendar search + read are now confirmed working
  against a real profile, but the WAL staleness path specifically is *not* yet
  exercised: a WAL DB's change counter bumps only on checkpoint, so the
  staleness signal should eventually pair the counter with `-wal` size+mtime.
  v1 uses the bare counter; still deferred until the calendar path takes live
  writes between polls.
- **Gloda counter cadence across a real poll** — sizing only (retry/backoff);
  the read/star/tag churn is already confirmed. The content-triple de-churn
  (`max(id)`/`count(*)`/`sum(deleted)`) is the upgrade if the ~1 s spurious
  rebuild ever bites.
- **Compose recipient-novelty identity schema.** {Gloda#domains_seen} reads
  `identities(kind, value)` — the shape recalled from Gloda, **not** probed on a
  real box (DESIGN.md marks `contacts`/`identities` "unused in v1"). The query
  degrades gracefully (any `SQLite3::SQLException` → "couldn't check" note), so a
  wrong column name is a silent no-op, not a crash — but the *feature* is unproven
  until a real profile confirms the domains are actually found. First real-box
  compose is the test.
- **`CAL_ITEM_FLAG` mapping** — verify the recalled bitfield (esp. beyond
  bit 8) against comm-central at v2-calendar-create implementation.
- **v2 residual — does importing an `.ics` with `ATTENDEE` lines onto a
  CalDAV calendar mail invites?** Import usually isn't an organize-action, so
  probably not — but unverified; the `attendees` param waits on this.
- **Calendar date-filter timezone frame.** Bounds are compared in the
  machine-local frame — correct for timed events everywhere and for all-day
  events in UTC/eastern zones, but an all-day event (stored *floating*
  UTC-midnight) can slip a local-frame day boundary in a far-*western* zone. A
  fully correct fix needs per-event-type date extraction (all-day compared in
  its floating frame, timed in local). Deferred; low harm, and the common
  (eastern/UTC) case is right. See the comment in {Pikuri::Thunderbird::Calendar}.
- **`.msf` (Mork), maildir, mbox fallback** — all deferred; build only when a
  Gloda-disabled or maildir host is a real user.
- Mention in the book
- Integrate into pikuri-os

