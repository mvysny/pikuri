# Chapter 7 — The OS assistant: your machine, no network

This is the first *complete, fully-implemented* assistant in the
guide — and the gentlest possible introduction to the densest part
of pikuri. `pikuri-os` is a single local agent whose job is to
understand and operate the computer you're sitting at: answer
questions about the system, find and read your files, explain what a
log is complaining about, advise on configuration. Everyone already
owns the concept "an assistant for my machine," and that familiarity
is exactly why this chapter — not the coding agent — is where you
first meet the four seams that the rest of the toolkit is built on:
`Workspace` (what the LLM sees on the filesystem), `Confirmer` (how
user-state changes get approved), `Bash` (running a real shell), and
`Sandbox` (what that shell can actually touch).

There is one thesis sentence to carry through both this chapter and
the next. [Chapter 6](06-security.md) named the lethal trifecta —
private data, untrusted content, a way to send bytes out — and said
you defeat it by *structurally* removing a leg. This is the first
agent that does it, and because reading your whole disk is the entire
point, the leg it removes is **egress**: the network is severed by
the kernel, so a prompt injection in a log file has the data but
nowhere to send it. [Chapter 8](08-code.md) takes these same four
seams and makes the *opposite* cut — it keeps the network (builds
need it) and confines the disk instead. Same adversary, opposite leg.
Hold onto that; it's the through-line.

One honest note about layering before we start. `pikuri-os` is a thin
gem: it rides on top of `pikuri-workspace` (the file tools) and
`pikuri-code` (the shell and the sandbox), the two gems
[chapter 8](08-code.md) returns to directly. We'll meet their
concepts *as this agent uses them*, at introductory depth — the
sharper edges (bubblewrap's overlays, the git-config hardening, the
project-root containment algorithm) wait for chapter 8, where a
developer audience needs them. Reading order isn't dependency order:
the relatable agent comes first, then we peel back a layer.

## Prerequisites

Chapters [1](01-chat.md) and [6](06-security.md). `llama-server`
running, `bundle install` done. Plus a couple of OS-level pieces,
all of which **degrade rather than crash** except the first:

- **`bubblewrap`** (`bwrap`) — the sandbox that severs the network
  lives in it. On Debian / Ubuntu: `sudo apt install bubblewrap`.
  This one is load-bearing, so `pikuri-os-assistant` probes it (and
  the unprivileged user/network namespaces it needs) at boot and
  **raises rather than silently running with an open network**. If
  you genuinely want no sandbox, you have to pass `--no-sandbox`
  and say so out loud.
- **`localsearch`** — GNOME's desktop file index (it ships with the
  GNOME desktop on Ubuntu 26.04+). When it's present you get the
  `fileindex_*` tools; when it isn't, they're simply omitted and the
  agent still works with `bash` and the file tools.
- **`inxi`** — a hardware/desktop summariser, optional enrichment for
  the boot grounding. Absent is fine; the same facts come from
  `/proc`, `uname`, and the environment.

This agent points at your *real* home directory by design. It can't
reach the network, and every change stops for your confirmation — but
it is not a toy sandbox you can be careless in. Read the confirmations.

## 1. Run it

```sh
./bin/pikuri-os-assistant "what's eating my disk in my home directory?"
```

or with no argument for an interactive REPL:

```sh
./bin/pikuri-os-assistant
> find the budget spreadsheet I was editing last week
> why did bluetooth.service fail to start this boot?
```

You'll watch it reach for read-only shell commands (`du`, `df`,
`journalctl`), the file-index tools, and `read` — and *not* stop you
for any of those. The only prompts you'll see are for changes:
writing a file, editing one, a `bash` command that isn't provably
read-only. That asymmetry is the whole design, and the next few
sections are why.

## The Sandbox seam — severing the network (the load-bearing move)

The naive way to build a no-internet agent is to "just not give it
internet tools." That doesn't hold: an unsandboxed `bash` reaches the
network freely with `curl`, `wget`, `nc`, or `apt`, and a sentence in
the system prompt saying "you have no internet" is a *request*, not a
property — a prompt injection in a file the agent reads can ignore it.

