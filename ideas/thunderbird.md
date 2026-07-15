# Local Thunderbird integration

Status: **v1 + v2 both shipped and validated against a real profile.** The
`pikuri-thunderbird` gem ships five inbound, no-egress tools
(`thunderbird_mail_search` / `_mail_read` / `_contact_search` /
`_calendar_search` / `_calendar_read`) and two opt-in, human-gated outbound
tools (`thunderbird_mail_compose` / `thunderbird_calendar_create`) + profile
discovery + the snapshot / ephemeral-FTS5 machinery + a one-call
`Thunderbird::Extension` + `bin/pikuri-thunderbird`, all under test and confirmed
working end-to-end against an actual Thunderbird install (the external-content
FTS5 rebuild + column assumptions held; both outbound hand-offs open their
window/wizard live). What remains here is the deferred-work + open-validation
residue below (attendees, WAL cadence, timezone edge, non-Gloda fallbacks).

This note has been trimmed per the graduation pipeline
([`../CLAUDE.md`](../CLAUDE.md)). Where the substance now lives:

- **Empirical data** (confirmed Gloda/calendar schema, encodings, locking,
  snap confinement, hand-off mechanics, the measured numbers) →
  `pikuri-thunderbird/DESIGN.md` § "Storage landscape (empirically
  confirmed)" — the durable evidence base, especially for the v2 builder.
- **Per-symbol rationale** → the class yardocs ({Pikuri::Thunderbird::Profile},
  {DatabaseSnapshot}, {Gloda}, {Calendar}, the four tools, {Extension}).
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
  reflink snapshot copy (change-counter + `-journal` bracket). {DatabaseSnapshot} +
  DESIGN.md. (The `:memory:` medium was considered and reversed — on-disk keeps
  idle RAM ≈ 0 via the page cache; `:memory:` stays a documented zero-disk
  knob, unbuilt.)
- **Q12 freshness** → inherit Gloda's (TB keeps it live); per-search
  change-counter check triggers the ~1 s FTS5 rebuild, no daemon. {Gloda} +
  DESIGN.md.
- **Q13 tool surface** → four inbound tools named `thunderbird_*`; mail ORs
  words + bm25-ranks (recall-first), calendar ANDs words across
  title/description/location (precision-first, no ranker). The shipped tools.

## v2 — outbound, human-gated (compose + address-resolver + calendar-create shipped)

The egress half. The load-bearing invariant (now also the CLAUDE.md seam):
**pikuri performs no network egress and no autonomous send; every outbound
action is a hand-off to Thunderbird's own UI where the human commits.** No
send tool ever ships. Confirmed hand-off mechanics are in DESIGN.md §
"Hand-off mechanics".

### `thunderbird_mail_compose` — **shipped** (first cut)

Built as opt-in (`Extension.new(allow_compose_mail: true)`, default off so an
unopted wiring stays no-egress by construction). The design graduated to source
and yardoc:

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
  wires `allow_compose_mail: true` with that prompt — the demo carries a
  *human-gated* egress leg on purpose (low risk: no autonomous send). The
  `Extension` default stays off, so downstream inbound-only wirings are unchanged.

### `thunderbird_contact_search` — resolve a name → address — **shipped**

Resolves a name (or partial address) to ranked addresses off the user's *own
correspondence graph*, so compose can turn "email Jon Snow" into an address
without inventing one or stopping to ask. The design graduated to source +
yardoc:

- **{Pikuri::Thunderbird::Gloda::Contacts}** — the resolver, one of two query
  views over the `Gloda` *service* (the other is `Gloda::Mail`; the service
  itself does snapshot + FTS5 index + freshness + connection, no queries):
  `#resolve` (corpus-based name→address) + `#domains_seen` (the identity-graph
  novelty query, grouped here alongside it). Owns the source decision (decoded
  `c3author`/`c4recipients`, not the dead `contacts` table), the shared-FTS5
  column-restricted match, bracket-agnostic extraction, the per-entry all-terms
  precision filter, Sent-weighted ranking, and the before-else-after name
  heuristic. Queries the service's snapshot through `Gloda#with_fresh_db`.
- **{Pikuri::Thunderbird::ContactSearch}** — the `thunderbird_contact_search`
  tool: renders ranked `Name <addr>` candidates with a familiarity signal,
  never auto-picks. Registered whenever Gloda is present (a pure read; the
  once-open "always vs. only-with-compose" question settled to *always* — gating
  a read behind the egress flag buys nothing).

Refinements made while building (worth remembering, all in the yardoc): the
shared FTS5 index is token-based, so "substring match" became FTS recall +
a **per-entry all-terms** precision filter — which is what stops a co-recipient,
my own address on a Sent message, or a mailbox that merely shares a domain token
with a full-address query from polluting the result; and the name comes from the
text *before* the address (dominant `Name <addr>` form), falling back to after,
so a tri-part cell like `Martin Vysny <m@x> Martin Vyšný` doesn't yield doubled
junk.

Still open / deferred:
- **Honest residual — a spoofed contact.** The graph includes senders of
  *received* mail, so an attacker who mailed as `Jon Snow <evil@…>` can surface
  as a candidate. Three things blunt it, none a hard block: the Sent weighting
  (a spoofer isn't in your Sent) sinks a one-off below the real Jon; the resolved
  address lands in the compose window the human reviews; and compose's
  novelty-warn fires if `evil@`'s domain is new. Same "human reviewing the To
  field is the last line" posture as the rest of compose — not trustworthy on
  its own.
- **Deferred:** fuzzy/nickname matching (`Jon` ↔ `Jonathan` — the all-terms
  substring filter already partially covers prefix cases); group/alias
  expansion; and reading Thunderbird's *address book* proper (recalled
  `abook.sqlite` / collected-addresses store — a source **separate** from
  Gloda's derived graph, holding manually-curated contacts the user may never
  have mailed). The address book would **extend the read allowlist** beyond
  Gloda + calendar (a deliberate seam decision), so build it only if the derived
  participant graph proves too thin in practice.

