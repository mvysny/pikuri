# Per-process temp store (`Paths.new_temp`)

Status: **shipped.** `Pikuri::Paths.new_temp` (fresh per-process scratch dir,
Finalizers-reaped, stale-swept at core load) split from `Paths.cache`
(shared + persistent). Trimmed per the graduation pipeline
([`../CLAUDE.md`](../CLAUDE.md)). What remains: the origin map, the rejected
alternative (its reasoning bounds the shipped design), and the open questions.

## Origin — the collision it fixed

Two concurrent `pikuri-thunderbird` processes shared a **fixed** snapshot path
(`~/.cache/pikuri/thunderbird/{mail,calendar}/`), so they clobbered each other's
SQLite copies, and one process's clean-exit `rm_rf` (a `Snapshot` Finalizer)
deleted the copy the other was mid-query on. Root cause was **discoverability**:
`Paths` was invisible, so the implementer reimplemented `XDG_CACHE_HOME` inline
and landed on a shared, persistent path without meeting the per-process concept.

Where the substance now lives:

- **The primitive + its whole why** (in-home/not-`/tmp` for reflink + the
  sandbox `/tmp`-bind, factory-not-accessor, the reap/sweep contract) →
  {Pikuri::Paths.new_temp} / {Pikuri::Paths.sweep_stale_temps!} yardoc.
- **The invariant** ("cache & temp paths go through `Paths`"; `cache`
  shared+persistent vs. `new_temp` per-process+ephemeral) + the
  `ENV['XDG_CACHE_HOME']` grep tripwire → CLAUDE.md *Conventions*.
- **The shape lifted** — `Filesystem.mint_internal_temp` /
  `sweep_stale_internal_temps!` were deleted; `Filesystem#internal_temp` now
  memoizes `Paths.new_temp`, and the stale sweep moved from *workspace* gem load
  to *core* load (so every binary sweeps, generic `temp-*` prefix).

## Rejected — `Paths.cache(session: :shared | :current)`

A required kwarg *forcing* the shared-vs-scratch decision at the signature (nice
discoverability, pikuri-shaped like `StepLimit.new(on_exhausted:)`). **Killed**
because the enum is secretly a 2×2 matrix — *shared-vs-private* ×
*persistent-vs-nuked* — crammed onto one axis: `:shared` implies persistent,
`:current` implies nuked, and there is *no cell for a persistent per-process
session*. The moment that cell is wanted the enum breaks. Two named methods with
distinct semantics don't share an axis, so a future persistent-session need
becomes a *third named method*, not a broken enum value. (It also invented an
on-disk `sessions/<id>/…` tree the two-method design never needed.)

## Open questions

- **Stale-sweep liveness (pre-existing, inherited not created).** The sweep is
  mtime-cutoff based (`Paths::TEMP_STALE_SECONDS`, 7 days). A process outliving
  the cutoff whose temp-dir mtime doesn't get bumped could have a *live* dir
  reaped by a newly-starting process's core-load sweep. Latent in the old
  workspace design too; a pidfile + `Process.kill(0, pid)` liveness probe would
  fix it but is PID-recycle-fragile. Deferred — revisit if it actually bites.
- **Persistent per-process sessions:** explicitly **deferred, not built.** If a
  need appears (scratch that survives a process's own restart yet stays
  private), it becomes a *third* named `Paths` method — the two-method split
  leaves room without reopening the rejected enum.

## Related

- [`thunderbird.md`](thunderbird.md) — where the collision surfaced; Q11
  (concurrency) covered the *live-DB* race, not this *snapshot-destination* race
  between two pikuri processes.
- The *Finalizers / teardown seam* (CLAUDE.md) — `new_temp` registers one
  block-form reap per mint at its ownership boundary; no second `at_exit`.
