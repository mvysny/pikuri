# Local Thunderbird integration

The inbound tools and the outbound hand-offs have shipped. Everything shipped
has graduated: empirical storage
data → `pikuri-thunderbird/design/architecture.md`, per-symbol design + rationale (including
the rejected alternatives, inline beside the live design) → the class yardocs,
invariants → `pikuri-thunderbird/AGENTS.md`'s *Thunderbird no-egress / no-send seam*.

What is left here is only work not done yet. When a line below is built or
answered, it graduates the same way and this note shrinks again.

## Related

- pikuri-workshop's [`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md) — the "human as
  *author*, not *approver*" seat compose relies on.

## Deferred work

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
