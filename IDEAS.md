# IDEAS.md

Things pikuri considered, scoped, and deliberately deferred — recorded
here so a future contributor doesn't read the absence as oversight.
Promote into a real plan when the friction shows up.

Related but different: `COMPARISON.md` "Ideas to borrow" is the
externally-sourced version — "opencode/pi do X, should we?" This file
is the internally-sourced version — "we considered X for pikuri and
punted, here's why."

## Coding-agent deferrals

Carried over from the v1 plan once `bin/pikuri-code` shipped. Each was
in scope of the design exercise, considered, and left out on purpose.

- **Permission system.** opencode's three-action `allow` / `deny` /
  `ask` glob rules. v1 ships with two coarse modes (interactive
  `Tool::Confirmer::TERMINAL` on `Write` / `Bash`; `--yolo` swaps in
  `AUTO_APPROVE`). Revisit once `bin/pikuri-code` has lived a while
  and we know where the friction is. Where things are headed:
  yolo-in-docker, or ClaudeCode's agentic review of the command + automatic approval/denial.
- **Image / PDF in `Tool::Read`.** Read refuses binaries today
  (`lib/tool/read.rb` rejects on a null-byte heuristic). Multimodal
  Read needs vision-capable models and the streaming/encoding path
  ruby_llm exposes but we haven't wired.
- **LSP tool.** opencode wires an LSP client for hover / definition /
  diagnostics. Big-ticket feature; deferred until there's a concrete
  use case beyond "opencode has one."
- **TODO / plan tools.** opencode and Claude Code both maintain a
  per-session todo list the model can edit. Useful, but it's
  session-state machinery pikuri doesn't have today — same blocker as
  resumable sub-agents below.
- **Streaming output from bash.** `Tool::Bash` returns a single
  observation `String`. Live process output is meant to stay on the
  listener stream once we add a TUI; meanwhile callers bound wall time
  with coreutils' `timeout`.
- **Session persistence / resumable sub-agents.** opencode's `task`
  tool persists sub-sessions; `Tool::SubAgent` doesn't. Worth doing
  the day we have any other reason to introduce a session store
  (todo/plan tools being the obvious second customer).
- **Multi-file / multi-hunk Edit.** `Tool::Edit` takes one
  `old_string` → `new_string` per call. opencode bundles batch edits.
  Wait until the cost of separate calls becomes obvious in practice.

## Workspace v2

Plans recorded in `lib/tool/workspace.rb`'s "Future extensions" RDoc
section, summarised here so they show up in a doc-only sweep:

- **Multi-root workspace.** A read-set wider than the write-set —
  e.g. `~/.claude/skills` readable, project CWD writable. The
  `Workspace` abstract base already splits `resolve_for_read` /
  `resolve_for_write` to make this seamless.
- **`Tool::Workspace::ALLOW_ALL`.** Unrestricted reads + writes,
  intended for Docker / dev-container mode where the whole sandbox is
  the workspace. Pairs naturally with `--yolo`.
