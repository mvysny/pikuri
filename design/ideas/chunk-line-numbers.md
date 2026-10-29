# Search hits carry their line range — "[1] handbook.md lines 1210-1248"

Status: **open, decided enough to implement.** A corpus of long documents (a 1500-line Markdown
manual, a statute, a PDF contract) is searched with `rag_search` / `rag_find` /
`vectordb_search`, and then the agent wants the *surroundings* of a hit: the whole section, not
one snippet followed by an answer from training data. That needs to know *where in the
document* a hit is. Today a hit is only `source (score=…)` + snippet.

The workaround this rejects: one file per section, only so the path can stand in for a
position. Splitting files to work around the retrieval layer is the wrong way round, and every
multi-page document has the same need.

## What's already there

- `rag_read` / `vectordb_read` / workspace `read` already page by line (`offset:` / `limit:`,
  1-based, through `FileType.read_as_text_paged`), so a line range is directly followable today.
- **The index and the readers see the same lines, by construction.** The `Indexer` chunks
  `FileType.read_as_text`; the readers page `FileType.read_as_text_paged`. Both route through
  the one `Extractor` registry, and for every extractor the two agree line for line:
  - passthrough: `extract` is the raw string, `extract_lines` is `each_line.chomp`; counting
    `"\n"` gives the same lines either way;
  - pikuri-pdf: `extract` *is* `extract_lines.to_a.join("\n")`, so the two cannot drift;
  - HTML and the pikuri-extractors docker arm (no `extract_lines`): `extract_paged` runs
    `extract(io).split("\n")`, the very string the `Indexer` chunks.
- Qdrant and Chroma store `Chunk#metadata` generically as payload, so a new key rides along.
- `Rag::Backend::Fts5` has `SCHEMA_VERSION` and rebuilds an index built with another one, so a
  new column costs a bump, not a migration.

## What's missing

- **The chunker protocol drops positions.** `#chunk(text)` → `Array<String>`, and
  `Chunker::FixedWindow` splits on whitespace and re-joins with `' '`, so the line structure is
  gone before the `Indexer` composes a `Chunk`.
- **`metadata[:offset]` is the chunk's ordinal**, not a position — and `offset` already means
  "line" in the readers' `offset:`, one step apart in the same workflow.
- **`Fts5` keeps only `hash`** of the metadata (columns `id, source, hash, text, stems`). A
  fused `rag_search` winner can come from the keyword leg alone (`Rag::Tools::Search.fuse` keeps
  the first leg's `Result` per id, so a keyword-only hit carries FTS5's `{hash:}`), so without
  columns it would come back with no line — the two legs must agree.
- **Persisted vector indexes never pick it up.** FTS5 rebuilds on the schema bump; Qdrant and
  Chroma have no such marker, and `Indexer#reconcile_plan` diffs raw *file bytes*, so an
  unchanged corpus keeps its line-less chunks in the vector leg forever.
- **Nothing prints it.** `VectorDb::Tools::Search.format_observation` shows source, score,
  snippet. `Chunk`'s yardoc says metadata is "surfaced to the LLM when present" — it isn't;
  that drift is worth fixing on its own.
- **`vectordb_read` renders unnumbered** (`Result.page(..., numbered: false)`), its yardoc
  reasoning "the citation unit is the `source`". This idea makes that false.

## The line spec (normative — lands in the `Extractor` yardoc)

The numbers are consumed by an LLM *and*, through the library API, by programs. A silent
off-by-some mismatch is the worst kind of bug here: the agent reads the wrong passage, answers
confidently from it, and nothing errors. So the definition is written down once, in the
`Extractor` protocol's yardoc (the owner of line *production*), and `Chunk`, the `Indexer`,
`Extractor::Page` and the tool descriptions link to it rather than restate it:

- **1-based, both ends inclusive.** Same as the readers' `offset:` (`vectordb_read` already
  rejects `< 1`), `grep -n`, `sed -n`, `cat -n` and every editor.
- **LF (`"\n"`) is the only line terminator.** In CRLF the CR is part of the line's content,
  so CRLF and LF files number identically. A lone CR (classic Mac) is **not** a terminator.
  Line N is the text after the (N−1)th `"\n"`. This is what `Passthrough.extract_lines`'
  `each_line` already does — the spec documents current behaviour, it does not change it.
- **Lines of the *extracted* text, not of the file's bytes.** For passthrough formats (plain
  text, Markdown, source code) the two coincide, and a program may count lines in the file
  itself. For PDF / office / HTML the numbers point into the extractor's output,
  `--- Page N ---` markers included; a program reproduces them only by running the same
  extractor. The spec promises file-line equivalence for passthrough only.
- **Readers that agree:** Ruby `each_line`, `grep -n`, `sed`, `awk`, `wc -l`, JS
  `split('\n')`. **Readers that disagree** — they also split on a lone CR, and the first on
  `\x0b`, `\x0c`, `\x1c`-`\x1e`, `\x85`, ` `, ` ` too: Python `str.splitlines()`,
  Python's text-mode `open()` (universal newlines), Java `BufferedReader.readLine()` /
  `Files.readAllLines()`. The yardoc names them, because a host program written against one of
  them is exactly how this goes wrong two years later on a file pasted from Word.