So the posture is precise: **a network sandbox with no filesystem
sandbox.** The `Sandbox` seam governs what the `bash` subprocess can
touch, independently of what the LLM sees through its file tools. The
coding agent (chapter 8) uses it to confine bash to a project
directory while keeping the network. The OS assistant wants the
*inverse*, and that's a sandbox variant of its own:

```ruby
sandbox = Pikuri::Code::Bash::Sandbox::FullFsNoNet.new(filesystem: filesystem)
```

`FullFsNoNet` binds `/` read-write — full host control, the whole
point of the agent — but **unshares the network namespace**, so the
shell has no route off the machine. The cut is made by the kernel,
not by the model's good behaviour. And because that property is
load-bearing, the variant *fails loud*: it probes `bwrap` and the
unprivileged namespaces it needs at construction and raises if they're
unavailable, rather than quietly degrading to an open network. The
only way to an internet-capable shell here is the explicit
`--no-sandbox` flag, which swaps in `Sandbox::NONE` and prints a
warning that the security property is off — use it only on a
throwaway box.

**This is where chapter 6's trifecta argument becomes concrete.** The
agent holds two legs — private data (your whole disk) and untrusted
content (logs, `~/Downloads`, cloned repos are all attacker-influenced
bytes) — but never the third. You can't ask it to give up disk access;
reading your machine *is* its job. So you cut the leg you can spare.
An injection that says "append a curl beacon to `~/.bashrc`" has no
network to beacon to, and the same severed leg also contains the more
mundane danger: the model's own honest mistake can't phone home
either. Chapter 8 will keep the network and cut disk-reach instead —
the opposite leg, forced by the opposite need.

## The Workspace seam — the whole disk, one gate

`Workspace` is the *other* filesystem seam — not what the shell
touches, but what the LLM observes through `read` / `write` / `edit` /
`grep` / `glob`. For this agent the whole host is in scope, so it's
wired with the permissive variant:

```ruby
filesystem = Pikuri::Workspace::Filesystem::AllowAll.new(project_root: Dir.pwd)
```

There's no containment here — that's deliberate, and it's the opposite
of chapter 8's project-rooted workspace. `project_root` is just the
anchor for relative paths ("what's in *this* folder?") and the
directory `bash` starts in; absolute paths reach anywhere. The one
narrowing is a credential denylist for the *file tools* — they won't
read `~/.ssh`, `~/.aws`, and friends — though `bash`, running as you,
still can if you confirm a command that does.

Think of the Workspace as a fence around what the LLM can touch
through the file tools. Here the perimeter is down on purpose — the
whole disk is in scope — so just one gate still stands in it: the
**read-before-edit gate**, where `edit` (and an overwriting `write`)
refuses a path the agent hasn't `read` first. It's a small thing here;
chapter 8 raises the perimeter too, fencing the file tools into the
project, when the stakes are a shared repo rather than your own machine.

## The Confirmer seam — mutations stop for a human

Anything that changes your machine routes through a `Confirmer` and
stops for a yes/no. The binary wires the terminal one:

```ruby
confirmer = Pikuri::Workspace::Confirmer::TERMINAL
```

The tool never touches `gets`/`puts` itself — it hands the confirmer a
semantic request (the question, the exact command or bytes) and the
confirmer owns the presentation, including neutralising hostile
control characters in attacker-influenced text before it reaches your
terminal. That last part matters precisely because this agent reads
untrusted files: a log line engineered to look like a confirmation
prompt gets defanged, not rendered. (The `--no-confirm` flag swaps in
an auto-approver — again, throwaway-box only.)

You'll see this fire first not on a destructive command but on the
agent editing its own memory file, which is the next section.

## Confirmation fatigue — the read-only auto-confirmer

"Confirm every command" is right for changes and *miserable* for the
constant harmless reads (`ls`, `cat`, `journalctl`, `df`). And the
fatigue isn't only annoyance — it's a security hole. A user who has
clicked "yes" forty times this session has stopped reading; the
forty-first prompt, the injected one, gets rubber-stamped. Cutting
fatigue *is* security work.

So `bash` isn't handed the human confirmer directly. It's wrapped:

```ruby
Pikuri::Code::Bash::ReadOnlyAutoConfirmer.new(confirmer, allow_git: true)
```

