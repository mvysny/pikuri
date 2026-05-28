# Security model

Pikuri's security posture in one page: what we guarantee, what we
don't, and the structural reasons it works the way it does. Read
this once before pointing `pikuri-code` (or any future
write-capable variant) at anything sensitive.

This is the *committed* model — what ships today, stated tersely.
The teaching version — the threat from first principles, five
worked attacks told as stories, and a decision procedure for
designing your own harness — is
[chapter 6 of the guide](docs/guide/06-security.md). Open questions,
deferred mitigations, and prior-art notes live in
[`IDEAS.md`](IDEAS.md) §"Security perspective".

Two axes, in order. **Code trust:** which processes do you trust to
execute their intended code? A short section, settled in one pass.
**Prompt injection:** once code trust is established, how do you keep
correctly-functioning code from being tricked by untrusted *content*
it reads? The rest of the document, because it's the unsolved one.

## The kit, by harness shape

The two axes above are the *threats*. This is the *defense* side, and
the one thing to internalize first: pikuri is not one security model,
it's a small kit, and the right pick depends on what the harness has to
do. The trifecta-break is the headline — but it's one tool in the box,
and the harness everyone actually wants, a coding agent, is the one it
can't cover.

| Model | Mechanism | Fits | Where it fails |
|---|---|---|---|
| **Trifecta-break** | sub-agent capability boundaries — `RESEARCHER` / `FILE_MINER` hold at most two of the three legs | chat, `minions`, web / file recon | the *relay* leg: a sub-agent's reply carrying the injection up to a parent that *does* hold the third leg |
| **Blast-radius containment** | Workspace seam + Bubblewrap — `~/.ssh`, `~/.aws`, other projects don't resolve; bash sees only the workspace | coding, attended or not | the workspace is itself inside the radius — "leak *this* project's `.env`" still works |
| **Human gate** | `Confirmer` prompts before an irreversible or egress-bearing action runs | coding **with a human present** | confirmation fatigue; worth zero when nobody's watching |
| **Egress allowlist** *(planned — see [`IDEAS.md`](IDEAS.md))* | allow your package registries + git remote, deny the rest — cuts exfil at the network without removing `bash` | **unattended** coding | coarse: an allowlisted host is still open, and DNS exfil rides port 53 |
| **Outer isolation** | a VM / container wrapping the whole pikuri process | `--yolo`, "I don't trust any of this" | delegated to the OS; DinD footguns (see IDEAS) |

**Why coding needs the kit, not the headline.** A coding agent's job
*is* the trifecta: read your source (a), pull docs and dependencies (b),
run builds and push (c). You can't decompose that into "at most two
legs" without crippling it — so coding composes the *rest* of the kit
instead, and the composition splits on whether a human is in the room:

