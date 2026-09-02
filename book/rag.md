# Hybrid retrieval: the questions vectors can't answer

By the end of this chapter you'll have an agent that briefs you on a
customer from your own hand-written meeting notes — timeline, what was
discussed last, what was committed and still open — and you'll
understand why that agent needs something the [previous
chapter](vectordb.md) deliberately did not have: a keyword index
sitting beside the vectors.

This is also the first chapter that points you at your *own real
private data* and hands you something you'd run on a Monday morning.
Every demo so far has indexed the pikuri book, your own repo, or your
machine. This one wants your notes folder. The agent it builds has no
internet, no mail, no shell — it reads your notes and talks to you,
and that is the whole of it.

## Two questions the vector DB cannot answer

The vector-DB chapter left you with a sentence worth re-reading:
*there is no keyword index underneath, no inverted file, no fuzzy
match — it's pure geometry over meaning vectors.* That geometry is
excellent at one question and structurally incapable of two others.

The question it answers is **relevance**: *"what did we agree with
Acme about the migration plan?"* Embed the question, return the five
nearest chunks, optionally rerank them. Nothing else in this book does
that better.

Now try these two.

**Completeness.** *"Show me every note that mentions Acme."* Vector
search returns the top *k* — a sample, by construction. You could
raise *k*, but to what? Cosine similarity has no calibrated zero: a
score of 0.31 means "somewhat related" for one embedder and one corpus
and something else for another, so there is no threshold you can
document as a promise. And this is not a mild imprecision. A brief
assembled from a ranked handful of notes is *quietly* wrong: the note
you didn't see is the commitment nobody remembers, and the agent has
no way to know it was missing.

**Exactness.** *"Which note has invoice #4471?"* Rare tokens — invoice
numbers, ticket ids, a customer's name, a product SKU — are precisely
what embedders rank worst. An embedder is trained to place *meanings*
near each other, and `4471` has no meaning; the note holding the
literal string can easily rank below one that merely discusses
invoices at length. This is the failure that feels like a bug the
first time you hit it, and it isn't one. It's the model doing exactly
what it was built to do.

Neither is a shortcoming to patch on the vector side. The field
settled this years ago: put a **keyword index** beside the vectors and
combine the two. That's *hybrid retrieval*, and it's what
`pikuri-rag` is.

## Two tools, two promises

`pikuri-rag` ships four tools, and the interesting split is between
the first two.

**`rag_search`** is the ranked answer, and it runs both legs:

- The **vector leg** embeds your query and pulls the 50 nearest
  chunks — the previous chapter's pipeline, unchanged.
- The **keyword leg** takes the same query, splits it into words, and
  asks the keyword index for the 50 best matches by
  [BM25](#bm25-in-one-paragraph).

Then it fuses the two lists and returns five results. So *"what did we
agree about pricing?"* still works through meaning, and *"invoice
4471"* now works through the literal token, from the same tool call.

**`rag_find`** is the *complete* answer, and it has no vector leg at
all. Give it a term and it returns **every** document containing it —
the `source` path, how many of its chunks matched, and the file's
size:

```
3 documents contain all of: "acme" "pricing". Counts are how many of the document's chunks matched, not occurrences.

acme-2026-08-14.md — 3 chunks, 5.2 KB
acme-2026-07-02.md — 1 chunk, 1.8 KB
acme-2026-03-11.md — 1 chunk, 2.4 KB
```

No cutoff, no top-*k*, and the tool's own description says so in those
words — because the promise is the whole point. A keyword match is
*boolean*: either the word is in the document or it isn't. That's what
lets this tool claim completeness where no amount of tuning could let
`rag_search` claim it.

The size is bytes and not lines, which is a small decision with a
reason: bytes cost one `stat`, where a line count means reading every
matching file end to end. And for anything the extractor converts —
a PDF, a DOCX — the file's newlines are *container* bytes, not the
text the model reads, so the number would disagree with the offsets
`rag_read` pages by. Bytes answer the only question the agent is
actually asking here, which is *is this short enough to read whole?*

The other two tools are `rag_read` (pull one indexed document into
context in full, by a `source` path either of the above printed) and
`rag_reindex` (build or rebuild the index). Those are
`pikuri-vectordb`'s own tools, registered under this gem's prefix —
same code, same membership gate, one different string in their name.

**Why two tools rather than one with a `mode:` flag?** Because they
make different promises with different output shapes, and a model
choosing between them by flag value is a model reading a parameter
description instead of a tool name. `rag_search` returns ranked
snippets; `rag_find` returns a complete listing. Those are two tools.

### The AND/OR split, which looks like an inconsistency

`rag_search` **OR**s the words in your query. `rag_find` **AND**s
them. Same corpus, same index, opposite operator — and both are right.

`rag_search` takes a natural-language question. *"What did we agree
with Acme about pricing?"* is eight words; ANDing them matches nothing,
because no chunk contains all eight. OR maximizes recall and BM25 does
the ranking — and BM25's inverse-document-frequency term already
discounts "what", "did", "we" and "about", which appear in every
document and therefore carry almost no score.

`rag_find` takes terms, and its promise is a *set*. If you ask for
"acme pricing", a set that includes every note saying "pricing" is not
the set you asked for. So the tool ANDs, and its parameter description
tells the model to pass one entity or a couple of words rather than a
sentence.

**And that AND is per document, which is not what you get for free.**
SQLite's full-text search has an implicit AND — write two words and it
requires both — but it evaluates that AND *within one row*, and a row
here is a chunk, not a document. So the obvious one-line query silently
omits a note whose "Acme" sits in its first chunk and whose "pricing"
sits in its fourth. That is not a corner case: under the default
512-token chunker, any note past a couple of kilobytes is several
chunks, so the obvious query fails on exactly the long notes a briefing
cares about most — and it fails by returning *nothing*, which reads as
"no such note".

So `pikuri-rag` queries once per term and intersects the results by
`source`. Two words, two queries, and a document is listed when every
term appears *somewhere* in it. Worth dwelling on because it is the
shape of bug this whole tool exists to prevent: an answer that looks
like a confident "none" and is actually a missing row.

### BM25 in one paragraph

BM25 is the standard relevance score for keyword search, and it's
worth knowing what it rewards, because it's not "how many times does
the word appear". Three factors: **term frequency** (more occurrences
score higher, with diminishing returns — the tenth mention adds much
less than the second), **inverse document frequency** (a word that
appears in every document is nearly worthless; a rare word is
valuable), and **length normalization** (a match in a short note
counts for more than the same match buried in a long one). That last
one is why, in a two-note corpus where both mention pricing, the
shorter note ranks first.

