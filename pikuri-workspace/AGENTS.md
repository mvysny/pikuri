# pikuri-workspace — AGENTS.md

The filesystem and confirmation seams, the file tools built on them, and the
`ReadOnly` gate. Owns `Workspace` / `Filesystem` / `Confirmer`, three seams *consumed* by other gems
(`Bash`, `agent` and `web_search` take a `Confirmer`; `Bash` takes the bare `Filesystem`; the LSP tool renders
walked paths) — their `AGENTS.md` point here and never restate.

## Invariants

- **Workspace seam.** File tools take a `Workspace::Workspace` composite, `Bash` the bare `Workspace::Filesystem`; every path routes through `#resolve_for_read` / `#resolve_for_write`. The composite enforces the read-before-edit gate, file tools run in-process as the real user (so `File.writable?` is exact and backs the confirm-writable-writes posture), and every confirmed write routes through {Pikuri::Workspace::WriteGate}. See {Pikuri::Workspace::Workspace}, {Pikuri::Workspace::Filesystem}, {Pikuri::Workspace::Extension} (the depth-1 boot snapshot).
- **Denylist seam (walked vs. supplied paths).** `resolve_for_*` gates a path the *model* supplied; a path a tool **walked** to must pass `Filesystem#denied?` before it is reported — that check is the fail-closed guarantee, `rg` pruning is an optimization. Roster: `Listing`, `Search::Glob`, `Search::Grep` (via `Utils.reject_denied_lines`), and `Lsp::Sources` / `Lsp::Renderer` in `pikuri-lsp`. Without it a denied `.env` leaks its name, and for grep a line of its content, into the transcript — the root's **Privacy first**. One of the five `rake tripwires` checks watches it. See `D_walked_path_denylist`, {Pikuri::Workspace::Filesystem#denied?}.
- **Confirmer seam.** State-mutating or network-dispatching tools take a `Workspace::Confirmer` and route every prompt through `#ask(request:)` → `Approved` / `Rejected` / `Redirected`; a `Rejected` carries no text, so every typed word is a `Redirected` (`D_bare_rejected`). Presentation belongs to the confirmer; tool code never touches `gets` / `puts` / `$stdin` / `$stdout`, and defanging is the shared `Pikuri::Sanitizer`. See {Pikuri::Workspace::Confirmer}, {Pikuri::Sanitizer}.

Maintenance: the root `AGENTS.md`'s rules.
