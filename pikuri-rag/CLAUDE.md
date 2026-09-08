# pikuri-rag — CLAUDE.md

This gem's must-not-break list, loaded beside the root `../CLAUDE.md`
when work touches this directory. One-line invariants + pointers only;
the truth lives in the cited yardoc, roads not taken in `../DECISIONS.md`
`D_rag_gem`, the walk-through in `book/rag.md`.

## Seams (invariants)

- **RAG seam (two stores composed).** The keyword half is its own backend (`Rag::Backend::Fts5`, the only file speaking SQL) and `Rag::Backend::Hybrid` holds *both* stores — never a sibling indexer, so the vectordb `Indexer` / `Watcher` stay reusable byte-for-byte. "Indexed" means both stores hold it; the membership gate is the vector store alone. See {Pikuri::Rag::Backend::Fts5}, {Pikuri::Rag::Backend::Hybrid}, `DECISIONS.md` `D_rag_gem`.
- **Model text never reaches `MATCH`.** Every FTS5 `MATCH` term comes from `Rag::Query` as a quoted phrase, so the query mini-language is inert in model text. `T_fts_match_via_query`. See {Pikuri::Rag::Query}.
- **Exclusive with `VectorDb::Extension`** on one agent — the retrieval *system* over the vectordb *primitive*, not a second copy of it.
