# Vectordb auto-watch + incremental reindex

Status: **shipped as a library; no long-running host wires it yet.**
Per-file rationale now lives in the YARD headers (the source of
truth); this file keeps only what is still open.

## What landed

Two layers, behind the four-method {Backend} protocol that already
shipped:

- **Incremental reindex** (no threads): {Backend} grew
  `delete_by_source` / `replace_source` / `sources_with_hashes` on
  both `InMemory` (atomic under a reentrant `Monitor`) and `Chroma`
  (the `where: {offset: 0}` + `include: ['metadatas']` manifest read).
  {Indexer} grew `reindex_file!` / `remove_file!` / `reconcile_plan`,
  and every chunk now carries `metadata[:hash]` (SHA-256 of the file
  bytes). Embed-before-write ordering is enforced in `reindex_file!`.
- **Auto-watch** (`VectorDb::Watcher`): a `listen`-backed daemon —
  single last-intent-per-path work queue, boot reconcile sweep
  enqueued after the listener subscribes, {Pikuri::Finalizers}
  registration (LIFO closes it before the host's `ChromaServer`),
  drain-the-in-flight-job teardown. `listen` is a gemspec dep,
  required lazily in `#start`.

The settled design decisions (whole-file unit, config-change does
nothing + the loud reindex warning, `docker stop` not `rm`, no
library-installed signal trap) are recorded in the relevant yardocs
({Watcher}, {Indexer}, {Backend}, {VectorDb::Extension}).

## Still open

- **No production host constructs the Watcher.** The demo binary
  `pikuri-corpus --watch` wires it (good for exercising it by hand),
  but the real long-running owners — the planned `pikuri-tui` and a
  web app — don't exist yet, so the daemon has no end-to-end run
  against a real `listen` watch + live Chroma container under load.
- **Guide chapter.** `docs/guide/03-vectordb.md` now mentions the
  empty-corpus exercise and `--watch`, but there's no dedicated
  auto-watch walkthrough (host-owned lifecycle, the Finalizers
  teardown order, the reindex-on-config-change rule). Flesh it out
  when the host above lands, so the docs show a real
  wiring rather than a sketch.
- **Symlink policy parity.** `Indexer#list_files` (the walk) and the
  `listen` watch both treat symlinked directories as the OS does and
  neither special-cases them; they can diverge (index a symlinked
  file whose target changes off-tree, never see the event). Pin a
  policy if it bites.
- **`sources_with_hashes` at scale.** One `/get` call, but one
  metadata row per file — chunky JSON on a 50k-file corpus. Fine for
  the scoped personal-notes / single-product-docs sizes; the known
  "revisit when it bites" edge.
