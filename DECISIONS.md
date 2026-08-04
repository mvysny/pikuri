# DECISIONS.md

A living record of the design decisions behind pikuri — especially the
*roads not taken*. It exists because the graduation pipeline (see
[`CLAUDE.md`](CLAUDE.md)) had no home for one fact class: a rejected
alternative. Both candidate homes refuse it on their own stated terms —
yardoc is browsed standalone on rubydoc.info by someone at the API, who
gains nothing from an argument against a design that never shipped; and
CLAUDE.md is loaded into *every* session's context under a 40 KB cap, so
rationale there is paid for on every turn. This file is the lazy side of
that split: never context-loaded, read only when someone asks "why this
way?".

It is the *why-we-chose* record. It is not the *how-it-works* reference
(yardoc), the *why-the-concept* narrative (the book), the *what-you-must-
not-break* list (CLAUDE.md), a gem's architecture + threat model (per-gem
`DESIGN.md`), what other projects do (`COMPARISON.md`), or the shipped
defenses (`SECURITY.md`). An entry links out rather than restating.

**Boundaries** — the three that keep this from becoming a second copy of a
neighbor:

- **vs. per-gem `DESIGN.md`.** DESIGN.md describes the system *as it is*,
  for someone extending that gem. This file records *forks*, and is
  repo-root so it can hold the cross-gem ones DESIGN.md structurally
  can't. Carve-out: when a rejected alternative is gem-local *and*
  inseparable from that gem's threat model, leave the reasoning in the
  gem's DESIGN.md and make the entry here a one-line pointer. Never two
  half-answers.
- **vs. `COMPARISON.md`.** That file says what *others* do; this one
  records our choice against that option.
- **vs. `SECURITY.md`.** A shipped defense stays there. Only the fork
  ("rejected X because it widens the surface") comes here.

**Format.** One entry per decision. The ID is a slug, not a number: `D-`
plus a 1–4-word kebab hint at the subject (`D-per-process-temp`), so a
citation carries meaning on its own. The `(date)` on the heading is
*decided* provenance, not a log position — git owns the edit history, so
don't narrate how an entry used to read. Keep each entry tight: context,
the decision, the alternatives rejected and why, and the consequences a
future contributor would trip over. A decision is worth logging the moment
it's *made*; implementation can lag (the `Status:` line says which).

**No entry without a real fork.** If nothing was seriously considered and
rejected, it isn't a decision — it's how the thing works, and that's
yardoc. This is the guard against a diary.

**Never read wholesale.** `grep '^## D-' DECISIONS.md` is the index; there
is no ToC (same discipline as `ls ideas/`). Cite an entry by slug. Grep
tripwire: every `D-<slug>` referenced anywhere in the repo must exist as a
`^## D-` heading here.

**Entries are mutable — edit in place, don't append addendums.** Each entry
is the single coherent home for one *live* decision; keep it current as the
decision is refined or extended. Two things this does *not* license:

- **The roads-not-taken stay.** "We chose X, rejected Y because Z" is live
  content of the current decision, not stale history — never edit it away.
  It's the most valuable thing in the file.
- **A reversed *shipped* decision forks a tombstone, it is not
  overwritten.** When a design was tried, shipped, and then thrown away,
  leave the old entry as the scar, set its `Status:` to **Superseded by
  D-\<slug\>**, and write the replacement fresh. The line: *refined or
  extended* → edit in place; *reversed after shipping* → tombstone + new
  entry.

**Backfill is opportunistic.** Rejection rationale that already sits inline
in a yardoc or a `DESIGN.md` (the pre-2026-08-04 convention) stays put —
this file is the home going *forward*. Move an old one only when you're
already editing that doc and the inline rejection is crowding out the live
design.

---

## D-context-window-sources — The `/props` probe, never ruby_llm's model registry (2026-08-04)

**Status:** Accepted; the behaviour has always shipped this way
({Pikuri::Agent::ContextWindowDetector}). Logged 2026-08-04 when the
argument moved out of that class's yardoc.

**Context.** A context-window cap is only worth emitting if a host can *act*
on it — warn, compact, or switch models before
`RubyLLM::ContextLengthExceededError`. So the number has to be trustworthy
without a caveat attached.

