# OS/Linux Assistant

Status: **brainstorm, but a buildable one.** Unlike the federation
([`assistant.md`](assistant.md)), this note does *not* depend on an
unsolved UX problem — it's a single agent with one chat box. The open
questions here are scoping and confirmation ergonomics, not "is the
whole shape viable."

Related:

- [`assistant.md`](assistant.md) — the federation. **This note is the
  federation's `@private`/`@os` member, extracted and shipped as a
  standalone single agent.** It sidesteps the federation's unsolved
  half (the hand-orchestration tax) by simply not being a federation
  yet: one agent, no inter-agent routing. When/if the federation lands,
  this becomes one of its siblings.
- [`trifecta-detector.md`](trifecta-detector.md) — the three legs
  (private data / untrusted ingest / egress). This design breaks the
  trifecta by **enforced removal of the egress leg**, not by trusting
  its inputs.
- [`../CLAUDE.md`](../CLAUDE.md) §"Sandbox seam" — the existing
  `Code::Bash::Sandbox` (Bubblewrap) is the enforcement mechanism; see
  §"How the egress leg is severed" below.

## The idea

A single local agent whose job is to **understand and operate the host
OS**: answer questions about this machine, find and open files, read
logs and explain errors, advise on configuration. **Target platform:
Ubuntu 26.04 LTS or newer**, GNOME desktop (a recent baseline we can
make assumptions about — see §"File search"). Full read-write view
of the real filesystem (the whole point is to control the host, so
there is no *filesystem* sandbox). Local LLM only, running in
`llama-server`. No cloud account, consistent with pikuri's
privacy-first default.

**Target model: `unsloth/Qwen3.6-35B-A3B-GGUF` at `Q4_K_M`** (~22 GB) —
a Mixture-of-Experts with 35 B total parameters but only ~3 B active per
token (256 experts, 8 routed + 1 shared), 262 K native context.
Verified on Hugging Face. The MoE shape matters for the next question.

The reason to start here rather than with the general assistant: with
the network severed (below), the agent holds at most two trifecta legs
and can never silently exfiltrate. That lets us postpone the trifecta
work *and* the federation UX work, and still ship something genuinely
useful — a model trained on Linux + bash, grounded in this machine's
actual environment, that can read man pages and local docs.

## How the egress leg is severed (the load-bearing part)

The naive framing — *"no sandbox, just don't give it internet tools"* — does
not hold: an unsandboxed `bash` reaches the network freely (`curl`,
`wget`, `nc`, `apt`). "No internet" stated only in the system prompt is
a *request*, not a property, and a prompt injection in a local file can
ignore it.

So the posture is **not "no sandbox" — it's a *network* sandbox with no
*filesystem* sandbox.** The mechanism already exists in the tree:
`Code::Bash::Sandbox::Bubblewrap` today binds the workspace and runs
`--unshare-all --share-net` (it *keeps* the network because the coding
agent needs it). The OS assistant wants the **inverse config**: bind
`/` read-write (full host control) but `--unshare-net` to drop the
network namespace. That's a new sandbox variant (working name
`Sandbox::FullFsNoNet`) reusing the existing seam — the egress leg is
then severed by the kernel, not by a prompt.

## What "trust local files" really means

The earlier draft claimed *"we trust local files for no prompt
injection."* That is false on a real machine. The filesystem is full of
attacker-influenced bytes: `~/Downloads`, browser caches, cloned git
repos, mail stores (`~/.thunderbird`), and especially **logs** — an
attacker who hits your web server controls your nginx access log;
device/USB strings land in `journalctl`/`dmesg`. Reading logs to
diagnose errors is a headline use-case, so the untrusted-ingest leg is
effectively always present.

The defense is therefore *not* "the inputs are clean." It's two
enforced properties that make a dirty input safe to read:

1. **Enforced no-egress** (the `--unshare-net` above) — an injection
   has nowhere to exfiltrate to.
2. **Confirm every mutation** — `Bash`, `Write`, and `Edit` all route
   through `Workspace::Confirmer`, so a destructive command surfaces to
   the human before it runs.

Note that property 2 defends against *two* failure modes at once: a
prompt injection that says "append a curl beacon to `~/.bashrc`", **and**
the more mundane (and more likely) one the user flagged — the LLM
itself hallucinating a `rm -rf ~` or an overwrite of the wrong file.
With full filesystem write access, the model's own honest mistakes are
as dangerous as any attacker, and the confirmer is the same guard for
both. (This is also why the `Confirmer` must show the *exact* command/
bytes and neutralize hostile control characters — see CLAUDE.md
§"Confirmer seam".)

## Load-bearing invariants

