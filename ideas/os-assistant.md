# OS/Linux Assistant

Status: **brainstorm, but a buildable one.** Unlike the federation
([`assistant.md`](assistant.md)), this note does *not* depend on an
unsolved UX problem — it's a single agent with one chat box. Scope and
confirmation are settled into a v1/v2 split below; what's left is
empirical validation (does the local model cope, does keyword recall
suffice) — not open design questions, and never "is the whole shape
viable."

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

- **`bash`**, net-isolated (invariant 1). Confirmed by default, with a
  conservative deterministic auto-confirmer for provably-read-only
  commands — mutations always reach the human (invariant 2). See
  §"Confirmation fatigue".
- **Workspace tools** (`read`/`edit`/`glob`/`grep`) with unrestricted
  access to the whole disk, including `/etc` and sensitive home files
  like `~/.ssh`. `edit` mutates, so it confirms; `read`/`glob`/`grep`
  are inbound-only and don't.
- **Memory** of facts about *this particular computer* — where the user
  keeps music / work folders / documents, whether they're synced and by
  what (Dropbox, Syncthing, …), and useful conclusions from past
  sessions. **A single user-owned `MACHINE.md`**, not mem0 — a
  `CLAUDE.md`-for-this-host: appended to the system prompt at boot,
  agent-editable through the confirmed `Write`/`Edit` path,
  user-inspectable and -editable any time. See §"Memory: a single
  auditable `MACHINE.md`" for why this beats mem0 here.

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
- **Always fold in desktop-environment + machine context** (distro,
  `Init: systemd`, `Desktop: GNOME <ver>`, CPU/mem at a glance). This
  *information* is not optional — it's the highest-value grounding,
  cheap, and stops the model guessing about the host. What's optional is
  the **source**: `inxi -b -c 0` is the convenient one when present. Use
  `-b` (*basic*), **not** `-e`/`-F` — the latter is a full hardware dump
  (audio codecs, sensors, every partition, GPU/EGL APIs) that bloats the
  prompt with detail an OS-help agent rarely needs. `-c 0` strips inxi's
  color codes. Treat it as a source to curate from, not bytes to paste
  verbatim (inxi has cosmetic quirks, and `Desktop:` only populates
  inside a running graphical session).
- **inxi is one source for that info, not a dependency — if it's absent,
  gather the same facts from primitives; do not raise and do not nag the
  user to install it.** inxi is a convenience aggregator (and only in
  `universe`, not guaranteed pre-installed); every grounding fact it
  carries has an always-present source: distro from `/etc/os-release`,
  kernel/arch from `uname -srm`, init from `ps -p1 -o comm=`, **DE from
  `$XDG_CURRENT_DESKTOP`** (more reliable than inxi, which needs a live
  graphical session), CPU/mem from `/proc` or `free -h`, shell/home from
  the environment. So the grounding block is always built — from inxi
  `-b` when present, from those primitives otherwise. The deeper
  hardware detail inxi alone gives (exact GPU, sensors, mobo) isn't
  needed up front; if a question ever calls for it, the agent runs
  `inxi`/`lspci`/`lscpu` on demand — when it exists. A missing inxi is
  never a fatal or user-facing condition.
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

Deferred past v1: package *installation* (vs. advice — the agent may
still recommend *which* package per invariant 3; running the install is
user-run), systemd mutation, GUI-config *application* (vs. advice), app
launching, and anything needing the network.

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