Stemming happens before any of that. `pikuri-rag` uses SQLite's
built-in Porter stemmer, so "meetings", "meeting" and "meet" collapse
to one term and a search for the singular finds the plural. Porter is
**English-only** — that's a current limitation, documented rather than
hidden, and the gem's README says what the fix would look like.

### Reciprocal rank fusion, and why not a weighted sum

You have two ranked lists. How do you merge them?

The tempting answer is a weighted sum of the scores: `0.7 × cosine +
0.3 × bm25`. Don't. Cosine similarity lives in `[0, 1]`. BM25 is an
unbounded corpus statistic whose magnitude depends on how many
documents you have and how long they are — in a two-document corpus
it's a millionth of a unit; in a ten-thousand-document one it's single
digits. Adding those two numbers is adding a percentage to a
temperature, and every weight you pick is a knob with no principled
setting.

**Reciprocal rank fusion** throws the magnitudes away and keeps only
what each leg is actually good at: the *ordering*. A chunk at rank *r*
in a list contributes `1 / (60 + r)` to its fused score, summed across
the lists it appears in. So:

- A chunk both legs found ranks above a chunk only one leg found, even
  if that one was somebody's rank 1. Agreement between two different
  retrieval methods is strong evidence.
- The `60` flattens the top of each list, so a single confident rank-1
  hit can't out-vote that agreement. It's the constant the original
  TREC evaluation settled on, and it's what every hybrid stack ships.

After fusion, the optional cross-encoder reranker from the last
chapter runs over the fused candidates unchanged — it never knew where
its candidates came from.

## How the keyword index rides along

Here's the part worth understanding even if you never touch the code,
because it's the reason this gem is small.

`pikuri-rag` does **not** ship a second indexer. It ships two small
classes that compose:

```ruby
hybrid = Pikuri::Rag::Backend::Hybrid.new(
  vectors:  Pikuri::VectorDb::Backend::InMemory.new,   # last chapter's store
  keywords: Pikuri::Rag::Backend::Fts5.new             # the new one
)
```

`Fts5` is the keyword store — chunks in a SQLite full-text table, and
the only place in the gem that speaks SQL. `Hybrid` holds both stores,
fans every write out to the two, and keeps their reads separate for the
search tool to fuse.

To everything upstream — the indexer that walks your folder, the
watcher that reindexes on save, the read tool — `hybrid` simply *is* a
backend, because it answers the same methods. So the whole indexing
pipeline from the last chapter is reused byte-for-byte: one walk of the
folder, one text extraction per file, one content hash. Nothing
re-reads your files to build the keyword half.