This is a `Confirmer` decorator. It auto-approves a command **only**
when every part of it is a single, metacharacter-free invocation whose
binary is on a tight read-only allowlist (`ls cat head tail wc grep df
du free ps uptime …`, plus `|`/`&&`/`;`-joined chains of such). The
allowlist holds only binaries that are safe in *all* their argument
forms — `find` is excluded (`-delete`), `dd`/`tee`/`truncate`/`shred`
are excluded, anything with a destructive mode is out. The failure
mode is "asks too often," never "approved a deletion." Everything else
falls through to the human.

`allow_git: true` extends that to read-only git verbs (`status`,
`diff`, `log`, `show`, `blame`). On its face that's unsafe — even a
bare `git status` executes whatever the repo's `.git/config` directs
(`core.fsmonitor` is an RCE vector that fires on the most common
command). It's safe here *only because* `Bash` hardens the git
environment so a hostile repo-local `core.fsmonitor` is neutralised
regardless of what the repo says. That's the headline vector closed
deterministically; the residual (diff-driver execution on a repo whose
`.git/config` an attacker handed you) is documented and accepted — a
genuinely untrusted repo belongs in a VM. Chapter 8 unpacks that
hardening; here, take it as the reason there's no per-repo trust prompt.

There's a cheaper lever, too, and it's mostly in the system prompt:
the agent already has non-confirming `read`/`grep`/`glob` tools, so the
prompt nudges it to *prefer those for looking* and keep `bash` for
*acting*. That pushes the whole 80% of read-only work onto tools that
never prompt, leaving `bash`'s residual confirmations aligned with the
genuine changes you want to see anyway.

## Finding things — fileindex_search and fileindex_read

`find` and `grep` are fine for filenames and plain-text content, but
they're slow over the entire home directory and blind to PDFs and office
documents. GNOME already solved this: the desktop ships `localsearch`,
a file indexer that has *already extracted the full text* of your
PDFs, spreadsheets, and documents, and it's entirely local — inbound
only, nothing to send out, a perfect fit for the no-egress posture.

`pikuri-os` exposes it as a **search → read-full pair**, the same
two-step shape as `vectordb_search` → `vectordb_read` from
[chapter 3](03-vectordb.md):

- **`fileindex_search`** finds files whose contents match your words —
  inside PDFs and office docs included — and returns each path with the
  one short snippet the index provides. It's honest about being a
  *locator*: the index reports at most one match per file, so the tool
  doesn't pretend to show the whole story.
- **`fileindex_read`** then returns a file's full extracted text,
  line-paged exactly like the `read` tool, with no extractor of its
  own (the index did the extraction at index time).

It covers your home and XDG folders, not system paths — `/etc` and
`/var` aren't indexed, so the agent reaches for `grep` there. And it's
best-effort: when `localsearch` is absent or disabled the tools are
simply not wired, and the agent falls back to `find`/`grep`. This is
"spotlight" as two tools the LLM reaches for, and we got it from the
pre-installed index for free — which is also why a vector DB earns no
place in this agent: pointing one at `$HOME` would re-index the exact
corpus `localsearch` already holds.

## MACHINE.md — durable notes about this machine

An assistant for your computer should remember where you keep your
work, how your files are synced, the quirks of *this* setup — and have
that knowledge in hand at the start of the next conversation.
[Chapter 4](04-memories.md) built durable memory as mem0: automatic,
invisible capture into a vector store. For this agent the answer is
deliberately simpler — a single markdown file:

```
~/.config/pikuri/MACHINE.md
```

A `CLAUDE.md` for this host. It's read at boot and folded into the
system prompt, and the agent edits it through the *same confirmed
`write`/`edit` path* as any other file. That choice is the whole
point of contrast with chapter 4. mem0's safety rested on an invisible
structural filter ("capture user-role content only"); `MACHINE.md`'s
safety is **visible, confirmed, and reversible** — a poisoned fact
can't land silently, because the write surfaces to you as a plain-text
diff ("agent wants to append: *backup server is `evil.example`*")
before it takes effect, and you can open and edit the file any time.
For one machine's small, bounded fact set, that beats a vector store
and a docker sidecar; it reuses machinery the agent already has and
needs no retrieval tier at all. (When the file doesn't exist yet, the
prompt still tells the agent where to create it.)