**Getting enough context around a match (a two-call split).**
`localsearch search` is *discovery*, not *retrieval*: it returns which
files matched plus a **tiny** built-in snippet — measured on a 26.04 box,
about 3–4 words each side of the hit ("…physical or **environmental**
damage…"), meant only to confirm "is this the right file." There is
**no flag to widen it** — verified: `-d`/`--detailed` only adds the
resource URN, `-t`/`--documents` is a type filter (not "detailed"), and
the snippet length isn't configurable. The route to a real window is a
**second call**: LocalSearch already extracted and stored each file's
plain text, so

```
localsearch info -c -o json-ld /path/to/file.pdf
```

returns that full indexed text (PDF/office included, no re-extraction).
Use `-o json-ld` and read `nie:plainTextContent` — it comes back as a
clean JSON string with real newlines; the default turtle output indents
the body to align under the RDF property, which is fiddly to de-mangle.
So the content tier is a *search → read-full* pair: `search` finds the
file, `info -c` returns its whole extracted text. That's the same
two-step shape as `vectordb_search` → `vectordb_read` — and we get it
from the pre-installed index for free, which is part of why
`pikuri-vectordb` earns no place here (below).

**A purpose-built tool collapses the two calls into one.** Rather than
make the LLM orchestrate `search` → `info -c` → slice-by-hand every
time, wrap it: a single content-search tool that takes a phrase, runs
`localsearch search` to find matching files, then for each top hit pulls
the stored text (`info -c -o json-ld`) and returns a **~100-word window
centered on the match**.

*Why ~100, not 500.* This tool is the **search** half of a search→read
pair, not the only step — if a hit looks right, the full document is one
cheap `info -c` away (parent-document retrieval, the same escalation
`vectordb_read` gives). So the window only has to be big enough to
*judge relevance and often answer*, not to be the whole answer. ~100
words (±~50 around the term, ~130 tokens) hits that: ~8–10 hits still
fit in ~1k tokens, which matters because the local Qwen is likely served
with a far smaller context (8–32K) than its 262K ceiling. 50 words is
too thin (barely beats the native snippet); 500 is *reading a page* —
that's the escalation step, not the default. Keep it **configurable
(default ~100, cap ~300–400)**, with "read the full document" as the
explicit next move.

Tool shape (matching the parameter conventions):

- **Description advertises scope** — that it searches the GNOME index
  (point at `localsearch status` for what's indexed: `$HOME` + XDG dirs,
  *not* system paths), so the LLM knows to reach for `grep` on `/etc`,
  `/var`, etc.
- **Params:** `query`, `limit` (default ~10), `window_words`
  (default ~100), optional type filter.
- **Returns** per hit: path + a ~100-word window centered on the match;
  ≤2–3 merged windows when a file matches in several places.
- **Stemming gotcha:** localsearch FTS is stemmed (`environment` matches
  `environmental`), so a literal grep of the query against the stored
  text can miss. Locate the **highlighted surface form** the snippet
  already returns, fall back to a prefix/stem match, then to the
  document head if still unfound.
- **Fallbacks:** path outside the index → `rg -C` over the live file
  (or extract-then-window via `pikuri-extractors`); binary and text are
  both handled because `info -c` returns already-extracted text.

This is the content half of "spotlight" as one tool the LLM reaches for
— `grep`'s `-C`, but word-based and able to see inside PDFs/office docs.

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

So: filenames via `find`, content via `localsearch` (discover with
`search`, read full text with `info -c`) when healthy and in-scope,
`rg` + on-demand extraction everywhere else.

**`pikuri-vectordb` is explicitly *not* the upgrade path here.** It is
not a better `localsearch` — it's a *different* tool (semantic/embedding
recall vs. keyword full-text), and pointing it at `$HOME` would
**duplicate the corpus `localsearch` already indexes**: a second walk, a
second extracted-text store, embeddings + a vector DB to maintain — all
to discover the *same files* `localsearch` already surfaces. The OS
assistant's job is "search my actual disk," which is keyword-shaped and
already covered. Semantic recall over the whole home is a *deferred,
speculative* use-case at most, and even then it buys little over the
pre-installed index for discovery; it doesn't supersede it. `vectordb`
keeps its existing, distinct job — a small *curated* corpus
(`pikuri-corpus`), not the home directory — and stays out of this
design.

