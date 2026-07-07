# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os-assistant`
(built; the local-model-fit question is provisionally settled — initial
testing confirms the recommended 35B-A3B model can diagnose a real
issue, see below — so what's left is the deferred work list). The design
brainstormed in this note is now implemented and documented — so this
note keeps only the *origin map*, the questions still open to
validation, and the explicitly deferred work. For the shipped design and
its rationale, read:

- **Guide [chapter 7](../book/07-os-assistant.md)** — the
  narrative walkthrough. Part 1: the severed-network sandbox, the
  read-before-edit fence, confirmed mutations, the read-only
  auto-confirmer, the file-index pair, `MACHINE.md`, boot grounding,
  and why egress is the trifecta leg this agent removes. Part 2 ("the
  third leg returns"): reattaching the network via the quarantined
  `RESEARCHER` sub-agent + the confirmed task prompt + the two
  independent network boundaries.
- **YARD headers** — {Pikuri::Os::Extension} (one-call wiring +
  confirmation policy), {Pikuri::Os::FileindexSearch} /
  {Pikuri::Os::FileindexRead} / {Pikuri::Os::LocalSearch} (the
  search → read-full pair), {Pikuri::Os::MachineMemory} (`MACHINE.md`),
  {Pikuri::Os::SystemInfo} (grounding),
  {Pikuri::Code::Bash::Sandbox::FullFsNoNet} (the kernel-severed
  network) and {Pikuri::Code::Bash::ReadOnlyAutoConfirmer} +
  `Pikuri::Code::Bash::GIT_HARDENING` (the auto-confirmer + git arm).
- **[`../CLAUDE.md`](../CLAUDE.md)** — the `pikuri-os` gem entry and the
  Sandbox / Confirmer / Workspace seam invariants.

## Related

- [`assistant.md`](assistant.md) — the federation. This agent is the
  federation's `@private`/`@os` member, shipped standalone: one agent,
  no inter-agent routing. If the federation lands, it becomes a sibling.
- [`trifecta-detector.md`](trifecta-detector.md) — the three legs. This
  design breaks the trifecta by **enforced removal of the egress leg**,
  not by trusting its inputs.

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

## Open questions (empirical — settle by using it)

- **Does keyword recall suffice, or is semantic search needed?**
  `fileindex_search` is only as good as `localsearch`'s keyword match; a
  fuzzy ask ("the doc about our refund policy") can miss when the words
  don't literally appear. Revisit semantic recall (below) only if real
  usage shows keyword recall failing — and even then for that specific
  gap, not a wholesale home re-index. `pikuri-vectordb` is **not** the
  discovery upgrade path: pointed at `$HOME` it would just re-index the
  corpus `localsearch` already holds.

## Deferred / not yet built

**Confirmation-fatigue work beyond the shipped read-only auto-confirmer**
(the sequencer/pipe composition and the `git` arm are shipped — see
{Pikuri::Code::Bash::ReadOnlyAutoConfirmer}). The governing invariant
for everything below: **AI may *translate* a command ("this deletes
`~/tmp` recursively"), but code and the human *decide* — never an AI
✓/⚠ verdict.** An AI approver is talked into "yes" by the same laundered
content that fooled the agent; a usually-silent AI warner is worse, as
it trains the user to read "no warning" as "safe" and goes quiet exactly
when an injection is crafted to look benign.

- **`Write`/`Edit` path-zone auto-allow + diff render.** Reliable
  *because* the inputs are structured (known path + bytes): auto-allow
  new files / edits to already-read files in non-sensitive zones, always
  confirm sensitive targets (`~/.ssh`, dotfiles, `/etc`) and show the
  diff.
- **Subcommand-aware read rules** for mutating binaries still delegated
  whole — `systemctl status`, plain `journalctl`. The hard part, as with
  `git`, is that a "read" verb may still execute config-directed code.
- **Session-sticky / always-allow grants** — the runtime-populated
  companion to the static allowlist ("the human vouches for `pytest`
  this session"). Design space + why it's deferred moved to its own
  note: [`bash-confirmer.md`](bash-confirmer.md).
- **Batching** — present several queued commands as one prompt.
- **AI translation aid** — optional, never a verdict, always beside the
  raw command.

**Larger pieces:**

- **GUI-config *application*, app launching, package *installation*.**
  The agent advises (prints the exact `gsettings` / `apt` command) but
  doesn't run these: installs need root + egress (barred by the severed
  network anyway), and the rest are post-v1.
- **Local offline docs** (Ubuntu help, man pages) as a `pikuri-vectordb`
  corpus, if recall quality ever justifies it.
