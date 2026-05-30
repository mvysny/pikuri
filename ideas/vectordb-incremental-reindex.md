# Vectordb auto-watch + incremental reindex

Status: **shipped as a library, exercised by the `pikuri-corpus
--watch` demo binary.**
Rationale and per-file design decisions live in the YARD headers
({Watcher}, {Indexer}, {Backend}, {VectorDb::Extension}); this file
keeps only what is still open.

## Still open

- **`sources_with_hashes` at scale.** One `/get` call, but one
  metadata row per file — chunky JSON on a 50k-file corpus. Fine for
  the scoped personal-notes / single-product-docs sizes; the known
  "revisit when it bites" edge.
