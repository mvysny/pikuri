# OS/Linux Assistant

Status: **shipped** as the `pikuri-os` gem + `bin/pikuri-os`; the design
lives in the book's OS-assistant chapter, the yardoc, and
[`../../pikuri-os/design/architecture.md`](../../pikuri-os/design/architecture.md).
This note keeps only the residue not yet graduated.

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
  is book [the first-conversation chapter](../../book/chat.md) §"Why a mixture-of-experts model" +
  §"Picking a different model". Don't restate it here.)

## Deferred / not yet built

- **GUI-config *application*.** The agent advises (prints the exact
  `gsettings` command) but doesn't apply it; post-v1. Reading current
  values still works under the session-IPC mask (`dconf` reads the
  file), so this stays a pure UX question.

## File confirmations: allowlist-safe auto-allow

`pikuri-os` confirms **every** writable `write`/`edit` with a diff
(`confirm_all_writes`), because writes are rare for a diagnosis agent, so
there's little fatigue to cut and no "sensitive path" list to maintain —
see the book's OS-assistant chapter and {Pikuri::Workspace::WriteGate}. The considered-and-punted
generalization: an **allowlist of auto-allowed (safe) write paths**,
deny-by-default = confirm. It's the inverse of a sensitive-path denylist
(and the winning side of the enumeration game, like `PASSIVE_BINARIES`),
for a *hypothetical frequent-writing full-disk agent* that would want some
writes — a scratch dir, `/tmp` — to skip the prompt. No such agent ships,
so building the allowlist plumbing now would be speculative. Revisit when
one exists; `confirm_all_writes` is `[]`-safe-paths as a special case.
