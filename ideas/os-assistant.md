# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os-assistant`
(built; the empirical question of local-model fit, below, is what's
left). The design brainstormed in this note is now implemented and
documented — so this note keeps only the *origin map*, the questions
still open to validation, and the explicitly deferred work. For the
shipped design and its rationale, read:

- **Guide [chapter 7](../docs/guide/07-os-assistant.md)** — the
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

## Open questions (empirical — settle by using it)

- **Does a 35B-A3B model know Linux deeply enough?** Target model:
  `unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M` — MoE, ~3 B active params per
  token. Factual recall scales with *total* params (35 B — ample for
  FHS / man pages / apt), but multi-step *reasoning* depth scales with
  the ~3 B active budget, so deep causal diagnosis ("service failed →
  log says Y → therefore Z") may be shallow. The design hedges by
  construction — the agent iterates with tools rather than one-shotting,
  and verifies recall by *reading* (a man-page `read` beats a remembered
  flag) — but whether that's enough is a "try it" question, not settled.
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
- **Session-sticky grants** — "always allow `journalctl` this session,"
  the simple-invocation form only (Claude Code's shape: deterministic
  rules + user-granted session approvals, no LLM in the yes/no).
- **Batching** — present several queued commands as one prompt.
- **AI translation aid** — optional, never a verdict, always beside the
  raw command.

**Larger pieces:**

- **Semantic / large-scale memory.** Only if the bounded `MACHINE.md`
  proves too small. mem0-style auto-capture on an untrusted-ingest agent
  reopens the write-time-poisoning question that `MACHINE.md`'s
  visible-and-confirmed model sidesteps — so it waits on the taint
  machinery [`assistant.md`](assistant.md) and
  [`private-context-taint.md`](private-context-taint.md) are circling.
- **Internet access** — now guide **chapter 7, Part 2** ("the third leg
  returns"). **Shipped** behind the binary's `--with-internet` flag
  (default off): web access is quarantined in the bundled `RESEARCHER`
  sub-agent — it holds `web_search`/`web_scrape`/`fetch` (wired
  `add_sub_agent_tool`, so the parent LLM never sees them) but **no
  filesystem**, and is reached via the `agent` tool. The parent keeps
  **zero direct egress**; each delegation's task prompt is confirmed
  before dispatch (the human authors what leaves the machine), and the
  researcher — having no private data — can at worst leak that approved
  task plus the public pages it read. Bash stays kernel-severed
  regardless (a separate network boundary). Still open: the **editable**
  task prompt (the pure author seat, vs today's approve/reject of a shown
  task) and a **reject-reason** steering channel — both deferred to their
  own session, tracked in [`more-confirmers.md`](more-confirmers.md). The
  guide walkthrough (the researcher isolation, the approve-the-task gate,
  the two independent network boundaries) is chapter 7, Part 2.
- **GUI-config *application*, app launching, package *installation*.**
  The agent advises (prints the exact `gsettings` / `apt` command) but
  doesn't run these: installs need root + egress (barred by the severed
  network anyway), and the rest are post-v1.
- **Local offline docs** (Ubuntu help, man pages) as a `pikuri-vectordb`
  corpus, if recall quality ever justifies it.
