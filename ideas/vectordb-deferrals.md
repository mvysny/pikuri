# Vector DB / RAG deferrals

Status: **v1 shipped, follow-ups deferred.** `pikuri-vectordb` shipped —
local-corpus vector search + agentic RAG, wired onto an `Agent` via
`c.add_extension Pikuri::VectorDb::Extension.new(backend:, source:)`.
Per-piece rationale (Extension / Backend `InMemory`+`Qdrant`+`Chroma` /
Embedder / Reranker / Chunker / `bin/pikuri-corpus` + `LIBRARIAN`) lives
in the gem's YARD headers, the inventory in [`../CLAUDE.md`](../CLAUDE.md),
and [`../pikuri-vectordb/DESIGN.md`](../pikuri-vectordb/DESIGN.md); the
three-model ops guidance graduated into the `book/` chapters. Both
trifecta defenses (the no-egress `pikuri-corpus` posture and the
privilege-separated `LIBRARIAN`) are documented in
{Pikuri::VectorDb::LIBRARIAN} and [`../SECURITY.md`](../SECURITY.md).
Only the deferrals stay here.

## Deferred

- **A per-tool pool choice on `Extension`** — what the quarantined
  `LIBRARIAN` wiring actually waits on, and the reason no binary wires that
  persona yet. `#configure` registers all three tools with `c.add_tool`
  (`extension.rb:103–105`), so the boss always sees `vectordb_search`, which
  is the leg `book/assistant.md`'s design note wants gone.

  **Not blocked on the sub-agent side, despite what that chapter used to
  say.** `Configurator#add_sub_agent_tool` hides a tool from the parent's
  LLM and a persona's `tool_names` resolves against both pools
  (`sub_agent_tool.rb:91`) — the shape `RESEARCHER`'s web tools already
  ship in. A host can build the quarantined wiring *today* by
  hand-constructing backend + embedder + chunker + `Indexer` + the three
  tools, which is only unpleasant, not impossible; the extension exists to
  spare exactly that.

  Make it **per tool**, not a blanket switch: `vectordb_search` /
  `vectordb_read` return corpus content and belong behind the librarian,
  while `vectordb_reindex` returns a count and is fine on the boss. The
  pre-registration guard needs to learn about the second pool at the same
  time, or it fires on the very wiring this enables. (The broader
  "a `Persona` carries its own tool *instances*" idea is
  [`subagent-deferrals.md`](subagent-deferrals.md)'s, and this case does
  **not** need it — hiding a shared instance is enough; owning one is only
  earned when a child needs it *configured differently*.)

- **Classic-RAG-as-listener.** Auto-inject relevant chunks at the
  start of each turn (no tool call) — hermes' prefetch shape (see
  [`../pikuri-memory/DESIGN.md`](../pikuri-memory/DESIGN.md) §"The three
  retrieval tiers"). v1 ships agentic search only — fits the
  loop-agnostic ethos and the agent gets to refine queries. Add
  the listener variant if a concrete "the model forgot to search"
  pattern shows up.
- **Per-doc-type chunkers.** Markdown-heading-aware splitter,
  AST-aware code chunker, contextual chunking. All real quality
  wins, all separately scoped features. (Parent-document
  retrieval shipped instead as the `vectordb_read` tool — the
  agent reads the whole source document on a clean hit, rather
  than the chunker stitching parent context onto every chunk.)