1. **Network is kernel-severed, not prompt-severed.** Every `bash` (and
   any subprocess) runs net-isolated. If this is relaxed to a
   prompt-level convention, the trifecta claim is void.
2. **Mutations are always confirmed.** `Bash`/`Write`/`Edit` through the
   `Confirmer`. This is the only thing standing between a hallucinated
   (or injected) destructive command and your files.
3. **Advise, don't execute, anything privileged or networked.** The
   agent *does* unprivileged user-space actions; for anything needing
   `sudo` or the network (installing packages, restarting services,
   editing `/etc`, active connectivity probes) it **hands the user the
   command to run themselves.** This generalizes the original "if sudo
   is needed, the user runs it" and also dissolves the apt/snap
   use-case: the agent evaluates *which* package you want and prints
   `sudo apt install …`; you run it. (Installing needs both root *and*
   egress, so it could never have been an agent action under invariant
   1 anyway.)

## Tools

- **`bash`**, net-isolated (invariant 1), confirm-every-command
  (invariant 2).
- **Workspace tools** (`read`/`edit`/`glob`/`grep`) with unrestricted
  access to the whole disk, including `/etc` and sensitive home files
  like `~/.ssh`. `edit` mutates, so it confirms; `read`/`glob`/`grep`
  are inbound-only and don't.
- **Memory** of facts about *this particular computer* — where the user
  keeps music / work folders / documents, whether they're synced and by
  what (Dropbox, Syncthing, …), and useful conclusions from past
  sessions. This is the `@private`-posture memory: no untrusted ingest
  by construction (the user's own words + this machine's state) and no
  egress, so auto-capture is sound here — the exact context
  `pikuri-memory`'s DESIGN.md calls safe.

## Is a 35B-A3B model big enough to know Linux? (educated guess: yes)

The worry with the target model is the `A3B` — only ~3 B parameters fire
per token. But the two things that number governs are different:

- **Factual recall scales with *total* parameters** (knowledge is spread
  across the 35 B of experts), not with the active budget. For "does it
  know the FHS / man-page conventions / apt basics", 35 B is the
  relevant figure, and it's comfortably enough.
