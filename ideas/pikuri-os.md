# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os`
(built; the local-model-fit question is provisionally settled — initial
testing confirms the recommended 35B-A3B model can diagnose a real
issue, see below — so what's left is the deferred work list). The design
brainstormed in this note is now implemented and documented — so this
note keeps only the *origin map*, the questions still open to
validation, and the explicitly deferred work. For the shipped design and
its rationale, read:

- **Guide [chapter 7](../book/07-os-assistant.md)** — the
  narrative walkthrough. Part 1: the severed-network sandbox, the
  read-before-edit fence, confirmed mutations, the passive-command
  detector, the file-index pair, `MACHINE.md`, boot grounding,
  and why egress is the trifecta leg this agent removes. Part 2 ("the
  third leg returns"): reattaching the network via the quarantined
  `RESEARCHER` sub-agent + the confirmed task prompt + the two
  independent network boundaries.
- **YARD headers** — {Pikuri::Os::Extension} (one-call wiring +
  confirmation policy), {Pikuri::Os::FileindexSearch} /
  {Pikuri::Os::FileindexRead} / {Pikuri::Os::LocalSearch} /
  {Pikuri::Os::Recoll} (the search → read-full pair over a swappable
  file-index backend), {Pikuri::Os::MachineMemory} (`MACHINE.md`),
  {Pikuri::Os::SystemInfo} (grounding),
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} (the kernel-severed
  network) and {Pikuri::Code::Bash::PassiveCommandDetector} +
  `Pikuri::Code::Bash::GIT_HARDENING` (the passive detector + git arm).
- **[`../CLAUDE.md`](../CLAUDE.md)** — the `pikuri-os` gem entry and the
  Sandbox / Confirmer / Workspace seam invariants.
- **[`../pikuri-os/DESIGN.md`](../pikuri-os/DESIGN.md)** — the file-index
  engine survey (`localsearch` vs `recoll`, measured) and the
  keyword-recall-vs-semantic decision.

## Related

- [`assistant.md`](assistant.md) — the federation. This agent is the
  federation's `@private`/`@os` member, shipped standalone: one agent,
  no inter-agent routing. If the federation lands, it becomes a sibling.
- [`trifecta-detector.md`](trifecta-detector.md) — the three legs. This
  design breaks the trifecta by **enforced removal of the egress leg**,
  not by trusting its inputs.
- **`bin/pikuri-computer`** — app integrations (thunderbird, …) compose *on
  top* of pikuri-os as a **demo binary** (thunderbird as a dev-dep; not a gem,
  not a merge); pikuri-os stays substrate-only and keeps its no-egress posture
  unchanged. Landed + live-verified — see CLAUDE.md's pikuri-os entry + the
  "grow by bounded gems" convention, and book ch7 Part 3.

## Settled by initial testing

- **A 35B-A3B model knows Linux deeply enough — the recommended
  default.** Target model: `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` — MoE,
  ~3 B active params per token. Factual recall scales with *total*
  params (35 B — ample for FHS / man pages / apt); the open worry was
  that multi-step *reasoning* depth scales with the ~3 B active budget,
  so deep causal diagnosis ("service failed → log says Y → therefore Z")
  might be shallow. Initial testing confirms it isn't: the model carries
  a real diagnosis end to end, not just flag recall. The design hedge
  holds up in practice — the agent iterates with tools rather than
  one-shotting, and verifies recall by *reading* (a man-page `read`
  beats a remembered flag). So this stays the **recommended** model; if
  further experience shows the ~3 B active reasoning budget falling short
  on deeper causal chains, we'll revisit.

  **Why MoE, not a bigger dense model:** a dense model needs its full
  parameter count resident in fast memory *and* run through the matmul
  on every token, so matching a MoE's quality densely means the whole
  thing must fit in VRAM on a strong discrete GPU — expensive, and
  against the no-cloud, no-strong-GPU-required posture this gem targets.
  A MoE activates only ~3-4 B params worth of experts per token, so the
  *inactive* experts can sit in ordinary system RAM while only the
  active path needs to be fast — the iGPU/CPU-RAM machine this project
  is shooting for. So "bigger total params, same 3-4 B active" is the
  only upgrade axis that keeps that target machine viable; a bigger
  dense model would instead demand a stronger GPU.

  **Bigger-box escalation, if not laptop-bound:** the ~3 B active-param
  budget is an inference-cost floor, not a total-param ceiling — a user
  running from an LLM-dedicated machine (still iGPU/CPU-RAM-class, just
  more RAM) can trade up in *total* params while keeping the same active
  budget and roughly the same tokens/sec. `Qwen/Qwen3-Coder-Next`
  (80B-A3B, ~3 B active, Feb 2026) is the candidate: same inference-cost
  class as the 35B default, 80B total params, and — unlike the
  general-purpose 35B model — agentically trained on long-horizon tool
  use and *recovery from execution failures*, which speaks more directly
  to the causal-diagnosis worry above. Needs ~50GB combined VRAM+RAM at
  Q4_K_M — comfortably a CPU-RAM box (e.g. 64GB system RAM) with little
  or no discrete GPU, not a jump to data-center hardware — so it's
  explicitly the dedicated-machine tier, not the laptop default. Also
  worth an empirical try at the *same* cost tier as the 35B default:
  `GLM-4.7-Flash` (30B-A3B) — same ~3 B active budget, benchmarks lower
  on general reasoning but ahead on agentic tool-use (τ²-Bench 79.5% vs.
  Qwen3.6-35B-A3B), which is most of what this assistant actually does.
  Neither swap is validated here — both ride the same "settle by using
  it" caveat, though the 35B default itself is now provisionally
  confirmed (above).

- **The permission-wall hand-off needs no explicit read-vs-mutate
  guidance — an honest `EACCES` is enough.** Two things had to be true
  together, and testing (2026-07-18, "Is my SSD healthy?") confirmed
  both. (1) `FullFsNoNet` must bind the *real* `/dev`: the earlier
  synthetic `--dev /dev` hid block-device nodes, so `smartctl` failed
  `ENOENT` ("No such device") while `lsblk`/`/sys` showed a healthy
  disk — an incoherent machine that made the model retry-loop instead
  of escalate (fixed; the why-not note lives in
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet}'s yardoc). (2) *Given* that
  honest `EACCES`, the `os-assistant.txt` prompt does **not** need the
  read-vs-mutate sub-bullets that once spelled out the escalation
  strategy: the model ran the probe, read "Permission denied",
  recognized root was required, and handed over the exact
  `sudo nvme smart-log` / `sudo smartctl -a` commands with an
  explanation and a paste-back ask — unprompted, and even reaching for
  the NVMe-specific tool first. So the sub-bullets were trimmed (commit
  `f917226`); **don't re-add them** thinking they're load-bearing.
  *Caveat still open:* the model escalated *straight* to `sudo` without
  first gathering the partial non-root picture. Fine when root is
  genuinely required (SMART data is), but on a case with real partial
  value (a root-only log where `/sys` gives half the story) the leaner
  prompt may leave that on the table — watch for it before calling the
  "gather partial first" nudge fully unnecessary.

## File search: keyword recall vs semantic — settled, graduated

The three-causes analysis of *why* a keyword search whiffs (content not
indexed, phrasing miss, genuine semantic gap) and the measured
`localsearch` vs `recoll` engine survey have **graduated** to
[`../pikuri-os/DESIGN.md`](../pikuri-os/DESIGN.md) (§"File search" and
§"Backend engine"). Settled outcome: cause (2) is the primary answer and
needs no new infra (agent reformulation + the wired grep fallback);
cause (1)'s only lever is `recoll`, a thin slice since grep already
covers its wins; cause (3) (embeddings / `pikuri-vectordb`) stays
declined against the offline, small-enough-to-audit posture.

## Deferred / not yet built

**Confirmation-fatigue work beyond the shipped passive-command detector**
(the sequencer/pipe composition and the `git` arm are shipped — see
{Pikuri::Code::Bash::PassiveCommandDetector}). The governing invariant
for everything below: **AI may *translate* a command ("this deletes
`~/tmp` recursively"), but code and the human *decide* — never an AI
✓/⚠ verdict.** An AI approver is talked into "yes" by the same laundered
content that fooled the agent; a usually-silent AI warner is worse, as
it trains the user to read "no warning" as "safe" and goes quiet exactly
when an injection is crafted to look benign.

- **`Write`/`Edit` full read + confirmed writes** — **shipped**: full
  read to match bash (`denylist: []`), and every *writable* write
  confirmed with a diff, unwritable writes short-circuited to "sudo it
  yourself" (`confirm_all_writes`). Narrative in the guide's ch7
  (Workspace + Confirmer seam sections); mechanism in
  {Pikuri::Workspace::WriteGate}. Deferred residue (allowlist-safe
  auto-allow) in §"File confirmations: allowlist-safe auto-allow" below.
- **The rest of the confirmer-gate fatigue work** — session-sticky
  grants, subcommand-aware read rules, batching, and the AI translation
  aid — is collected in [`bash-confirmer.md`](bash-confirmer.md).

**A `Recoll` file-index backend** — **shipped** as
{Pikuri::Os::Recoll}, a stateless module parallel to
{Pikuri::Os::LocalSearch} behind the same duck type;
{Pikuri::Os::Extension} wires the first `available?` backend
(`localsearch`, then `recoll`). Its shape, selection order, and the
payoff bound have graduated to the yardoc +
[`../pikuri-os/DESIGN.md`](../pikuri-os/DESIGN.md) (§"Backend engine").

## File confirmations: allowlist-safe auto-allow

`pikuri-os` confirms **every** writable `write`/`edit` with a diff
(`confirm_all_writes`), because writes are rare for a diagnosis agent, so
there's little fatigue to cut and no "sensitive path" list to maintain —
see book ch7 and {Pikuri::Workspace::WriteGate}. The considered-and-punted
generalization: an **allowlist of auto-allowed (safe) write paths**,
deny-by-default = confirm. It's the inverse of a sensitive-path denylist
(and the winning side of the enumeration game, like `PASSIVE_BINARIES`),
for a *hypothetical frequent-writing full-disk agent* that would want some
writes — a scratch dir, `/tmp` — to skip the prompt. No such agent ships,
so building the allowlist plumbing now would be speculative. Revisit when
one exists; `confirm_all_writes` is `[]`-safe-paths as a special case.

**Larger pieces:**

- **GUI-config *application*, app launching, package *installation*.**
  The agent advises (prints the exact `gsettings` / `apt` command) but
  doesn't run these: installs need root + egress (barred by the severed
  network anyway), and the rest are post-v1.