- **A document-level recall mode.** Today `vectordb_search` answers
  *precision*: top-k chunks, reranked, each snippet capped at
  `Search::SNIPPET_LENGTH`. That is the right shape for a corpus of long
  documents and the wrong one for a pile of short notes, where the
  snippet is a lossy intermediate the agent discards — it reads the whole
  document anyway via `vectordb_read`. What that corpus wants is the
  complement: **rank documents rather than chunks and return only their
  `source` paths**, so the agent gets a wide, cheap candidate list and
  reads what it wants in full. A hundred filenames cost less context than
  three chunks.

  Motivated by [`briefing.md`](briefing.md), whose flat notes corpus needs
  two things vector search structurally cannot give: **completeness**
  ("every note mentioning Acme" — top-k is a sample, and a timeline with
  one silently missing note is worse than none) and **ordering by date**
  (chunks carry no dates; the `source` path does). The workaround was to
  bolt `grep` + `file_list` from `pikuri-workspace` onto that agent —
  which patches a retrieval shortcoming from outside the gem that owns
  retrieval. Fix it here instead.

  Four forks to settle when it is built:

  - **Cutoff, or genuinely everything?** Cosine has no natural zero, so
    "find everything" either returns every indexed source ranked (honest,
    and over a small corpus perfectly usable — it is `file_list` ordered
    by relevance) or keeps a cutoff and can still miss. Only the first can
    claim completeness; the tool has to say which it promises, because
    "probably everything" is the reading that makes a brief quietly wrong.
  - **How chunk scores aggregate to a document.** Max, mean or sum over
    the document's chunks — the classic passage-to-document problem. Max
    is the usual answer and the defensible one: a note with a single
    dead-on chunk should beat one that is vaguely on-topic throughout.
  - **Reranker bypass.** The reranker is the precision device and reorders
    *snippets*; a recall mode has none to reorder, so it skips the
    reranker entirely. State that rather than leaving it to be discovered
    from a latency measurement.
  - **The corpus-shape precondition.** "The agent reads them in full" only
    holds while documents are short. Over a corpus of 100-page PDFs a list
    of fifty filenames is useless. So this is a mode a host opts into
    knowing its corpus, never a new default.

  **What it does not fix: exact-string search.** "invoice #4471" is a
  token an embedder ranks badly however wide the net, and a document
  containing the literal string can rank below one merely discussing
  invoices. Nothing in pikuri complements the embedder here
  (`book/vectordb.md`: "no keyword index underneath, no inverted file, no
  fuzzy match"), so hybrid retrieval — BM25 beside the vectors, or `grep`
  wired alongside — is its own deferral, and the honest thing to reach for
  if that specific gap is what bites.

- **Onyx as a separate gem.** Onyx is a product (UI + connector
  framework + scheduler), not a vector DB. If pikuri wants Google
  Drive / Slack / Jira RAG, the right shape is `pikuri-onyx` —
  a thin tool gem that calls a self-hosted Onyx's search API over
  HTTP. Same precedent as MCP: integrate with the protocol, don't
  reimplement it. Onyx's heavy operational footprint stays opt-in
  and out of pikuri-vectordb's scope.
- **Memory growth tier integration.** `pikuri-memory` v1 shipped on
  its own external semantic store (mem0 + Qdrant; see
  [`../pikuri-memory/DESIGN.md`](../pikuri-memory/DESIGN.md) §"Why mem0"),
  *not* pikuri-vectordb — so the once-open "could memory ride the same
  primitive?" question is moot for now. Revisit only if consolidating
  the two stores onto one backend ever becomes worth it; not a v1 goal.
- **Configurable ignore rules.** `Indexer::DENYLIST` ships a fixed
  set (`.git`, `node_modules`, dot-files); `.gitignore`-shaped
  user-configurable skip rules defer until someone asks.
- **Multi-source indexing.** `Extension.new(source:)` takes a single
  file-or-directory root in v1; `Indexer` walks one root. Indexing
  several disjoint roots into one collection (the user's notes dir +
  a checked-out repo + a downloads folder) is deferred — it needs a
  source-list API and a provenance story for which root a hit came
  from. Referenced from `VectorDb::Extension` / `Indexer` yardoc
  (that yardoc is the source of truth). **The per-source `trusted:` /
  `private:` flag is part of that API** — design it in from day one
  rather than retrofitting: trust becomes per source, the union follows
  the `Bundle::Base` rule (one unvouched root indexed into the
  collection takes the whole tool set to `:hard`; `private` is true if
  any root claims it), and the legs are computed from the source list at
  `#configure` rather than from a single boolean. See `DECISIONS.md`
  `D_corpus_trust_declaration`.
- **Additional reranker backends.** Only `Reranker::LlamaServer`
  ships. Because it speaks the same `/v1/rerank` wire format as
  Cohere's hosted reranker, a `Reranker::Cohere` (or any other
  hosted cross-encoder) is a thin adapter behind the same duck-typed
  `#rerank(query:, documents:)` protocol — deferred until someone
  wants a non-local reranker. Referenced from `VectorDb::Reranker`
  yardoc (that yardoc is the source of truth).
