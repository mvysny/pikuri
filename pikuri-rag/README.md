# pikuri-rag

Hybrid retrieval for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit: a
keyword index beside the vectors, so the agent can answer every kind of
question people ask about a pile of their own documents.

[`pikuri-vectordb`](../pikuri-vectordb/README.md) alone answers *"what
did we agree about the migration plan?"*. Two other questions need a
keyword index:

- **Completeness.** *"Every note mentioning Acme."* A vector search
  returns the top few hits, never all of them, so a timeline built from
  it can silently miss a note.
- **Exactness.** *"Invoice #4471."* Embedders rank ids and proper nouns
  poorly, so the note holding the literal string can lose to one that
  merely talks about invoices.

This gem keeps the same chunks in an SQLite FTS5 index as well and
merges the hits from both indexes into one ranking.

## Wiring

Same parameters as `pikuri-vectordb`'s extension; only the class name
changes:

```ruby
require 'pikuri-rag'

ext = Pikuri::Rag::Extension.new(
  backend:  Pikuri::VectorDb::Backend::InMemory.new,
  embedder: Pikuri::VectorDb::Embedder.new(server: ..., model: ...),
  source:   '~/notes',
  private:  true,   # these documents are worth exfiltrating
  trusted:  true    # and every one of them is yours
)

agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension ext
end

# Filling the index is up to you, as with pikuri-vectordb.
watcher = Pikuri::VectorDb::Watcher.new(indexer: ext.indexer).start
```

`trusted: true` is a bigger claim than it looks: read
`Pikuri::VectorDb::Extension#trusted?` before you make it about a
folder holding PDFs or shared with anyone.

You can't add both this extension and `pikuri-vectordb`'s to one agent.
Doing so raises an error, so the model never gets two search tools that
promise different things.

**Where the keyword index lives.** `store:` is its SQLite path and
defaults to `":memory:"`. Keep it in memory when the vectors are in
memory, and put it in a file under `Pikuri::Paths.cache` when the
vectors are in Qdrant, so both survive a restart. Any other pairing
still works, but every start re-embeds the whole corpus.

### Who opens and closes what

Your app owns the stores, not the agent. One extension can be added to
several agents, and they all search the same index, so closing an
agent leaves the index alone, and the extension has no `close`.

- **The vector store** is yours: you build it and you pass it in as
  `backend:`, so you close it too. Closing a Qdrant server takes its
  container down.
- **The keyword index** is opened by the extension from `store:`, but
  you close it, through `ext.backend.close`. If you skip that, nothing
  is lost: every write is already on disk, and the file is released
  when the process exits.

Close things in the reverse order you opened them: first the watcher,
so nothing writes any more, then the agents, then the keyword index,
then the vector store:

```ruby
watcher.close
agent.close
ext.backend.close
vector_server.close   # or however your vector backend is shut down
```

`bin/pikuri-briefing` ends this way.

## What you get

1. **`rag_search`**: the best five passages, found by both indexes and
   merged into one ranking, optionally re-sorted by a reranker. Each
   passage is cited as `source lines a-b`.
2. **`rag_search_keywords`**: *every* document containing all the
   words, anywhere in it, with the lines where they occur. Nothing is
   cut off.
3. **`rag_read`**: one indexed document in full, by its `source`.
4. **`rag_reindex`**: rebuild both indexes from disk.

The last two are `pikuri-vectordb`'s tools under a `rag_` prefix. How
the two indexes are kept in step is in the yardoc of
`Pikuri::Rag::Backend::Hybrid`.

## Other languages

Words are matched by their stem, so "meetings" finds "meeting". The
default stemmer is English. For another language, pass `stemmer:`;
Finnish ships in pikuri-workshop's
[`pikuri-stemmers`](https://github.com/mvysny/pikuri-workshop/tree/master/pikuri-stemmers),
whose README says what to install:

```ruby
Pikuri::Rag::Extension.new(
  backend: ..., embedder: ..., source: '~/notes',
  stemmer: Pikuri::Stemmers::Voikko.new(Voikko.new(language: 'fi'))
)
```

Changing the stemmer of a saved index empties it at the next start,
and the next index run re-embeds every note. Why:
`design/decisions.md` `D_ruby_stemming`.

## Try it

`bin/pikuri-briefing` prepares you for a customer meeting from your
own hand-written notes: the timeline, what was discussed last, what was
promised. The model runs locally and the agent has no internet access.

```
./pikuri-rag/bin/pikuri-briefing --source ~/notes "brief me on Acme"
```

The walk-through is the guide's [RAG chapter](../book/rag.md).

## Install

```ruby
# Gemfile
gem 'pikuri-rag'
```

Pulls in `pikuri-vectordb`, `pikuri-core` and `sqlite3`, whose prebuilt
gem already includes FTS5, so the keyword index needs no extra service.

## Threat model

`pikuri-vectordb`'s, unchanged: the same `private:` / `trusted:`
declaration, no tool that sends anything out, and `rag_read` opens only
documents in the index. The keyword index is a second copy of the same
text, in an SQLite file owned by the same user. See
`pikuri-vectordb/design/architecture.md`.
