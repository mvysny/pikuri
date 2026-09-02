# pikuri-rag: a retrieval system on top of the vector primitive

Status: **decided 2026-09-02 (`DECISIONS.md` `D_rag_gem`), ready to
build.** The *why* — the diagnosis, the gem-vs-fold-in fork, decorator vs.
composite indexer, English-only, the retired recall mode — has graduated
into that entry and is not repeated here. The three `pikuri-vectordb`
seams the gem needs are shipped (`family:` on `Tools::Read` /
`Tools::Reindex`, `VectorDb::CorpusLegs.derive`, the `Backend` yardoc
naming the protocol decoratable). What stays in this note is the **build
plan**: the mechanics an implementer needs that are too early for yardoc
because the code does not exist yet. Each section names its graduation
home; the note is deleted when the gem lands.

Related:

- `DECISIONS.md` `D_rag_gem` — the decision and the roads not taken.
- [`vectordb-deferrals.md`](vectordb-deferrals.md) §"A document-level
  recall mode" — superseded; delete that bullet at landing.
- [`briefing.md`](briefing.md) — the first host; its Stage 0 wiring
  becomes `Rag::Extension`, and `pikuri-briefing` lands in `pikuri-rag/bin/`.

## Gem skeleton

`pikuri-rag/` in the monorepo shape: `lib/pikuri/rag/…` under a Zeitwerk
loader (acronym inflection: none needed — `Rag`, `Fts` are plain
camelcase; `FTS5` never appears in a constant), `spec/`, gemspec with
`pikuri-vectordb` + `sqlite3 ~> 2.9` as dependencies, an inventory line
in CLAUDE.md, a lockstep pin in the `pikuri` metagem, `bin/pikuri-briefing`.
Header states the threat model is `pikuri-vectordb`'s unchanged (same
corpus legs, inbound-only, same membership gate) — no DESIGN.md.

Constants, so the note and the code agree on names:

- `Pikuri::Rag::Extension` — `new(backend:, source:, embedder:, reranker:,
  chunker:, private:, trusted:, store:)`; the vectordb kwargs are passed
  through, `store:` is the SQLite path (default `:memory:`, see
  §Persistence). Wraps `backend:` in the decorator, builds the vectordb
  `Indexer` over the decorator, exposes `#indexer` for the host's `Watcher`
  exactly as `VectorDb::Extension` does.
- `Pikuri::Rag::Backend::Hybrid` — the decorator (§Decorator).
- `Pikuri::Rag::Tools::Search`, `Tools::Find` — new; `rag_read` /
  `rag_reindex` are `VectorDb::Tools::Read.new(..., family: 'rag')` /
  `Reindex.new(..., family: 'rag')`, zero new code.
- `Pikuri::Rag::Query` — the tokenizer that turns model text into a safe
  FTS5 `MATCH` expression (§Escaping).

## Decorator: `Rag::Backend::Hybrid`

Delegates the whole eight-call `Backend` protocol to the inner vector
backend and mirrors writes into one FTS5 table
`chunks(id UNINDEXED, source UNINDEXED, hash UNINDEXED, text,
tokenize='porter unicode61')`. Rows are the `Chunk`s, so fusion and the
reader work on the same ids and sources.

- **Writes, FTS first, then inner.** `upsert`, `replace_source`,
  `delete_by_source`, `delete_all` each write FTS inside one SQLite
  transaction, then call the inner backend. The embed already happened
  before any of these are reached (the `Indexer` embeds before writing),
  so the only thing that can fail *between* the two stores is the inner
  network call — and then the vector manifest is the one that lags, which
  the boot sweep repairs.
- **"Indexed" means both stores hold it.** The one non-delegating read
  logic, and a correctness invariant, not tidiness: `sources_with_hashes`
  returns the inner manifest *filtered to sources FTS also has*, and
  `count` returns `0` when either store is empty (else the inner count).
  That is what makes a persisted Qdrant beside a fresh `:memory:` FTS
  converge — the `Watcher`'s sweep sees the FTS-less sources as unindexed
  and `replace_source`s them into both; `index_if_empty!` sees `0` and
  fills both. Without it a host with a persistent vector store and a
  default FTS store boots to a silently empty `rag_find`.
- **Reads that the vectordb tools use** (`query`, `source_indexed?`)
  delegate untouched. The decorator adds two of its own:
  `keyword_query(match:, top_k:)` → `Array<Backend::Result>` scored by
  `bm25()`, for the search tool's FTS leg; and
  `find(match:)` → `Array<[source, matched_chunk_count]>` via
  `GROUP BY source`, for `rag_find`.
- **Sharing: `P_shared_locked`.** A `sqlite3` connection is not safe for
  concurrent use, and the `Watcher` thread writes while agent threads
  read — one `Monitor` around every SQLite call, the same posture
  `Backend::InMemory` takes. Inner-backend calls happen outside the lock.

Graduates to: the class yardoc (`== Implementation details` for the
both-stores rule and write order).

### Persistence