**Compatible tools, named explicitly.** A range from `rag_search` / `rag_find` /
`vectordb_search` is a valid `offset:` for exactly these readers, because they page the same
`FileType.read_as_text_paged` over the same `Extractor` registry:

- `rag_read` and `vectordb_read` (`VectorDb::Tools::Read`) — the intended follow-up, same
  corpus root, same `source` path;
- workspace `read` (`Workspace::Read`) — when the corpus also lies inside the workspace (path
  resolved from the workspace root rather than the corpus root).

Not `fileindex_read` (pikuri-os) or `mail_attachment_read` (pikuri-thunderbird): same renderer,
but different documents, so a corpus range means nothing to them.

## Proposal

- **`FixedWindow` returns verbatim slices with their position.** It records each window's
  first- and last-word character offsets and returns `text[start...end]` verbatim; then
  `first_line = text[0...start].count("\n") + 1` and likewise `last_line` from `end`. No per-word
  line bookkeeping, and the snippet keeps the document's line breaks where the `' '` join
  flattened them. The chunk text changes, so embeddings shift slightly — covered by the reindex
  the change needs anyway.
- **The chunker protocol changes** (pre-1.0, break freely): `#chunk(text)` →
  `Array<Chunker::Piece>`, `Piece = Data.define(:text, :first_line, :last_line)`. No
  String-or-Piece dual acceptance in the `Indexer`.
- **Two scalar metadata keys, `first_line:` / `last_line:`**, not `lines: [a, b]` — Chroma
  has historically accepted only str/int/float/bool metadata values, and two scalars mirror the
  FTS5 column pair, so both legs build `Chunk`s the same way. `metadata[:offset]` is renamed
  `:ordinal` while in there.
- **`Fts5` gains `first_line` / `last_line` columns** (`UNINDEXED`), `SCHEMA_VERSION` 3.
- **Search output:** `rag_search` / `vectordb_search` print
  `[1] handbook.md lines 1210-1248 (score=0.03)`. A hit with no line metadata (a vector index
  built before this change) prints the old shape — never raises, never `lines -`.
- **`rag_find`** lists, per document, the first line of each matching chunk, capped (~5, then
  `…`): `handbook.md — 3 chunks (lines 412, 1210, 1388), 52.1 KB`. `Fts5#find`'s `COUNT` gains
  an ordered `group_concat(first_line)`.
- **Tool descriptions** say the ranges are `offset:` values for the read tool of the same
  family (`rag_search` → `rag_read`, `vectordb_search` → `vectordb_read`) and link the spec
  rather than restate it.
- **`vectordb_read` / `rag_read` render numbered** (`numbered: true`), so the agent sees in the
  page the same numbers the search printed — ~7 chars a line. Its yardoc's "citation unit is
  the `source`" sentence goes.
- **CHANGELOG:** one sentence — run `vectordb_reindex` / `rag_reindex` to get line ranges on an
  existing Qdrant/Chroma index.
- **`Chunk` yardoc:** names which metadata keys surface to the LLM (the line range), instead
  of "when present" — `hash:` and `ordinal:` never do.
- **One consistency spec** pins the whole promise: index a fixture with CRLF lines, a lone CR,
  blank lines and a long paragraph; for every stored chunk, assert that
  `vectordb_read(offset: first_line)` begins with the chunk's first word and that line
  `last_line` holds its last word.

**Start *and* end, not just start.** Same plumbing, one more integer. A 512-token window
(plus overlap) can start at the tail of one section and carry the actual match into the next;
with the start line alone a "section containing line N" reader would hand over the wrong
section. With both, it reads every section the range touches — almost always one.

## Structured access is the library API, not tool output

`Tool#execute` answers a `Tool::Result` — `content` (text for the model), `summary`,
`attachments` — and that stays so ("One tool return type"): tools are for LLMs. A program that
wants positions calls the backend / the search legs directly and reads
`result.chunk.metadata[:first_line]` / `[:last_line]`; the printed `lines 1210-1248` is
presentation for the model and never an API to parse. A host that wants its own model-facing
behaviour (say, "give me the section around this hit") writes its own tool over that API.

## Out of scope here

- **A section reader.** `rag_read(source, around_line:, heading_level:)` returning the
  enclosing Markdown section could come later, once more than one consumer wants it; until
  then it is a host tool over the library API above.
- **A heading-aware chunker** (`vectordb-deferrals.md`, "Per-doc-type chunkers") would use the
  same metadata channel for `heading: "Chapter 7 > § 3"`; this idea only opens the channel.
- **Structured tool output** — rejected above; tools return text.

## Decided

- `Q_line_basis` — the index and the readers agree for every extractor today (see "What's
  already there"); the line definition is LF-only, 1-based, inclusive, over extracted text,
  and is *documented* with the disagreeing readers named.
- `Q_protocol_compat` — the chunker protocol simply changes; no dual acceptance.
- `Q_overlap_lines` — print ranges as they are. A range states what the chunk covers;
  trimming the overlap would claim the match is not in the overlapping part, which may be false.