### `thunderbird_calendar_create` — hand off an `.ics` to import — **shipped**

Builds an event `.ics` and opens Thunderbird's import wizard, where the human
picks the destination calendar (local-vs-CalDAV = no-egress-vs-egress is *their*
choice) and confirms — the same no-autonomous-egress shape as compose. Design
graduated to source + yardoc:

- **{Pikuri::Thunderbird::CalendarCreate}** — the tool: build → stage → hand off,
  opt-in via `Extension.new(allow_create_calendar_event: true)` (its own flag, independent of
  `compose:`; both default off).
- **{Pikuri::Thunderbird::IcsEvent}** — the `.ics` builder; RFC-5545 field
  escaping + control-byte strip is the structural injection defense (a smuggled
  newline can't inject a second property/`VEVENT`), the `MailtoUri` analog. UTC
  for timed events, `VALUE=DATE` + exclusive `DTEND` for all-day.
- **{Pikuri::Thunderbird::Profile#outbox_dir}** — confinement-aware staging: the
  snap-owned data area for snap (the hidden `~/.cache` snapshot dir is
  unreadable by a confined TB — DESIGN.md § "Platform confinement"), the
  unconfined profile dir otherwise. The staged file is finalizer-reaped.
- **{Pikuri::Thunderbird::Launcher}** — the detached `setsid --fork` launch,
  extracted from `MailCompose` and now shared by both outbound tools.

*Rejected (kept for the reasoning):* direct DB write (TB holds the DBs
`EXCLUSIVE`; a live write is invisible/clobberable and never syncs).

Still open / deferred:
- **Attendees** — no `attendees` param yet; an imported `ATTENDEE` line *might*
  trigger CalDAV meeting invites (an autonomous send), which is unverified. The
  param waits on the validation question below.
- **Reap-vs-cold-boot residual.** The staged `.ics` is reaped at process exit,
  which for the interactive assistant is well after TB read the file (the wizard
  reads it on open, seconds after hand-off). A fire-and-forget one-shot that
  exits instantly *could* out-race a cold TB boot; acceptable, same
  best-effort class as compose's detached launch.

### The recipient guard (Q10) — **shipped**

The two-tier mechanical guard (hard-reject: Sanitizer everywhere + body
fail-closed + address ASCII-only/no-punycode; soft-warn: correspondence-graph
novelty) graduated to {Pikuri::Thunderbird::ComposeGuard}, backed by the new
{Pikuri::Thunderbird::Gloda#domains_seen} identity-graph query. What stays here:

- **Honest residual (unchanged by shipping):** pure-ASCII look-alikes of a
  domain you've *never* used, thin-history mailboxes, and a human who waves the
  warning through. That's why the observation urges a human-driven out-of-band
  check — the last line, outside the agent's trust boundary (adds no egress leg).
- **Novelty check verified end-to-end** against a real profile (schema + a
  live warn on a made-up recipient); see Open validation questions.

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
- **Compose recipient-novelty identity schema** — **resolved.**
  {Gloda#domains_seen} reads `identities(kind, value)`; the schema was confirmed
  on a real box (`kind` holds `'email'`, `value` the bare address) and the whole
  path was exercised end-to-end: `bin/pikuri-thunderbird` drafted to a made-up
  address, the compose window opened with it in the To field, and the soft-warn
  fired ("You have no prior mail with …"). The query still degrades gracefully
  (any `SQLite3::SQLException` → "couldn't check" note) for schema drift across
  TB versions.
- **Address-resolver — resolved, shipped, and validated live.** Both probes
  confirmed the source (`contacts` dead: `frecency`/`popularity` 0, `name`
  unreliable; decoded `c3author`/`c4recipients` carry `Name <addr>` pairs), the
  corpus-based resolver is built ({Pikuri::Thunderbird::Gloda::Contacts}), and
  it has now been **run against a real populated Thunderbird profile and works
  as intended** — the frequency ranking (the one thing fixtures couldn't prove)
  surfaces the right contact on a real correspondence graph. No open question
  remains for the resolver itself; the honest spoofed-contact residual (above)
  stands unchanged.
- **`CAL_ITEM_FLAG` mapping** — verify the recalled bitfield (esp. beyond
  bit 8) against comm-central. Now a *read-path* nicety only: create writes an
  `.ics` and lets TB set its own flags on import, so it no longer blocks
  create-event.
- **v2 residual — does importing an `.ics` with `ATTENDEE` lines onto a
  CalDAV calendar mail invites?** Import usually isn't an organize-action, so
  probably not — but unverified; {Pikuri::Thunderbird::CalendarCreate}'s
  `attendees` param waits on this (it ships without one).
- **Calendar-create — resolved, validated live.** Run against an actual
  Thunderbird: the `thunderbird <path.ics>` → import-wizard round-trip works
  end-to-end (build → stage → hand-off → the wizard opens the event, human
  confirms), and the staged `.ics` was readable by the running TB. No open
  question remains for create-event itself; the ATTENDEE-invite residual (above)
  still gates the `attendees` param.
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