The one honest caveat to test for: the windowed content tool is only as
good as `localsearch`'s **keyword** match. A fuzzy/semantic ask ("the
doc about our refund policy") can miss when the words don't literally
appear — and that miss is exactly the gap semantic recall would close.
So the deferred semantic option isn't dead, it's *scoped*: revisit it
only if real usage shows keyword recall failing, and even then for that
specific gap, not as a wholesale home-directory re-index. Find out when
we prototype.

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

## Confirmation fatigue

"Confirm every command" is correct for mutations but tiresome for the
frequent harmless ones (`ls`, `cat`, `journalctl`). The handling here
is more than a footnote because of one reframe:

**Fatigue is a security problem, not just UX.** A user who has clicked
"yes" forty times this session has stopped reading; the forty-first
prompt — the hallucinated or injected one — gets rubber-stamped. So
cutting fatigue *is* security work; the two pull the same direction.
And the job is narrower than it looks: with egress kernel-severed
(invariant 1) and sudo user-run (invariant 3), confirmation guards
exactly **one** thing — *irreversible local destruction* of the user's
files. Not exfiltration, not privilege escalation. The classifier's
question is "could this destroy data?", not the much harder "is this
safe in general?"

**Two tool classes, split by analyzability.**

- **`Write`/`Edit` are structurally analyzable** — a known path + known
  bytes. Reliable rules are possible: auto-allow new files / edits to
  already-read files in non-sensitive zones; always confirm sensitive
  targets (`~/.ssh`, `~/.config`, dotfiles, `/etc`, outside `$HOME`) and
  show the diff. (Deferred to v2 — see the menu — but reliable when
  built, *because* the inputs are structured.)
- **`Bash` is an opaque, Turing-complete program.** Static allow-
  patterns on the command string lose: `git st | rm -rf ~`, `$(rm -rf
  ~)`, `eval`, `awk 'BEGIN{system(...)}'` all defeat "starts with git."
  Note `Code::Bash` runs `bash -c <command>` and does **not** restrict
  metacharacters at execution — what it sanitizes is the *display*
  (`Sanitizer` → displayed == executed), which is the *precondition* for
  any safe gate, not a gate itself.