`store:` on the extension, default `:memory:`. Guidance, not inference:
pair `:memory:` with `Backend::InMemory` and a file under `Paths.cache`
keyed by the collection name with Qdrant / Chroma. A mismatch is *correct*
thanks to the both-stores rule above, only slower (a full re-embed at
boot), so this is a yardoc paragraph and a `bin/pikuri-briefing` default,
not a check.

## The tool set

Prefix `rag_`; one shared backing resource, the decorated backend.

- **`rag_search(query)`** — hybrid top-k. Vector leg: embed, inner
  `query(top_k: 50)`. Keyword leg: `keyword_query(match: Query.any(query),
  top_k: 50)` — terms **OR**ed, bm25-ranked, because a twelve-word
  natural-language question ANDed matches nothing and bm25's idf already
  discounts the "what did we discuss" words. Fuse by reciprocal rank
  (`1/(60+rank)`, the standard constant) over chunk ids, then the optional
  `Reranker` over the fused candidates, then `FINAL_K = 5` with the same
  observation format as `vectordb_search` — score shown is whatever built
  the order. Keep `vectordb_search`'s constants; measure before changing.
  Legs: `CorpusLegs.derive` from the extension flags.
- **`rag_find(terms)`** — the complete listing. `Query.all(terms)` —
  terms **AND**ed, stemmed — `find(match:)` grouped by `source`; per row
  `source`, matched-chunk count, size in lines and bytes read from disk at
  call time (`File.size`, line count via `File.foreach`). Sorted by count
  desc then `source` asc, so a `name-date.md` convention yields a
  date-ordered tail. **No cutoff, no top-k**, and the description says so
  in those words, plus: pass one entity or term, not a sentence
  (AND semantics), and "the agent reads them in full" only pays off over
  short documents. Counts are chunks, not occurrences — cheap, and honest
  once the header says "chunks". Legs: as `rag_search`. Sharing:
  `P_shared_locked` via the decorator.
- **`rag_read`** / **`rag_reindex`** — the vectordb classes under
  `family: 'rag'`. One wrinkle to accept or fix while wiring:
  `Read.description` says "the citation from rag_search" and `rag_find`
  also returns citations. Fix is a second sentence in `Read.description`
  mentioning "or a listing" — generic enough to be true of both families.

Graduates to: each tool's yardoc + `description:`; the AND/OR split and
the RRF constant go in `Tools::Search` / `Tools::Find` yardoc.

### Escaping: `Rag::Query`

FTS5 `MATCH` is a mini-language (`NOT`, `OR`, `AND`, `*`, `^`, `:`
column filters, phrase quotes, `{}` / `()` grouping); a stray quote or a
leading `-` in model text is an SQL error. `Query.all(text)` /
`Query.any(text)` tokenize on `\p{L}` / `\p{N}` runs, lower-case, drop
empties, and emit each token as a quoted phrase term — `"acme" "pricing"`
(AND is FTS5's implicit default) or `"acme" OR "pricing"`. The operators are
never exposed; "Acme *or* Initech" is two `rag_find` calls. An empty token
list returns `"Error: no searchable terms in …"` from the tool, never
reaches SQLite.

Graduates to: `Query` yardoc, with the spec as the truth table.

## Landing checklist (the siblings)

- Reword "agentic RAG" → *semantic retrieval primitive / topical retrieval
  over long documents* in the CLAUDE.md inventory line,
  `VectorDb::Extension`'s header, the gemspec summary; one paragraph in
  `book/vectordb.md` where it says "no keyword index underneath" pointing
  at the RAG chapter.
- `VectorDb::Extension#configure` refuses `rag_*` pre-registered;
  `Rag::Extension#configure` refuses `vectordb_*` and `rag_*`. Spec both.
- Delete the recall-mode bullet from `vectordb-deferrals.md`.
- `briefing.md`: Stage 0 wiring → `Rag::Extension`; retire "see whether
  the gap bites"; strike the one-collection-per-customer question; the bin
  moves to `pikuri-rag/bin/`. (Or graduate the note wholesale if the
  chapter + binary land in the same stretch.)
- CHANGELOG: one `Add pikuri-rag` entry naming the four tools; one
  `**Breaking:**`-free reword note is *not* needed (positioning prose is
  not API).
- Book: `book/rag.md`, a chapter after `vectordb.md`, owning hybrid
  retrieval and the primitive-vs-system distinction; ToC line + the two
  neighbouring "What's next" links. Chapter over section because the
  briefing chapter needs a home to point at and the concept is distinct.

## Open questions

None that block a first implementation. Two to settle while writing, not
before:

- **`rag_read`'s description wording** for the find-vs-search citation
  (above) — decide when the sentence is in front of you.
- **Does `rag_find` show sizes for every row or only the first N?** A
  flat notes corpus has hundreds of small files, so `File.size` per row is
  negligible; if a corpus ever returns thousands of rows the observation
  size is the problem, not the stat calls. Show for every row; revisit on a
  real corpus.
