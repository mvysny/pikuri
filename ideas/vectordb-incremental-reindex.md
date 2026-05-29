# Vectordb auto-watch + incremental reindex

Status: **designed, not built.** Architecture is settled (this
file); nothing is in source yet. This file is the staging area — as
pieces land in `pikuri-vectordb/lib/` or in `docs/guide/`, cut them
from here so what remains is always "not yet done."

Related, already in the repo:

- [`IDEAS.md`](../IDEAS.md) §"Vector DB / RAG" → "Deferred" — the
  short deferral list; this file is the long-form version of the
  "Auto-watch / incremental reindex" entry.
- {Pikuri::VectorDb::Indexer} — owns extract → chunk → embed →
  upsert today (`index_all!` / `reindex!` / `index_if_empty!`). The
  daemon does **not** reimplement this; it grows two new per-file
  entry points on the Indexer (below).
- {Pikuri::VectorDb::Backend} — the four-method duck-typed protocol
  (`upsert` / `query` / `delete_all` / `count`). Incremental adds
  three methods (below).
- {Pikuri::VectorDb::ChromaServer} — already process-scoped via
  {Pikuri::Finalizers} (`ensure_running!` registers `#close`, which
  `docker stop`s but keeps the volume). The daemon registers the
  same way and, being a dependent, tears down first.
- {Pikuri::Finalizers} — the LIFO teardown registry the daemon
  plugs into. Registration order *is* dependency order.

## What it is

Keep a persistent vector index in sync with a corpus on disk
*without* the user calling `vectordb_reindex` and paying the
full nuke-and-reload cost. Two separable layers:

1. **Incremental reindex** — per-file delete+reindex machinery, no
   threads. Useful on its own; fully testable without a watcher.
2. **Auto-watch** — a `listen`-backed daemon that drives layer 1
   from filesystem events plus a boot reconciliation sweep.

llamaindex has no index daemon; shipping one in pikuri itself
(usable by the future TUI and web app, not just a binary) is a real
value proposition, which is why the daemon lives in the library
rather than in a host script.

## The one simplification that collapses the hard part