The residual to keep in view: a fact in `MACHINE.md` is in the
*system prompt* — instructions-adjacent, higher-privilege than a
mid-conversation recall — so a rubber-stamped poisoned edit has real
steering power. The counterweights are that it's your own trusted
file and every write is confirmed; the severed network still contains
the blast radius. There's a soft size guard, too: past ~10k the agent
is nudged to trim, the same way the Claude CLI nudges an oversized
`CLAUDE.md`.

## Grounding — what the agent already knows about the host

A local model knows the FHS, man pages, `apt`, XDG, and bash well —
the prompt doesn't waste words re-teaching those. What it *can't* know
is *this* host, so the agent folds a small grounding block into the
system prompt at boot: distro and version, desktop environment, init
system, kernel, CPU/memory at a glance, the current date. Two of the
facts pre-empt a wrong guess the model otherwise makes routinely: the
**packaging** line names the host's manager (apt / dnf / pacman / …,
plus whether flatpak and snap are present), so it hands the user the
right install command instead of assuming apt; and the **dmesg** line
says up front whether reading the kernel ring buffer works as this user
or needs `sudo` (read from `kernel.dmesg_restrict`, not by spawning
`dmesg`), so it doesn't propose a command that returns "operation not
permitted". When `inxi` is present, `inxi -b` enriches the block; when
it isn't, the same facts come from `/etc/os-release`, `uname`,
`$XDG_CURRENT_DESKTOP`, `/proc`, and a `$PATH` probe. `inxi` is a
convenience, never a dependency — a missing one is silent, not fatal.
This is cheap and stops the model guessing distro paths.

## The wiring all together

One extension assembles the whole surface, the same `add_extension`
shape you've used since chapter 2:

```ruby
agent = Pikuri::Agent.new(
  transport: Pikuri::Agent::ChatTransport.from_openai_server(server:, model:, api_key:),
  system_prompt: system_prompt,
  step_limit: Pikuri::Agent::Control::StepLimit.new(max: 40)
) do |c|
  c.add_listener Pikuri::Agent::Listener::Terminal.new
  c.add_tool Pikuri::Tool::CALCULATOR
  c.add_extension Pikuri::Os::Extension.new(
    filesystem: filesystem,   # AllowAll(project_root: Dir.pwd)
    confirmer:  confirmer,    # the *human* confirmer
    sandbox:    sandbox,      # FullFsNoNet
    read_only:  read_only     # the shared plan-mode flag, below
  )
end
```

`Os::Extension` is a composite: it adds `Workspace::Extension` (the
five file tools) and `Code::Extension` (`bash`, wrapped in the
read-only auto-confirmer), then layers on the `fileindex_*` tools, the
grounding block, and the `MACHINE.md` section. The binary doesn't
re-derive any of that — and neither will the TUI or web client that
wire the same object later.

The one piece the host keeps a handle on is **plan mode**: a shared
`Workspace::ReadOnly` flag, threaded into both the file tools and
`Code::Extension`. Flipping it on (the REPL's `/plan`) makes `write`
and `edit` refuse — research and design without touching anything —
and `/impl` flips it back. It gates only the *writing* file tools,
never `bash`'s read-only commands, and the toggle is host-side: it's
never sent to the model.

## The third leg, deferred

The obvious next wish is "give it the internet." We don't — yet — and
the reason is the whole point of this chapter. Egress is the leg we
removed to make reading your dirty disk safe. Adding it back reassembles
the full trifecta: private data (your disk) + untrusted content (logs,
downloads) + a way out. The clean answer is a privilege-separated
investigator sub-agent that can search the web but is structurally
barred from the private filesystem context — which depends on taint
machinery that isn't built. So the internet OS assistant is a future
chapter, not a flag; until then, the severed network is what keeps this
design simple and safe.

## What's next

[Chapter 8 — the in-repo coding agent](08-code.md) takes the four
seams you just met and makes the opposite cut. Where this agent
severed the network and kept the whole disk, the coding agent keeps
the network — a build needs it — and confines the disk instead:
`Bubblewrap` in place of `FullFsNoNet`, a project-rooted `Workspace`
in place of `AllowAll`. Same `Confirmer`, same `bash`, same
read-only auto-confirmer (now with the git hardening unpacked). Same
adversary, opposite trifecta leg — and now in a developer's hands,
with read-only recon sub-agents on top. The threat-model accounting
for both shapes is [chapter 9 — security
revisited](09-security-revisited.md).