**Decision.** Two sources only: llama.cpp's non-standard `/props` probe (the
server's *launched* `n_ctx`, i.e. the real window) and an explicit
{Pikuri::Agent::ChatTransport#context_window}. Anything else resolves to
`nil` — an honest "we don't know."

**Alternatives rejected.**

- **`RubyLLM::Model::Info#context_window`** (the obvious source, and free) —
  it's a static `models.json` lookup, so it returns `nil` for every
  `assume_exists` local id, `nil` for anything past the snapshot, and —
  worst — a **frozen** value for models it *does* know: a window bumped
  256k → 1M still reports the old number. A cap you must caveat defeats its
  only job, and a confidently-wrong number is worse than `nil`. Not
  consulted at all, rather than consulted as a last resort, because a
  fallback that lies is indistinguishable from one that works until it
  silently truncates.

**Consequences.** Non-llama.cpp servers get no cap unless the host passes
`context_window:` on the transport — deliberate, and why the detector's
failure path is a debug log rather than a raise.

---

## D-per-process-temp — Two named `Paths` methods, not `cache(session:)` (2026-07-14)

**Status:** Accepted; implemented 2026-07-14 (`Paths.new_temp` +
`Paths.sweep_stale_temps!`). Graduated from `ideas/session-scoped-store.md`,
now retired.

**Context.** Two concurrent `pikuri-thunderbird` processes shared a *fixed*
snapshot path (`~/.cache/pikuri/thunderbird/{mail,calendar}/`), so they
clobbered each other's SQLite copies — and one process's clean-exit `rm_rf`
(a `Snapshot` finalizer) deleted the copy the other was mid-query on. The
root cause was **discoverability**, not the path: `Paths` was invisible, so
the implementer re-derived `XDG_CACHE_HOME` inline and landed on a shared,
persistent directory without ever meeting the per-process concept. Any fix
had to make the shared-vs-private choice unmissable at the call site.

**Decision.** Split the concept into two *named* methods with distinct
semantics — `Paths.cache` (shared across all pikuri processes, persistent)
and `Paths.new_temp` (private to this process, ephemeral, finalizer-reaped,
stale-swept at core load). Per-symbol mechanics and their full why —
in-home rather than `/tmp`, factory rather than memoized accessor, the
reap/sweep contract — live in {Pikuri::Paths.new_temp} /
{Pikuri::Paths.sweep_stale_temps!}. The invariant ("cache & temp paths go
through `Paths`") plus its `ENV['XDG_CACHE_HOME']` grep tripwire live in
CLAUDE.md *Conventions*.

**Alternatives rejected.**

- **`Paths.cache(session: :shared | :current)`** — a required kwarg
  *forcing* the decision at the signature. Genuinely attractive: great
  discoverability, and pikuri-shaped like `StepLimit.new(on_exhausted:)`.
  **Killed** because the enum is secretly a 2×2 matrix — *shared-vs-private*
  × *persistent-vs-nuked* — crammed onto one axis: `:shared` implies
  persistent, `:current` implies nuked, and **there is no cell for a
  persistent per-process session**. The moment that cell is wanted, the enum
  breaks. Two named methods don't share an axis, so the same future need
  becomes a *third named method* instead of a broken enum value. It also
  invented an on-disk `sessions/<id>/…` tree the two-method design never
  needed.
- **Keeping the mint on `Workspace::Filesystem`** (`mint_internal_temp` /
  `sweep_stale_internal_temps!`) — rejected: the concept isn't
  workspace-shaped, and the stale sweep ran at *workspace* gem load, so a
  binary that wires no workspace never swept. Both were deleted;
  `Filesystem#internal_temp` now memoizes `Paths.new_temp`, and the sweep
  moved to *core* load with a generic `temp-*` prefix, so every binary
  sweeps.

**Consequences.**

- **A persistent per-process session is deliberately not built.** If the
  need appears (scratch that survives a process's own restart yet stays
  private), it is a *third* named `Paths` method — the two-method split
  leaves room without reopening the rejected enum.
- **Stale-sweep liveness is a known latent hazard** (pre-existing —
  inherited from the workspace design, not created here). The sweep is
  mtime-cutoff based (`Paths::TEMP_STALE_SECONDS`, 7 days), so a process
  outliving the cutoff whose temp-dir mtime never gets bumped could have a
  *live* dir reaped by a newly-starting process's core-load sweep. A pidfile
  + `Process.kill(0, pid)` liveness probe would fix it but is PID-recycle-
  fragile. Deferred — revisit if it actually bites.
- `new_temp` registers one block-form reap per mint at its ownership
  boundary, under the single `at_exit` of the *Finalizers / teardown seam* —
  no second `at_exit`.
- Thunderbird's `Extension` now takes `cache_dir` with `nil` meaning "mint a
  fresh per-process dir," which is what closed the original collision.

**Related.** [`ideas/thunderbird.md`](ideas/thunderbird.md) — where the
collision surfaced; its Q11 (concurrency) covered the *live-DB* race, not
this *snapshot-destination* race between two pikuri processes.
