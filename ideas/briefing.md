# Briefing: the one thing still open

Status: **both stages are built and shipped, and so is the teaching.**
What keeps this note alive is a single deliberate deferral, below.
Everything else has graduated:

- `DECISIONS.md` `D_briefing_wiring` — Stage 0's forks, and the
  laundering-pipe argument.
- `DECISIONS.md` `D_briefing_with_mail` — Stage 1's forks: the flag,
  the raise where its dependency fails open, mail + contacts without
  the calendar, one prompt plus a fragment, and the four rejected
  roads (cite-and-stop, absence-over-mail, a `write`/draft tool,
  auto-memory).
- `DECISIONS.md` `D_thunderbird_surfaces` — the `surfaces:` knob Stage
  1 needed, and why the map cannot grade what it buys.
- `book/trifecta-detector.md` §"One flag, one extra leg, and the same
  verdict" — the two-run lesson: presence 1 → 2, verdict silent, and
  everything that changed for the human sitting outside what the
  detector grades.
- `book/rag.md` — Stage 0's walk-through, the one-legged map, the
  local-inference invariant, which gem *not* to wire.
- `pikuri-thunderbird/DESIGN.md` §leg 3 — narrowing the inbound
  surface reduces severity, not presence.
- [`assistant.md`](assistant.md) — the federation this is a candidate
  first member of (`@customers` / `@accounts`, not `@private`: the
  pool is customer-relationship records rather than durable personal
  memory, and under `--with-mail` it carries an untrusted leg
  `@private` must not have). That point graduates there when that
  note does.

## The deferral: a correspondent allowlist

"Correspondence with that customer" is a prompt promise, not an
enforced boundary — `--with-mail`'s private pool is the whole mailbox
and address book. Enforcing it needs a filter on
`Thunderbird::Extension`: mail whose sender or recipient matches an
address or domain, and nothing else. Unlike the corpus declaration
that is a real filter, not a label.

Two notes on its shape, so a later build doesn't re-derive them:

- **Inside the Gloda query, never as a post-filter over results.**
  Results are ranked and capped, so dropping rows afterwards spends
  the cap on mail that is then discarded, and a scoped search quietly
  returns less than it should.
- **The contacts surface is its name→address resolver** — which is
  part of why `surfaces:` keeps contacts separable
  (`D_thunderbird_surfaces`).

**Deferred deliberately:** the honest whole-mailbox reading is what
makes the severity lesson land, and prompt-promise-versus-enforced-
boundary is a distinction worth teaching. Build it when a week of real
use makes the pool intolerable — then `pikuri-thunderbird/DESIGN.md`
(it narrows the read surface) plus a `D_` entry if a fork turns out to
be real.