And because both stores hold the same chunks, with the same ids and the
same `source` citations, fusion is textbook: both legs return the same
identifiers, so matching them up is a hash lookup rather than a
heuristic.

Two things fall out of that split worth noticing. A third index — a
graph store, a second keyword engine — is a third store handed to
`Hybrid`, not another wrapper around it. And the keyword store is
useful alone: a corpus with no embedder at all can be indexed into an
`Fts5` and searched by word, which is also why it can be tested without
a vector backend anywhere in sight.

The alternative — a `Rag::Indexer` that wraps SQLite plus the vectordb
indexer — was the larger cut and got rejected. It would re-read and
re-extract every file, and it would have to merge two "what's indexed?"
manifests. `DECISIONS.md` `D_rag_gem` has the full comparison.

### "Indexed" means both stores hold it

Two of `Hybrid`'s methods don't simply delegate, and the reason is a
correctness invariant rather than tidiness.

Picture the failure it prevents. You run with Qdrant, so your vectors
persist across restarts. Your keyword index defaults to in-memory, so
it doesn't. You restart. The vector store says "I have 4,000 chunks,
nothing to do"; the keyword index is empty; `rag_find` returns nothing
for every query, forever, and never says why.

So `Hybrid` answers "what is indexed?" with the **intersection** of the
two stores' manifests, and a chunk count of `0` when *either* store is
empty. Now the restart goes differently — the watcher's boot sweep sees those 4,000
chunks' sources as unindexed, and reindexes them into both stores.
Slower, and correct.

The same rule quietly repairs a half-written pair. If a write lands in
the keyword index and the vector store's network call then fails, that
source drops out of the intersection and the next sweep fixes it.
Nothing has to be transactional across two stores.

It's also why the pairing guidance is guidance and not a check: pair
in-memory with in-memory, and a file under the pikuri cache with
Qdrant. Get it wrong and you're *correct*, just paying a full re-embed
at every boot — and nothing in `Hybrid` can tell whether the vector
store you handed it persists.

### Model text never reaches the query language

SQLite's `MATCH` operator takes a small query language of its own:
`AND`, `OR`, `NOT`, `*` for prefixes, `^` for anchors, `column:`
filters, phrase quotes, `()` and `{}` for grouping. Hand it raw model
text and a stray quote is a *syntax error*, not a query that finds
nothing.

So every expression is built by one small module, which splits the
text into runs of letters and digits and emits each one as a quoted
phrase term. `acme OR initech` becomes `"acme" "or" "initech"` — three
literal words, one of which happens to be spelled "or". The operators
are never exposed, deliberately: "Acme *or* Initech" is two
`rag_find` calls, and the model doesn't get a query language to
misuse. If nothing survives the split — the model passed `???` — the
tool says "no searchable terms" and the database is never touched.

## The demo: a briefing from your own notes

```
./pikuri-rag/bin/pikuri-briefing --source ~/notes
```

Point it at a folder of meeting notes and ask it to brief you:

```
> brief me on Acme — what did we discuss last, and what did we commit to?
```

What it does, if the notes are there: lists every note mentioning
Acme, reads the recent ones in full, orders them by the date in the
filename, and gives you a timeline plus the open commitments — quoting
and citing each note so you can check it in one click.

### Name your notes so a date can be read off them

Chunks carry a `source` path and a content hash. They carry no dates.
So for the agent to answer "what did we discuss *last*", the date has
to live somewhere it can read — and the requirement is the
**filename**, not a folder structure:

```
~/notes/acme-2026-08-14.md
~/notes/acme-2026-07-02.md
~/notes/initech-2026-08-01.md
```

One flat folder is enough, because the `source` rides every search
hit and every listing. Name-before-date is the better order of the
two: in a flat folder it groups a customer's notes together for the
access pattern that dominates ("everything about Acme"), and the date
is just as readable off the string. `customers/acme/2026-08-14.md` is
one instance of the same idea, not the requirement — a convention that
asks you to reorganize your notes is a convention you won't adopt.

Why not the file's modification time? Because it would be wrong the
first time you `git clone` your notes onto a new machine. Why not a
date on the note's first line? It works, weakly: only the one chunk
containing that line carries it, so it survives a full read and not
necessarily a search hit.

### The one-legged agent

Print the trifecta map at boot — this binary does, unconditionally —
and you get something no other demo in this book has shown:

```
Trifecta: pikuri-briefing — 1 of 3 legs (private); no untrusted/egress leg found.

pikuri-briefing [:private]
  rag_search [:private]
  rag_find [:private]
  rag_read [:private]
  rag_reindex []
```

