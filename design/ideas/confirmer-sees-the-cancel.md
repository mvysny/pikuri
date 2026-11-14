# A confirmer parked on a human doesn't see the turn's cancel

Status: **found moving pikuri-tui onto pikuri-workshop's `pikuri-conversations` (2026-11-14);
not scheduled.**

## What happens

`Workspace::Confirmer#ask(request:)` blocks the tool's thread until a human answers. Nothing
hands it the turn's `Agent::Control::Cancellable`, so a cancel — `Cancellable#cancel!`, which is
what `Conversation#cancel`, `close(force: true)` and `Conversations#shutdown` all do — never
reaches a parked `#ask`: the flag flips, and the turn waits on the human anyway. `Terminal` gets
away with it (Ctrl+C there is a `SIGINT` in the `gets`), but an interactive host confirmer can't.

pikuri-tui's `Code::TranscriptConfirmer` parks on a `Queue` and exposes `cancel_pending!`, which
makes the parked `#ask` raise `Cancellable::Cancelled`; the host must call it next to *every*
cancel it issues — Ctrl+C, and its `close` before `shutdown`, or the shutdown waits out its
timeout. A cancel from anywhere else (a SIGTERM handler calling `shutdown`, a webui's second
tab) misses it. Each host re-derives that rule; pikuri-tui keeps it as an `AGENTS.md` invariant.

## Options

- **(a) Hand the token to `#ask`**: `ask(request:, cancellable:)`, the extension passing the
  agent's own (`c.agent.cancellable`). A confirmer waits with it — `Queue#pop(timeout:)` in a
  loop with `cancellable.check!`, the same polling `Cancellable#sleep` does and for the same
  reason (`cancel!` stays SIGINT-safe). Breaking for third-party confirmers; a default keyword
  of `Cancellable::NEVER` softens it.
- **(b) `Cancellable#on_cancel { … }`**: a callback the confirmer registers while parked. Not
  SIGINT-safe if the callback takes a lock, which most wake-ups do.

(a) looks right: it is the `Cancellable#sleep` contract applied to the one other place a tool
waits.
