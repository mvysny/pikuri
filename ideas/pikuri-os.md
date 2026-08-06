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
  default** (`unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M`). Factual recall
  scales with *total* params (35 B — ample for FHS / man pages / apt);
  the open worry was that multi-step *reasoning* depth scales with the
  ~3 B active budget, so deep causal diagnosis ("service failed → log
  says Y → therefore Z") might be shallow. Initial testing confirms it
  isn't: the model carries a real diagnosis end to end, not just flag
  recall. The design hedge holds up too — the agent iterates with tools
  rather than one-shotting, and verifies recall by *reading* (a man-page
  `read` beats a remembered flag). Revisit if deeper causal chains show
  the active budget falling short. (The model *shape* argument — why MoE
  and not a bigger dense model, the same-tier and dedicated-box swaps —
  is book [ch1](../book/01-chat.md) §"Why a mixture-of-experts model" +
  §"Picking a different model". Don't restate it here.)

- **The permission-wall hand-off needs no explicit read-vs-mutate
  guidance — an honest `EACCES` is enough.** Settled; validated
  2026-07-18. See [`DECISIONS.md`](../DECISIONS.md)
  `D-permission-wall-handoff`, which carries the trimmed sub-bullets
  (**don't re-add them**), the real-`/dev` precondition that makes it
  work, and the one caveat still open (the model escalates straight to
  `sudo` without gathering the partial non-root picture first).

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

- **Confirmation-fatigue work beyond the shipped passive-command
  detector** — collected in [`bash-confirmer.md`](bash-confirmer.md)
  (session-sticky grants, subcommand-aware read rules, batching, the AI
  translation aid), together with the governing invariant they all obey:
  **AI may *translate* a command, but code and the human *decide* —
  never an AI ✓/⚠ verdict.** Read it there; don't restate it here. The
  one *file*-shaped residue is §"File confirmations: allowlist-safe
  auto-allow" below.
- **GUI-config *application*, app launching, package *installation*.**
  The agent advises (prints the exact `gsettings` / `apt` command) but
  doesn't run these: installs need root + egress (barred by the severed
  network anyway), and the rest are post-v1.

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