The IDEAS deferral called the diff logic ("which chunks survived,
which got replaced, which got deleted") the hard part. We sidestep
it entirely by choosing the **coarsest possible unit of work — the
whole file**:

- **change** = delete all chunks for that source + reindex the file
- **delete** = delete all chunks for that source
- **move** = delete (old path) + reindex (new path)

No per-chunk diffing. The "edited file now has fewer chunks → stale
orphans `:4`,`:5`,`:6` left behind" problem disappears because we
always delete *all* of a source's chunks before re-adding. The unit
is a source path, never a chunk.

## Backend protocol: three new methods

- **`delete_by_source(source)`** — remove every chunk whose source
  is `source`. Chroma: `where: { source: … }`-filtered `/delete`
  (`source` is already a reserved metadata key — see
  `Backend::Chroma#upsert`). InMemory: hash filter. Returns `nil`.
- **`replace_source(source:, chunks:, vectors:)`** — `delete_by_source`
  + `upsert`, **as one critical section**. This is the entire
  incremental unit and the home for both the atomicity and the
  embed-before-delete ordering (below). Returns `nil`.
- **`sources_with_hashes` → `Hash{String => String}`** — `{source
  => content_hash}` for everything currently indexed. The boot
  sweep's reference. InMemory builds it from its in-memory chunks
  (empty at boot). Chroma reads it back cheaply — see the trick
  below.

### The `where: {offset: 0}` manifest trick

The boot sweep needs, per source file, its stored content hash —
without dragging the heavy vectors/text back over HTTP. Chroma's
`/get` takes both `where:` and `include:`, so two knobs make it
cheap:

- `include: ["metadatas"]` only — **excludes embeddings and
  documents**. You pull the metadata projection, not the index.
- `where: { offset: 0 }` — every indexed file has a `:0` chunk, so
  this returns **exactly one row per source file**, not one per
  chunk. Dedup falls out for free.

So the hash lives in chunk metadata (add `hash:` alongside the
existing `offset:` in `Chunk.metadata`); no sidecar file, no SQLite.
The backend stays the single source of truth.

**What is hashed:** the raw file *bytes* (`Digest::SHA256` hex), not
the extracted text. Hashing bytes is *why* a chunker/embedder
config change does **not** trigger reindex — see "Config changes"
below.

## Indexer: two new per-file entry points

The daemon stays thin and does **not** duplicate the
extract → chunk → embed → source-path logic. The Indexer grows:

- **`reindex_file!(path)`** — extract → chunk → embed → compute
  hash → `backend.replace_source(...)`. Reuses the *exact* same
  `relative_path_from(root)` source computation as `index_file`, so
  the daemon's chunk IDs line up byte-for-byte with the boot index's.
- **`remove_file!(path)`** — `backend.delete_by_source(source)`.

## Auto-watch daemon: `VectorDb::Watcher`

A thin wrapper over the [`listen`](https://github.com/guard/listen)
gem (inotify → FSEvents → polling fallback, recursive watch,
`ignore:` rules, `latency:`/`wait_for_delay:` debounce). The
`listen` dep lands in **`pikuri-vectordb.gemspec` only** — it never
touches core.

### Single work queue (last-intent-per-path)

The boot sweep and the live event stream **must not race**. If a
file changes during the sweep, the live event (new content) can be
processed first, then the sweep's already-enqueued *stale* reindex
overwrites it with old content. Fix:

1. **Subscribe to events first**, then run the sweep.
2. Funnel both into **one indexing worker**, keyed by source path,
   **last-intent-wins**.

The same queue gives coalescing for free: rapid edits to one file
collapse to a single reindex of the final state, and a
modify-then-delete within the debounce window nets to a delete. The
queue holds "latest intent per path," not a FIFO of every event.

### Boot reconciliation sweep (uniform across backends)

On start: walk the tree, hash each file, and for each ask "does the
backend already have this source at this hash?" If not → reindex.

- **InMemory** answers "no" to everything (empty at boot) → full
  index. **Chroma** answers from persisted metadata → only the diff.
  **No `backend.is_a?` branch anywhere** — InMemory is not a special
  case, it's the empty case of the same algorithm.
- This **subsumes `index_if_empty!` and the `index_on_boot:` knob**
  for daemon-hosted runs (the sweep *is* the boot index). The knob
  survives only for the one-shot binaries that run no daemon.
- The sweep also closes the **downtime gap**: changes made while the
  process was down are invisible to `listen`, but the hash compare
  catches them on next boot.

Naive scope, per the design call: full walk+hash on every boot,
last-intent queue, no incremental-on-the-sweep cleverness. Works for
personal-notes / small-corpus sizes; revisit when it bites.

## Concurrency

- **Lock lives inside `InMemory`.** A plain stdlib `Mutex` wrapping
  every method (audit-friendly; no new dep — though `concurrent-ruby
  1.3.6` is already transitively present if an RW lock is ever
  wanted). The lock's real job is making `replace_source`'s
  delete+upsert atomic so a concurrent `vectordb_search` never sees
  the gap. Chroma needs no client-side lock (server serializes).
- **More than two indexers collide.** The host MUST construct **one**
  `Backend` instance and pass the *same* object to both the daemon
  and every agent's `Extension.new(backend:)`. Per-agent backends
  would have the daemon indexing into a store nobody queries. This
  is the concrete form of "the daemon is host-owned, not
  agent-owned."
- **No model-contention optimization.** Re-embedding competes with
  the chat model on a shared `llama-server`, but vectordb is not
  meant for high-churn corpora (it's notes/docs, not a git tree), so
  we don't optimize for bursts. Revisit if it bites.

## Lifecycle: process-scoped, via Finalizers

Both `ChromaServer` and the `Watcher` are **process-scoped** (the
Chroma *container* is stopped on exit; persistence is in the
bind-mounted volume, not container lifetime). They register with
{Pikuri::Finalizers}; LIFO order *is* dependency order:

```
ensure_running! ChromaServer   # registers first  → closes last
build Backend / Indexer
Watcher#start                  # registers last   → closes first
```

So teardown runs `Watcher#close` → `ChromaServer#close` (`docker
stop`) → `Subprocess.cleanup!` (load-time backstop, bottom of stack).

- **`Watcher#close` MUST drain.** Stop accepting events *and block
  until the in-flight `replace_source` finishes* before returning.
  Otherwise `close` returns while an upsert is mid-flight, the sweep
  reaches `ChromaServer#close` → `docker stop`, and the upsert lands
  on a stopping container (caught + logged, but leaves a
  half-reindexed file). `close` = `listen.stop` + join the indexing
  worker.
- **`Watcher#close` is idempotent + unregisters.** Copy
  {Pikuri::Agent#close}'s shape verbatim — `@closed` guard +
  `Pikuri::Finalizers.unregister(self)` on explicit close, tolerant
  of the double-close (explicit, then `at_exit`).

## Decisions taken (rationale, so they aren't relitigated)

- **Whole-file unit, not chunk diffing** — see "the one
  simplification" above.
- **Config changes do nothing automatic.** Embedder swap or
  chunker/tokenizer param change → the file-byte hash is unchanged,
  so the sweep won't notice, and the daemon won't react. This is
  deliberate: the recourse is a manual full `vectordb_reindex`.
  Needs a **big fat warning** in the `Extension`/`Watcher` yardoc
  and the guide chapter: *"changed your embedder or chunker? reindex
  fully."* Detecting it automatically (a config fingerprint that
  forces full reindex) is a deferred refinement.
- **`docker stop`, not `rm -f`, on exit** — keeps the fast
  `:stopped → docker start` path; the volume carries the index
  either way. (Already shipped in `ChromaServer#close`.)
- **No library-installed signal trap.** Teardown rides the one
  process-global `Finalizers` `at_exit`; the `Watcher` does not
  install its own `trap`/`at_exit` (that hijacks the host's signal
  handling — the invisible-magic footgun pikuri avoids).

## Still open

- **Symlink policy parity.** `Indexer#list_files` and the `listen`
  watcher must agree (probably "don't follow"), or you index files
  whose changes you never see. Pin it when building.
- **`sources_with_hashes` at scale.** One `/get` call, but one
  metadata row per file — chunky JSON on a 50k-file corpus. Fine for
  the scoped sizes; the known "revisit when it bites" edge.
- **Where the daemon is constructed in practice.** No pikuri binary
  vends a long-running Chroma host yet (TUI / web app are the
  eventual owners), so for now this is library + documentation only.