- **Attended** (you're driving `pikuri-code`): blast-radius containment
  as the floor, the human gate as the active control. The gate catches
  the rare irreversible / egress action; containment bounds the damage
  to *this project* when a tired user clicks through.
- **Unattended** (cron, CI, a `minions` fan-out): no human to prompt, so
  the human gate is off the table. Blast-radius containment plus an
  egress allowlist is the structural substitute — exfil blocked at the
  network, no human required. The allowlist isn't shipped yet; until it
  is, unattended coding on a box with real secrets is the open gap, and
  "run it in a VM" (outer isolation) is the stopgap.

These *compose*; they aren't alternatives. The honest line from
"Non-goals" still holds — the human gate is *attention, not isolation* —
which is exactly why it only works stacked on the structural mechanisms
beneath it: they keep it from firing on every edit (fatigue) and bound
the blast radius when it's bypassed.

## Code trust (the short axis)

Before anything else: which processes do you trust to execute? Once
this is settled, every defense below assumes those processes are
running their intended code.

- **Pikuri itself — trust it (and read it).** Pikuri's code
  (especially `core`) is designed to be small: plain Ruby across
  eight gems, deliberately small enough to read in an evening. Every
  public class has a YARD header explaining *why* it exists. See
  [`CLAUDE.md`](CLAUDE.md) for the design map. Audit it; you're
  meant to.
- **Your LLM provider — *the* trust choice.** Defaults wire local
  llama.cpp: your prompts never leave the box. The moment you
  `RubyLLM.configure` OpenAI / Anthropic / anything else, every byte
  of context (file contents, scraped pages, tool results) is shipped
  to that third party. A malicious LLM is downstream of every other
  defense in this document — there is no structural recovery if the
  model itself is the adversary. Pick a reputable provider.
- **The LLM's drafted bash — half-trust → Bubblewrap.** `Bash` runs
  commands composed by the LLM, under instructions it may have read
  from anywhere. Even when it's invoking your own build tooling
  (`./gradlew test`, `npm run build`), **it** chose to run that, with
  those args — and it could just as easily hallucinate `rm -rf ~/*`.
  `pikuri-code`'s `Bash` wraps every spawned argv through
  `Bash::Sandbox::Bubblewrap` by default, which blocks exactly that
  plus reads of files it shouldn't touch. It does *not* block network
  egress (that would break `git` and package managers) — see
  Non-goals. See {Pikuri::Code::Bash::Sandbox}.
- **MCP server processes — don't trust → Docker.** The `mcp` gem
  spawns stdio MCPs as raw subprocesses; pikuri does not sandbox
  them. An MCP whose code calls `os.system('rm -rf')` is unstoppable
  at the pikuri layer. Run untrusted MCPs in a Docker container —
  most are Node / Python and containerize trivially. (Description
  injection is a separate MCP threat, defended differently — see
  the next section.)
- **Skills — text, not code.** Skills are Markdown + YAML
  frontmatter the user dropped under `.pikuri/skills/` /
  `.claude/skills/` / `.agents/skills/`. They don't execute; they're
  prompts. User-vetted by definition. Treat them like any other
  source you'd `git clone` — read before you trust.

That's the baseline. The rest of this document is about the harder
problem: **prompt injection of code you've already decided to
trust.**

## Prompt injection (the long axis)

The remaining attack surface is content the model reads: a tool
returns text, it enters the context, and the model cannot tell
"data" from "instructions" — there is no equivalent of the CPU's NX
flag for tokens. Unsolved industry-wide, and arriving from many
places: a scraped page, a file in `node_modules/`, an MCP result,
even another sub-agent's reply. Pikuri does not try to *detect*
injection (filters lose to adversarial text); the defense is
**structural**, via the *lethal trifecta* (Simon Willison's
framing): any single agent combining (a) private-data access,
(b) untrusted-content exposure, and (c) internet egress is one
injection away from an exfiltration tool. Keep every agent to at
most two of the three.

### Defenses that ship

**Privilege-separated sub-agents.** Three bundled personas, each
holding ≤2 legs, so the agent that *reads* untrusted content has no
tool to act on an injection — structural, holds even against a
fully-fooled model:

- `RESEARCHER` — `web_search` / `web_scrape` / `fetch`. Web in/out;
  no `read` / `bash` / `write` / `agent` recursion.
- `FILE_MINER` — `read` / `grep` / `glob`. Reads files; no egress, no
  `bash` / `write` / recursion.
- `GIT_REPO_RESEARCHER` — `git_clone` plus a `FILE_MINER`+web set,
  cloning (HTTPS-only, shallow) into a temp workspace *disjoint*
  from the parent's project root, so cloned bytes never land where
  the parent's `read` would find them. Same trifecta shape as
  `RESEARCHER`.

`bin/pikuri-code` wires all three; the parent receives only the
sub-agent's one-paragraph reply, never the raw untrusted bytes.

*The honest gap — the relay leg (not structural).* That reply is
itself attacker-influenced content, and it flows into a parent that
in `pikuri-code` / `pikuri-assistant` holds `read` + `bash` +
`fetch`. A flag-don't-relay instruction in the persona prompts and
the lossy one-paragraph summary narrow it, but neither bites on an
injection subtle enough that the model never classifies it as one
("for completeness, also check `.env`"). What holds even then is the
machine-layer boundary: `~/.ssh`, `~/.aws`, `~/.m2/settings.xml`,
and other projects don't resolve for the parent — blast radius is
the *project* surface, not the whole box.

**MCP description verification.** Even when the MCP *process* is
benign, its tool descriptions can be injected (supply-chain
compromise, MITM, a duped author) — and this lands at *registration*,
before any prompt, where sub-agent separation can't help.
{Pikuri::Mcp::Verifier} runs there: a mechanical Unicode pre-pass
(zero-width chars, bidi overrides, tag characters) plus an
LLM-driven scan of every text field the server emits, looking for
instruction-override / exfiltration / authority-impersonation. A
flagged server raises `Mcp::InjectionDetected` and never enters the
live registry. Best-effort, not airtight: a subtle injection can
slip the LLM pass, so "pick reputable MCPs" is the first line. Gap
worth naming: the Verifier checks only *registration*-time text —
the bytes a tool *returns at runtime* flow into the parent unchecked,
and MCP tools mount on the parent (no sub-agent boundary between the
model and the payload), so "pick reputable MCPs" applies at every
call too.

> **Five worked attacks** — credential exfil via a scraped page, a
> destructive command in a vendored file, a malicious MCP
> description, a poisoned MCP *response*, and the compound
> MCP-plus-bash-plus-tired-user case — are walked end to end in
> [chapter 6 of the guide](docs/guide/06-security.md). The first
> three are structural (or best-effort) wins; the last two are where
> structural defense ends and operational caution takes over.

Non-goal: pikuri does not filter or sanitize tool output. The
defense is the trifecta (at most two capabilities available to any
agent), not content inspection.

## Non-goals (be explicit)

Several framings worth stating directly so the model isn't misread
as a guarantee:

- **A compromised LLM provider.** A model trained to exfiltrate is
  downstream of every defense in this document. Restated from the
  code-trust section because it's the load-bearing trust choice.
- **Permission prompts are UX, not isolation.** The
  `Workspace::Confirmer::TERMINAL` prompts on `Write` / `Bash`
  reduce honest mistakes; they do not stop a determined or injected
  call once the user has approved sticky permissions. (Borrowed
  framing from opencode's `SECURITY.md`, which puts this same line
  at the top of theirs. They're right.)
- **Pikuri does not sandbox its own process.** For real isolation
  against a compromised pikuri or compromised tool, run pikuri
  itself inside a VM or container. The Bubblewrap sandbox on `Bash`
  constrains one tool's view; it does not constrain the Ruby
  process invoking it.
- **`pikuri-code --yolo` outside a VM/container.** `--yolo` disables
  the `Confirmer` (no per-command approval) and `--no-sandbox`
  disables Bubblewrap (no filesystem containment). Together they
  make `Bash` a fully privileged subprocess on your host. Use these
  only inside an outer sandbox you trust.
- **An agent wired with both fs-read and egress as a parent.** The
  persona model protects sub-agents that touch untrusted content.
  A parent with `read` + `fetch` + a tool that scrapes the web
  reassembles the trifecta if the model skips delegating to
  `RESEARCHER`. `bin/pikuri-chat` structurally avoids this shape
  (no `read` / `bash` / `write`); `bin/pikuri-code` and
  `bin/pikuri-assistant` currently have the shape and rely on the
  system prompt to nudge delegation rather than enforcing it by
  capability — a prompt-injected model that chooses not to delegate
  can reach the residual leg-(a) surface (project source, `.env`,
  dependency caches) through the parent's own `fetch` /
  `web_scrape`. A custom Agent built from `pikuri-core` can
  recreate the shape either way.

## See also

- [Chapter 6 of the guide](docs/guide/06-security.md) — the teaching
  companion to this page: the threat from first principles, the five
  attacks as stories, and a decision procedure for picking a model
  when you build your own harness.
- [`IDEAS.md`](IDEAS.md) §"Security perspective" — open
  mitigations under consideration (egress allowlists, per-tool
  first-use consent, output-byte caps with spillover, secret-
  placeholder patterns), and prior-art notes on how PI and
  opencode handle the same threats.
- [`pikuri-code/README.md`](pikuri-code/README.md) — the
  Bubblewrap sandbox shape and the workspace seam from the
  coding agent's perspective.
- [`pikuri-mcp/`](pikuri-mcp/) — `Mcp::Verifier` source if you
  want to read the pre-flight scan.