**No AI in the decision — ever (and none at all in v1).** An AI
*approver* can be talked into "yes" by the same laundered content that
fooled the agent — and it's slow and non-deterministic. An AI *warner*
that's usually silent is worse than it looks: it trains the user to read
"no warning" as "safe," so it becomes an approver by conditioning — and
its blind spots **correlate with attacker effort** (an injection crafted
to look benign looks benign to the warner too), so it goes quiet exactly
when noise is needed, having *already lowered* the human's vigilance. It
can make the system worse than honest manual confirmation. (Contrast the
MCP verifier: a one-shot, low-frequency check of static text where the
human isn't in a per-call loop — opposite cost/benefit.) The only safe
use of AI here is to *translate* ("this deletes `~/tmp` recursively"),
always shown beside the raw command, never as a ✓/⚠ verdict — and even
that waits for later. The invariant: **AI translates; code and the human
decide.**

### v1: a conservative deterministic auto-confirmer

Implementable now as a `Confirmer` decorator wired onto `Bash` (it
implements `confirm?(request:)` and wraps the human confirmer; the
request already carries the command verbatim). It auto-approves **only**
a command that is a *single invocation, with zero shell metacharacters,
whose binary is on a tight read-only allowlist* — or, since the
composition refinement below, a `&&`/`||`/`;`/`|`-joined chain of such
invocations; everything else is delegated to the human. Failure mode is
"asks too often," never "approved destruction."

**Shipped refinement — sequencer / pipe composition.** The decorator
now also auto-approves a command split on the shell sequencer/pipe
operators (`&&`, `||`, `;`, `|`) when *every* segment is independently a
provably-read-only invocation (`cd notes && ls`, `ps aux | grep ssh`,
`df -h ; free -m`). Two facts make it sound: (1) the split is faithful
because the per-segment metacharacter check still forbids both quote
characters and the backslash (so no operator can hide in a string) and
every *other* metacharacter — redirects, background `&`, `$()`, globs —
stays forbidden per segment, so a writing operator like `ps | grep x >
out` delegates the whole command; (2) a pipe grants no new capability —
no allowlisted binary writes a file or executes a program from its
stdin, and the data→action escalators (`xargs`, `sh`, `tee`) aren't on
the allowlist, so `ls | xargs rm` / `cat x | tee y` both delegate. `cd`
was added to the allowlist for this (a builtin with no destructive
form, useful only in a chain). Note this is *necessary but not
sufficient* for `cd X && git diff`: `git` stays delegated (see the v2
menu — read-only `git`/`systemctl`/`journalctl` subcommands need
subcommand-aware rules and, for `git`, pager/textconv/`ext::` hardening
the boolean confirmer can't inject).

The care is in the **allowlist**, not the code: metacharacter-free is
necessary but not sufficient — `find . -delete`, `sort -o f`, `systemctl
stop`, `git reset --hard`, `dd`, `tee`, `truncate`, `shred` are all
single, metacharacter-free, *destructive* invocations. So the list holds
only binaries safe in *all* arg forms (`ls cat head tail wc grep rg
nproc uname id pwd date stat file df du free ps uptime whoami hostname`
…) and excludes anything with a destructive mode. ~40 lines on top of
the existing seam; the substance is curating that list.

### v1's bigger lever: route reads off bash

The cheapest win needs almost no code. The fatigue is overwhelmingly
*read-only* commands, and the agent already has non-confirming
`Read`/`Grep`/`Glob` tools. A prompt/persona nudge — "prefer the read
tools; use bash for *actions*, not for looking" — pushes that whole 80%
onto tools that never prompt, leaving bash carrying mostly genuine
mutations, which you *want* confirmed anyway. So v1's residual
confirmations are *aligned* with where confirmation earns its keep.

### v2 menu

- **`Write`/`Edit` path-zone auto-allow + diff render** (reliable, per
  the analyzability split above).
- **Subcommand-aware read rules** — recover the *read* verbs of
  otherwise-excluded binaries: `git diff`/`status`/`log`/`show`,
  `systemctl status`, plain `journalctl`. The hard part is `git`,
  because **even a bare `git diff` is not an inert read — it executes
  whatever the repo's git config directs.** The live code-execution
  vectors:
  - `core.fsmonitor = <cmd>` — `git diff` refreshes the index, which
    runs the fsmonitor command (regardless of TTY). RCE.
  - `diff.<driver>.command` / `.textconv` — a *committed*
    `.gitattributes` selects a driver; the driver's command lives in
    config. Runs during the diff. RCE.
  - the pager (`core.pager`/`PAGER`) is the one vector *already closed*
    here: `Subprocess.spawn` captures via `Open3.popen2e`, so git's
    stdout is a pipe not a TTY and plain `git diff` won't auto-page —
    so the residual is the config-*execution* keys above, not the pager.

  All the live vectors are **config-gated**, and `git clone` never
  copies the remote's config into local `.git/config`. So the deciding
  variable is **repo-config trust, not network/sandbox**: a repo *you
  cloned yourself* has clean config and `git diff` is effectively safe;
  a checkout *handed to you with its `.git/` intact* (tarball, shared
  dir, a config an earlier tool step wrote) has attacker-controlled
  config and `git diff` ⇒ RCE. (`safe.directory` only guards repos
  owned by a *different* uid.) And no current mode rescues an
  untrusted-config repo — each closes the wrong leg of the trifecta:
  under `FullFsNoNet` the no-net stops exfil but not a wiper
  (`core.fsmonitor = rm -rf ~` is exactly the irreversible local
  destruction the confirmer exists to prevent); a sandboxed-but-
  networked agent contains fs damage but allows exfil. A boolean
  confirmer can't rewrite the command to harden it, so the real
  prerequisite is **hardened git execution** (`git --no-pager -c
  core.fsmonitor= -c diff.external= …`, with neutralized system/global
  config) — a config-key *denylist*, which is why `git` stays delegated
  for now.
- **Session-sticky grants** — "always allow `journalctl` this session,"
  sticking the *simple-invocation* form only. This is Claude Code's
  actual shape: deterministic allow/deny rules + user-granted session
  approvals, **no LLM in the yes/no** — the strongest precedent for "AI
  never approves."
- **Batching** — present several queued commands as one prompt, not N
  round-trips.
- **AI translation aid** — optional, never a verdict, always beside the
  raw command.

## Memory: a single auditable `MACHINE.md`

The memory-pollution problem below is real, and **the v1 answer is a
markdown file, not mem0.** A single user-owned `MACHINE.md` (a
`CLAUDE.md` for this host) holds the facts — folder locations, sync
system, learned conventions — and is **appended to the system prompt at
boot**. The agent edits it through the normal confirmed `Write`/`Edit`
path; the user can open, diff, and edit it any time.

**Location: `~/.config/pikuri/MACHINE.md`** (XDG, host-scoped) — not
project-local, because for this agent the machine *and the user's home*
**are** the project: `MACHINE.md` records facts spanning the whole host
(where music/work/documents live, which sync system, system quirks), not
any one directory. A single canonical XDG path is what the boot-append
and the agent's edit-path both resolve to.

Why this beats mem0 *for this agent*:

- **It reuses the existing machinery — no new infra, no new tool
  surface.** No Qdrant, no docker sidecar, no socket relay, no embedder;
  just read a file at boot and hand the agent the `Edit`/`Write` it
  already has. For one machine's facts — a small, bounded set — the
  whole thing fits in the prompt and needs no retrieval tier at all.
  This is the line-count and audit-first ethos applied to memory.
- **It makes pollution *visible* instead of trying to prevent it
  invisibly.** mem0's safety rested on "capture user-role content only"
  — a structural filter that leaks exactly when the user paraphrases
  untrusted content into their own turn. `MACHINE.md`'s safety is
  **visible + confirmed + reversible**: a poisoned fact can't land
  silently, because the write is a plain-text diff routed through the
  confirmer (invariant 2) — "agent wants to append: *backup server is
  `evil.example`*" surfaces *before* it lands, and the user can read
  the whole memory at will.

Prior art: this is the `CLAUDE.md` / `AGENTS.md` convention (opencode,
PI, Claude Code), and the [federation note](assistant.md) already
gestured at it ("a `@team` agent nudges `AGENTS.md` — shared ⇒
human-gated write").

### The pollution risk, now mitigated rather than deferred

Reading untrusted local content (logs, `~/Downloads`, cloned repos,
PDFs) is this agent's *core job*, so an injection in a read file can try
to **write a poisoned fact into durable memory** — the write-time sink.
A bad fact persists across sessions and steers later advice, which is
worse than a one-shot injection. The `MACHINE.md` design doesn't make
the sink vanish; it downgrades it from *silent durable poison* to *a
confirmed, auditable, reversible one-line diff*. The residuals to keep
in view:

- **A fact in `MACHINE.md` is in the *system prompt* — instructions-
  adjacent.** That's higher-privilege than mem0's recall-as-`:system`
  mid-conversation, so a poisoned fact there has more steering power.
  The counterweights: it's the user's own trusted file (same trust model
  as `CLAUDE.md`) and every write is confirmed — but it raises the
  stakes of a rubber-stamped edit.
- **Confirmation fatigue, again.** The defense is only as strong as the
  user actually reading the memory diff. Memory edits should be *rare*
  and the diff *small* (unlike a sprawling bash command), so this is far
  more reviewable than the bash-confirm case — but it rests on the same
  human attention.
- **No-egress still contains the blast radius.** Even a poisoned fact
  can't be exfiltrated; worst case is bad advice to the user, not data
  leaving the machine.

### Size guard

A markdown file is the right tool *because* one machine's fact set is
small and bounded; it is explicitly **not** a general large-scale
memory. To keep it from silently bloating the prompt, a simple size
check — mirroring how the Claude CLI nudges an oversized `CLAUDE.md`
(~40k) to be trimmed: **if `MACHINE.md` grows past ~10k, log a
warning** that it's time to trim. No hard cap, no auto-eviction — just a
visible nudge. If a host ever genuinely needs more than that, the
bounded-file model has been outgrown and semantic memory (below) is the
conversation to reopen.

## Placement: a new `pikuri-os` gem (not `pikuri-assistant`)

The instinct to reuse `pikuri-assistant` should be resisted — it's the
wrong home, for two reasons:

- **Opposite posture.** `pikuri-assistant` is the egress-capable,
  MCP-wired, mem0 + vectordb assistant (ch7). This agent is the inverse:
  no egress, no MCP, no mem0 (it uses `MACHINE.md`), no vectordb. Sharing
  a gem drags those deps into a binary that must *not* wire them, bloating
  the audit surface of an agent whose whole pitch is "small, no-egress,
  auditable." (Note: *not* because `pikuri-assistant` lacks library code —
  its empty `lib/` is a temporary RubyGems-name placeholder that will fill
  in; the objection is the clashing posture, not the empty gem.)
- **Convention.** Each distinct agent *shape* is its own capability gem +
  demo bin (`pikuri-code`, `pikuri-corpus`, `pikuri-memory`,
  `pikuri-assistant`). This is a distinct shape.

On the name specifically: every pikuri gem is named for its capability
*domain* and puts the assistant in `bin/` — `pikuri-vectordb` →
`bin/pikuri-corpus`, `pikuri-code` → `bin/pikuri-code`, `pikuri-memory` →
`bin/pikuri-memory`, `pikuri-mcp` → `bin/pikuri-openlibrary`. So
`pikuri-os` (the util layer) + `bin/pikuri-os-assistant` (the assistant)
is the *consistent* choice; `pikuri-os-helper` would be the only gem with
a `-helper` suffix — the odd one out. "It sounds like a pile of OS utils"
is correct and fine: the gem **is** the utils; the assistant-ness lives
in the bin, exactly as vectordb's does in `bin/pikuri-corpus`.

So: **a new `pikuri-os` gem**, depending on `pikuri-core` +
`pikuri-workspace` + `pikuri-code` (and deliberately *not* mcp / memory /
vectordb). It holds the OS-integration surface and the demo binary:

- `Os::LocalSearch` — the localsearch content-search wrap tool
  (§"File search").
- The `MACHINE.md` resident memory — boot-append + edit target
  (§"Memory").
- Boot grounding — `inxi -b` + primitives (§"How the LLM learns about
  this machine").
- `bin/pikuri-os-assistant` + its prompt.

The two cross-cutting pieces land in **`pikuri-code`**, the gem that
already owns the OS-touching primitives (`Bash`, `Sandbox`,
`ToolchainPaths`):

- `Bash::Sandbox::FullFsNoNet` — full-fs, net-isolated (§"How the egress
  leg is severed").
- The conservative auto-confirmer — a shell-aware `Confirmer` decorator
  (§"Confirmation fatigue").

## Future (deferred)

- **Semantic / large-scale memory.** Only if the bounded `MACHINE.md`
  proves too small. mem0-style auto-capture on an untrusted-ingest agent
  reopens the write-time-poisoning question in a form the markdown
  file's visible-and-confirmed model sidesteps — so it waits on the
  taint machinery the [federation note](assistant.md) and
  [`private-context-taint.md`](private-context-taint.md) are circling,
  rather than being rushed into this gem.
- **Internet access**, likely via a privilege-separated investigator
  sub-agent that can search the web but is structurally barred from the
  private filesystem context — at which point the full trifecta work
  (and possibly the federation) is back on the table. Until then, the
  severed network leg is what keeps this design simple and safe.
