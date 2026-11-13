# `DatabaseSnapshot` misses whatever sits in a WAL

Status: **a reader bug, not fixed.** Found by the testbed probe
([`thunderbird-testbed.md`](thunderbird-testbed.md), 2026-11-13): an event that the `ics` calendar
had just synced into `cache.sqlite` stayed invisible to `Calendar#search` until Thunderbird quit.
Live users hit it too: an event they just added may not show up.

## Why

`DatabaseSnapshot` copies only the main DB file and the callers open it with `?immutable=1`.
For a WAL store that gives a view as of the last checkpoint, and its yardoc assumes "Thunderbird
checkpoints aggressively". That holds for a busy DB but not for a handful of new rows. SQLite's
auto-checkpoint fires at 1000 WAL pages by default, so a small change can sit in `-wal` until
Thunderbird closes the DB.

It is worse than lag. `refresh` keys the generation on the header change counter (bytes 24–27).
In WAL mode SQLite doesn't promise to bump that counter per commit, only on a checkpoint.
So a WAL-only commit leaves `live == @generation`, `refresh` returns `false`, and pikuri keeps
serving the stale copy without knowing it. The `-journal` bracket doesn't help either: a WAL store
has no rollback journal.

## The fix (lean)

- **Copy `-wal` beside the main file**, if it exists. Thunderbird runs `locking_mode=EXCLUSIVE`,
  so there is no `-shm` to copy; SQLite rebuilds the WAL index from the WAL when it opens our copy.
- **Open the copy normally, not `immutable`**, so SQLite applies the WAL. The copy is ours, in a
  private dir, so a recovery write there touches nothing of Thunderbird's.
- **The generation becomes main counter + WAL salt (header bytes 16–23) + WAL size**, so a
  WAL-only commit moves it.
- **The bracket checks the same triple before and after.** A WAL frame copied mid-write fails its
  checksum, and SQLite's recovery stops at the last valid commit, so a torn tail gives a clean
  prefix of committed transactions. The unsafe case is a WAL *restart* between the two copies (new
  salt): the old main file plus new frames that assume the post-checkpoint main. The salt in the
  bracket catches it. Copy order: main then WAL, so a checkpoint in between leaves frames that
  are already in main, and re-applying them is idempotent.

## To check before building

- Which stores are WAL? `cache.sqlite` is (the probe saw its `-wal`); Gloda's
  `global-messages-db.sqlite` — look for a `-wal` on a running Thunderbird.
- That SQLite opens a WAL copy without `-shm` from a read-only connection, or whether the
  connection must be read-write (it's our copy either way).
- A spec: a WAL-mode fixture DB with a committed but uncheckpointed row. Today's code must miss
  the row and the fixed one must find it.
