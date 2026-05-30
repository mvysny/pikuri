# Vectordb auto-watch + incremental reindex

Status: **shipped as a library; no long-running host wires it yet.**
Rationale and per-file design decisions live in the YARD headers
({Watcher}, {Indexer}, {Backend}, {VectorDb::Extension}); this file
keeps only what is still open.

## Still open

- **No production host constructs the Watcher.** The demo binary
  `pikuri-corpus --watch` wires it (good for exercising it by hand),
  but the real long-running owners — the planned `pikuri-tui` and a
  web app — don't exist yet, so the daemon has no end-to-end run
  against a real `listen` watch + live Chroma container under load.
- **Guide chapter.** `docs/guide/03-vectordb.md` now has a
  "Putting it together: `--chroma --watch`" walkthrough (boot sweep,
  first-vs-subsequent runs, live reindexing). What it still omits is
  the host-owned-lifecycle detail — the Finalizers teardown order and
  the reindex-on-config-change rule — because that only has a real
  wiring to show once the long-running host above lands. Fold it in
  then, against the host rather than the demo binary.
- **`sources_with_hashes` at scale.** One `/get` call, but one
  metadata row per file — chunky JSON on a 50k-file corpus. Fine for
  the scoped personal-notes / single-product-docs sizes; the known
  "revisit when it bites" edge.