**One leg.** Private data, unambiguously — every note is a record of a
customer relationship. Untrusted input: no, because you wrote every
byte. Egress: no, because there is no web search, no page fetch, no
mail, no shell.

And a private leg *alone is inert*. Private data with no exit and no
untrusted input is a personal tool, not an attack surface. No
confirmer, no sandbox, no gate — "start slowly" in its purest form,
and the [detector chapter](trifecta-detector.md) explains why the map
stays quiet rather than warning you about the one leg it found.

Two details in that map are worth naming, because both were choices.

**The declarations are hardcoded, not flags.** `bin/pikuri-corpus`
takes `--private` / `--trusted` as flags with pessimistic defaults,
because its default corpus is the *public* pikuri book — pessimism is
honest there. `pikuri-briefing` has no honest non-private reading, so
a flag would make the documented invocation the flagged one and the
true map opt-in. A forgotten flag would fail *silent*, and per the
detector chapter, an agent that prints the wrong leg teaches its
operator to stop reading the map.

**And the binary says the claim out loud**, in one line beside the
map:

```
Indexing /home/you/notes as PRIVATE and TRUSTED — that means: you reviewed every note in the
  form the model reads it, nobody else writes into that folder, and the index holds
  nothing but what that folder put there. Paste nothing from a customer; paraphrase.
```

Because `trusted: true` is a claim about a folder *you* supplied
through `--source`, and it is one paste away from false. The moment
you paste a customer's e-mail into a note, that folder holds text
somebody else wrote — indexed within seconds by the watcher, and
retrieved as *vouched* content from then on. Nothing can detect it.
The three clauses behind that flag are the vector-DB chapter's
["Why this agent can't leak your corpus"](vectordb.md#why-this-agent-cant-leak-your-corpus)
and `Extension#trusted?`'s yardoc; the one-line rule is: **the trusted
corpus holds only what you typed or reviewed as text.**

### Local inference is this agent's first invariant

The trifecta model does not count the inference provider as egress.
A user who says "these notes stay on my machine" does — and they're
the ones who are right about their own threat model.

Point this binary at a hosted model and every customer note ships to
that provider by design. The one-legged story becomes false at the
transport level, and no amount of tool wiring fixes it. So local
inference here is not a preference or a default worth overriding; it's
the first invariant, and the binary's header says so. There's nothing
to build — `Agent::ChatTransport` already makes the connection a
wiring choice — but it's the kind of thing worth writing down before
someone "just tries it with a bigger model".

### Which gem *not* to wire

Two absences are deliberate, and the reasons are more interesting than
the wiring.

**No memory gem.** The notes folder *is* the durable memory here:
human-written, human-curated, already distilled. Auto-extracting
memories from it would summarize a summary. If you want to remember
something, you write a note. (This is the only place in the book where
the answer to "should I add `pikuri-memory`?" is a flat no.)

**No write tool.** Not because writing is dangerous in general, but
because of what it would become. Suppose you later add read-only mail
to this agent — the natural next step, and one this book's
[OS-assistant chapter](os-assistant.md) already explores in a
different shape. Now an agent that reads untrusted mail can write into
the folder your whole setup declares *trusted*. A hostile e-mail's
content lands in a note, the watcher indexes it within seconds, and it
is retrieved as vouched content from then on — surviving into sessions
with no mail wired at all. A corrupted brief bounded to one
conversation becomes durable corpus poisoning, and **the detector says
nothing**, because `write` carries no trifecta leg at all. That one
needed reasoning rather than the map.

Which is also the honest trade to record about mail: the
hand-curation you already do — reading correspondence, deciding what
matters, writing it down in your own words — *is* the human-author
step that makes `trusted: true` true. Adding mail access automates
away the step that made the agent one-legged. That's a real feature
with a real cost, not a free upgrade.

## The watcher is on by default here

`bin/pikuri-corpus` makes you ask the agent to index the corpus,
because watching the manual reindex happen is half that chapter's
lesson. This binary inverts it and watches by default.

The reason is what a stale index does to a *brief*. A note you wrote
this morning and that the index hasn't seen is a silent hole in a
timeline. The read tool's membership gate does catch it — it refuses a
path it never indexed and tells you to reindex, which is loud and
actionable — but it's a baffling answer about a note that plainly
exists on disk. So the index stays live, and `--no-watch` is there if
you'd rather it didn't.

## What's next

You now have both halves of corpus retrieval: the vector primitive and
the hybrid system on top of it. The next chapter —
[memories](memories.md) — is the other kind of recall entirely: facts
the agent extracted from your conversations and kept, rather than
documents you handed it. It's also where the privacy posture gets
sharper, because a memory store is private data *by definition*.

→ Continue to [Memories](memories.md).