- **Reasoning depth per step scales with *active* parameters** (~3 B).
  This is the genuine weak spot: multi-step diagnosis ("service X failed
  → its log says Y → therefore Z") will be shallower than a dense 30 B.

Two reasons the educated guess still lands on "yes":

1. **Linux/bash is one of the densest domains in any code-leaning
   pretraining corpus** — GitHub, Stack Overflow, distro wikis, man-page
   dumps. FHS layout (`/etc`, `/var/log`, `/usr`, XDG paths), coreutils,
   systemd basics, apt are over-represented. Even 7 B models handle this
   competently; 35 B total is not the bottleneck.
2. **The design compensates for both weak spots by construction.** The
   shallow-reasoning risk is absorbed by the *agent loop* — it doesn't
   have to one-shot a diagnosis, it iterates with tools. And the
   currency risk (exact package names, version-specific paths) is
   exactly what the machine-specific grounding below + the
   read-the-man-page-on-demand tools fix: the model can **verify by
   reading rather than trusting recall**. A man-page `read` beats a
   remembered flag.

Where it *will* show strain: long-tail man-page specifics (obscure
flags), version-specific systemd/distro changes, and deep causal chains.
All three degrade gracefully here — wrong recall becomes a tool call
that reads the truth, and the confirmer catches any bad mutation. Worth
testing as we implement, but no reason to expect a wall.

## How the LLM learns about this machine

Per the above, the model already knows FHS, man pages, apt, XDG, and
bash well — don't spend the prompt re-teaching basics. Spend it on
**machine-specific grounding** so the model doesn't hallucinate distro
paths:

- Bake into the system prompt at boot: `/etc/lsb-release` (distro +
  version), desktop environment (GNOME/KDE), `$HOME`, login shell, and
  current date/time.
- Optionally fold in `inxi`/`lsb_release` output for hardware/DE
  context.
- Linux-first; **target Ubuntu 26.04 LTS or newer** (Debian likely free).
  Pinning a recent baseline lets us assume what ships by default — e.g.
  the GNOME file index (§"File search") — instead of probing for it.
  XDG conventions are cheap to include and pay off in path accuracy.
- Local offline docs (Ubuntu help, man pages) are a natural
  `pikuri-vectordb` corpus if recall quality justifies it — deferred,
  not v1.

## v1 scope (deliberately narrow)

Ship the read-heavy, low-risk slice — exactly the slice the two enforced
properties cover completely:

- **Answer questions about this system** (what's installed, what's
  running, disk/resource state).
- **Find and open files** — filenames via `find`/glob, content via the
  GNOME index (§"File search"); open/edit via `xdg-open`.
- **Read logs and explain errors** — `journalctl`, `dmesg`, kernel log;
  resolve from local knowledge + man pages where possible.

Deferred past v1: package install/eval, systemd mutation, GUI-config
*application* (vs. advice), app launching, and anything needing the
network.

## File search: filenames vs. content (the indexer question)

`find`/`rg` are fine for *filenames* and for *plain-text content*, but
they fall down on the two things a "spotlight" needs most: they're slow
over a large home directory cold, and they can't see inside PDFs or
office documents at all. So the design splits into two tiers:

**Filename / path search → no index needed.** `find` / `fd` / glob over
the relevant roots. Fast enough, always correct, zero setup. Handles
"find file xyz", "where's my budget spreadsheet".

**Content search, including PDFs and office docs → prefer the
pre-installed GNOME index.** Ubuntu's GNOME desktop already ships and
runs a file indexer — **`localsearch`** (the indexer/miner) backed by
**`tinysparql`** (the SPARQL store), the 2024 rename of
`tracker-miners` / `tracker3`. It's the same index GNOME Files and the
Shell search already use, it extracts full text from PDFs (via poppler)
and office formats, and — crucially for us — it's **entirely local and
inbound**, so it fits the no-egress posture with nothing to add. The
agent queries it by shelling out (`localsearch search "<terms>"`, or a
SPARQL query against `tinysparql` for structured filters like
mime-type/mtime). Targeting Ubuntu 26.04+ is what lets us *assume* it's
there rather than probe.

Three caveats, all of which point to keeping `rg` as the fallback, not
the primary:

1. **Scope.** `localsearch` indexes the user's content directories
   (`$HOME` + XDG dirs by default), **not the whole filesystem**.
   Anything under `/etc`, `/var`, or other system paths is outside the
   index — those still go through `rg`/`grep`. That's fine: system-file
   search is small and text, exactly `rg`'s strength.
2. **Reliability.** The indexer has a mixed reputation (resource churn,
   occasional stale/empty index) and some Ubuntu users disable it. So
   the agent should **check it's alive and populated** (`localsearch
   status`) before trusting it, and fall back to an extract-then-grep
   pass otherwise — which pikuri can already do via the
   `pikuri-extractors` PDF/office→text seam, just slower and ad-hoc.
3. **Freshness.** The index lags very recent writes; for "the file I
   saved 10 seconds ago", a filename `find` is more reliable than the
   content index.

So: filenames via `find`, content via `localsearch` when healthy and
in-scope, `rg` + on-demand extraction everywhere else. A curated,
always-fresh corpus (vs. the OS-wide index) remains
`pikuri-vectordb`'s job — out of scope for the OS assistant's
"search my actual disk" use-case, but the natural upgrade if recall
quality on `localsearch` disappoints.

## Use-cases (the broader wishlist, for direction)

- Spotlight-style: "find file xyz", "open the budget spreadsheet".
- Find-in-files / find-in-content — see §"File search" (GNOME
  `localsearch` for PDFs/docs when healthy, `rg` otherwise).
- System health: high resource usage, running out of disk.
- systemd: detect failed services, summarize their logs (read + advise;
  restart is user-run).
- GUI config help ("reverse the trackpad scroll direction") — GNOME
  first; mostly advice + the exact `gsettings`/`dconf` command.
- Kernel/system error diagnosis from local logs.
- Network *diagnosis* is mostly local reads (`nmcli d show`, `ip addr`,
  NetworkManager state) and works fine net-isolated; only an active
  probe (`ping`) needs egress and is therefore user-run.
- Package evaluation: advise which apt/snap package fits; for snap
  prefer recognized publishers (Canonical etc.). Install is user-run.
- *Not* an email/app searcher unless the indexer supports it cleanly;
  app launching is possible but slower than the native launcher
  (acceptable only if the user opts in).

## Open question: confirmation fatigue

"Confirm every command" is correct for mutations but tiresome for
obviously read-only ones (`ls`, `cat`, `journalctl`, `nmcli d show`).
With egress kernel-severed, read-only bash is genuinely low-risk, so
there's room to auto-allow read-only commands and confirm only
mutations — but classifying "read-only" from a shell string is a losing
parse game (`cat x | sh`, command substitution). v1 keeps
confirm-everything as the safe default; smarter gating is a later
refinement, not a launch blocker.

## Future (deferred)

- **Internet access**, likely via a privilege-separated investigator
  sub-agent that can search the web but is structurally barred from the
  private filesystem context — at which point the full trifecta work
  (and possibly the federation) is back on the table. Until then, the
  severed network leg is what keeps this design simple and safe.
