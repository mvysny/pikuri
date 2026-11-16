# pikuri-rag

Hybrid retrieval for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit: a
keyword index beside the vectors, so the agent can answer both kinds
of question a pile of your own documents gets asked.

`pikuri-vectordb` is the primitive — pure geometry over meaning
vectors, which is exactly right for *"what did we agree about the
migration plan?"* and structurally wrong for two others:

- **Completeness.** *"Every note mentioning Acme."* Top-k is a
  sample, and cosine similarity has no calibrated zero, so no cutoff
  can be documented as a promise. A timeline with one silently
  missing note is worse than no timeline.
- **Exactness.** *"Invoice #4471."* Proper nouns, ids and rare tokens
  are what embedders rank worst — the note holding the literal string
  can rank below one merely discussing invoices.

This gem is the retrieval *system* on top: an SQLite FTS5 keyword store
holding the same chunks, whose hits are fused with the vector store's
by reciprocal rank.

## Wiring

One line different from `pikuri-vectordb` — same parameters, same
corpus declaration:

```ruby
require 'pikuri-rag'

ext = Pikuri::Rag::Extension.new(
  backend: Pikuri::VectorDb::Backend::InMemory.new,
  source:  '~/notes',
  private: true,   # these documents are worth exfiltrating
  trusted: true    # and every one of them is yours
)

Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension ext
end

# Population is the host's call, exactly as with pikuri-vectordb.
Pikuri::VectorDb::Watcher.new(indexer: ext.indexer).start
```

`trusted: true` is a bigger claim than it looks — read
`Pikuri::VectorDb::Extension#trusted?` before making it about a folder
holding PDFs or shared with anyone. Nothing about the keyword index
changes what those clauses mean.

The two extensions are **mutually exclusive on one agent**: each
refuses the other's tool names, so wiring both raises rather than
handing the model two search tools with different promises.

## What you get

Four tools, registered by the extension:

1. **`rag_search`** — the hybrid ranking. Embeds the query for the
   vector leg, ORs its terms for a bm25-ranked keyword leg, fuses the
   two by reciprocal rank, optionally reranks with a cross-encoder,
   and hands back five `source lines a-b` snippets, best first.
2. **`rag_search_keywords`** — the complete listing. ANDs the (stemmed) terms
   *across the whole document* and returns *every* match: `source`,
   matching-chunk count with the line each starts at, byte size. No
   cutoff, no top-k.
3. **`rag_read`** — one indexed document in full, by the `source` path
   either of the other two printed. `pikuri-vectordb`'s tool under
   this gem's prefix, membership gate and all.
4. **`rag_reindex`** — build or rebuild the index from disk, both
   stores at once. Also `pikuri-vectordb`'s.

## How the keyword half rides along

Two classes, and they compose rather than nest.

`Pikuri::Rag::Backend::Fts5` is the keyword store: chunks in an SQLite
FTS5 table, `#keyword_query` for a bm25-ranked top-k and `#find` for
the complete listing. It is the only file in the gem that speaks SQL,
and it works on its own — a corpus with no embedder at all can be
indexed into it and searched by word.

`Pikuri::Rag::Backend::Hybrid` is a `pikuri-vectordb` backend holding
*both* stores: it fans every write out to the two and keeps their reads
separate for the search tool to fuse. Because it is a duck rather than
a subclass, the vectordb `Indexer` and `Watcher` drive it unchanged —
one walk, one text extraction per file, one content hash — and because
both stores hold the same `Chunk`s, both legs answer with the same ids
and the same `source` citations. A third index would be a third store
handed to `Hybrid`, not another wrapper around it.

`#find` runs one query per term and intersects by `source`, rather than
the single query FTS5's implicit AND invites: that AND is row-scoped,
and a row is a chunk, so the one-query form silently omits a document
whose terms land in different chunks.

Two reads do not simply delegate, because **"indexed" means both stores
hold it**: the manifest is the intersection, and `#count` is `0` when
either store is empty — which is what makes a persistent Qdrant
collection beside a fresh in-memory keyword index converge on the next
boot sweep instead of booting to a silently empty `rag_search_keywords`.

`store:` on the extension is the keyword index's SQLite path,
`":memory:"` by default. Pair it with the backend: in-memory with
in-memory, a file under `Pikuri::Paths.cache` with Qdrant. A
mismatch is *correct* thanks to the rule above, only slower — a full
re-embed at every boot.

## Stemming: English, and other languages through `stemmer:`

Out of the box the keyword leg uses FTS5's built-in `porter` stemmer, so
"meetings" matches "meeting" in English. Another language is a stemmer
passed as `stemmer:`. Finnish is in pikuri-workshop's
[`pikuri-stemmers`](https://github.com/mvysny/pikuri-workshop/tree/master/pikuri-stemmers),
whose README says what each language needs installed:

```ruby
Pikuri::Rag::Extension.new(
  backend: ..., source: '~/notes',
  stemmer: Pikuri::Stemmers::Voikko.new(Voikko.new(language: 'fi'))
)
```

Switching stemmers on a saved index empties it at the next start, and
the next index run re-embeds every note. Why it works this way:
`design/decisions.md` `D_ruby_stemming`.

## Try it

`bin/pikuri-briefing` is the demo: a no-egress agent over your own
hand-written notes that prepares you for a customer meeting — timeline,
what was discussed last, what was committed. Local inference, no
internet, nothing but the notes folder.

```
./pikuri-rag/bin/pikuri-briefing --source ~/notes "brief me on Acme"
```

The walk-through is the guide's [RAG chapter](../book/rag.md).

## Install

```ruby
# Gemfile
gem 'pikuri-rag'
```

Depends on `pikuri-vectordb` (which pulls in `pikuri-core`) and
`sqlite3` — the prebuilt gem ships a SQLite with FTS5 and a working
`porter` tokenizer compiled in, so the keyword half needs no external
service. Install `pikuri-vectordb` alone if you only want the vector
primitive; the two extensions cannot both be wired onto one agent.

## Threat model

`pikuri-vectordb`'s, unchanged — which is why this gem ships no
`design/architecture.md` of its own. Same corpus, same `private:` / `trusted:`
declaration, same inbound-only posture (no tool here has an egress
leg), same membership gate on the reader. The keyword index is a
second copy of text the vector store already holds, in a SQLite file
the same user owns. See `pikuri-vectordb/design/architecture.md`.
