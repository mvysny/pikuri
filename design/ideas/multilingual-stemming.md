# Multilingual stemming for `pikuri-rag`, Finnish first

`pikuri-rag`'s keyword half stems English only (FTS5's built-in `porter`,
`Backend::Fts5::SCHEMA`). `D_rag_gem` deferred other languages with the seam
already named: a `stemmer:` duck on the extension, never a `languages:` array.
This file is that deferral picked up, with Finnish as the first language.

## Decided so far

- **The `stemmer:` seam.** Stemming happens in Ruby, before FTS5 sees the text
  and on the query, so the database stays a plain FTS5 table and the stemmer is
  swappable without touching SQL.
- **Voikko first** (`libvoikko1` + `voikko-fi`, both in Ubuntu main). It
  analyses words rather than stripping suffixes, so it gives the dictionary
  form: *kadulla* / *kadun* / *katu* → *katu*, where Snowball's suffix
  stripper misses the consonant change. There is no `hunspell-fi` in the
  distro: Finnish morphology does not fit Hunspell's affix model, which is why
  LibreOffice spellchecks Finnish through Voikko.
- **`ruby-voikko` is its own gem, outside this monorepo.** FFI to the distro
  `libvoikko1` (`ffi` is already in the lockfile), with a generic API, e.g.
  `Voikko.new('fi').analyze(word)` → the analyses as hashes, plus a
  `base_forms(word)` convenience method. It knows nothing about pikuri, so its
  own AGENTS.md stays about Voikko.
- **Later languages fit the same duck.** Hunspell (`ffi-hunspell`, distro
  dictionaries) for Slovak / Czech, which Snowball lacks; Snowball
  (`libstemmer0d` is in the distro) as the fallback for languages with no good
  dictionary; `trigram` stays the fallback of last resort, as `D_rag_gem`
  says.

## The seam

A duck, so a lambda or a `ruby-voikko` adapter both qualify:

- `#stems(word)` → `Array<String>`: every form to index under, lower-cased,
  never empty (an unknown word answers itself). Several forms is normal: Voikko
  returns one analysis per reading of an ambiguous word, and the index takes
  their union, which is the "run every stemmer, index the union" shape
  `D_rag_gem` sketched.
- `#id` → `String`: names the stemmer and its configuration, e.g.
  `"voikko-fi+identity"`. It is written into the index, see `Q_stemmer_change`.

The default is the identity stemmer (`[word]`). With porter kept in the
tokenizer (`Q_keep_porter`) that is exactly today's behaviour.

## Where it plugs in

**Index side: `Fts5#insert`.**
- Add a `stems` column: the chunk's tokens (via `Query.tokenize`, so index and
  query split words the same way), each run through `#stems`, joined by
  spaces.
- `text` becomes `UNINDEXED` payload, still what a hit returns to the model.
- Cost: the stems column is stored beside the text, roughly doubling the FTS
  file.

**Query side: `Rag::Query`.**
- `any` ORs every stem of every word.
- `terms` returns one group per word, `("katu" OR "kadu")`. `Fts5#find` keeps
  running one query per group and intersecting by document, so the
  per-document AND is unchanged.
- Each stem is still a quoted phrase term, so the invariant "model text never
  reaches `MATCH`" holds without change.

**Wiring: `Rag::Extension.new(stemmer:)`** passes the stemmer on to
`Backend::Fts5.new` and to `Tools::Search` / `Tools::Find`.

## Open questions

- **`Q_keep_porter`:** keep `tokenize='porter unicode61'` and run porter over
  the stems column too? Lean **yes**:
  - English in a mixed corpus keeps working with no English stemmer in Ruby.
    Voikko does not know an English word, answers the surface form, and porter
    stems it as today.
  - Porter runs on both sides, so a Finnish base form it mangles is mangled
    identically in the query.
  - The risk is two distinct Finnish lemmas colliding after porter. That needs
    measuring on a real corpus, not guessing.
- **`Q_stemmer_change`:** an index built with one stemmer and queried with
  another quietly returns nothing. Store `#id` (and a schema version, since the
  `stems` column already invalidates every existing index) in a one-row meta
  table. On a mismatch, should it raise (errors are loud) or rebuild
  automatically? Lean **raise**, with a message naming `rag_reindex` and the
  two ids.
- **`Q_compounds`:** Voikko's `WORDBASES` attribute splits *tietokone* into
  *tieto* + *kone*. Indexing the parts too lets "kone" find "tietokone", which
  is a large part of Finnish recall. It also inflates bm25 document lengths
  and makes `rag_find` "every note mentioning kone" broader than the literal
  word. Probably yes, but as an option of the Voikko adapter, not of the seam.
- **`Q_unknown_word`:** Voikko has no analysis for names, neologisms or typos.
  Should it answer the surface form (the default above) or also Snowball
  Finnish's stem? The second improves recall on inflected names (*Nokian*)
  but adds a second dependency for the first language.
- **`Q_voikko_threads`:** a `Watcher` thread indexes while agent threads
  query. Verify whether a libvoikko handle is thread-safe; if not, the adapter
  holds a `Monitor` (`P_shared_locked`, like `Fts5`).
- **`Q_cache`:** word frequency is Zipfian, so a bounded `word → stems` cache
  should cut analysis calls by orders of magnitude during a full index. Measure
  before adding one.
- **`Q_adapter_home`:** where does the `ruby-voikko` → duck adapter live?
  - Not a new gem: it has no novel threat model and is a few lines.
  - `pikuri-rag` should not depend on `ruby-voikko` and, through it, on a
    native library.
  - Lean: the host (`bin/pikuri-briefing`, or a production binary) builds it,
    with `ruby-voikko`'s README showing the three-line adapter.
- **`Q_license`:** check the licences of `libvoikko` and `voikko-fi` before
  publishing `ruby-voikko`, and pick the gem's licence to match.

## Alternative kept open: a stemming container

A long-running container speaking JSON over stdio (`{"words": [...]}` in,
`{"stems": {...}}` out), wrapping Voikko, Hunspell and Snowball behind one
protocol. It would be one more implementation of the same duck: a
`Stemmer::Stdio` client.

Pros:
- Nothing native on the host.
- Every dictionary is provisioned in one image, so a new language means
  rebuilding the image rather than installing packages on each machine.
- The parsers run `--network=none --read-only`, like `pikuri-extractors`.

Cons:
- Docker becomes a dependency of plain keyword search.
- Process lifecycle: spawned through `Subprocess.spawn`, torn down through
  `Finalizers`, restarted after a crash.
- A protocol and an image to build and maintain.
- A per-query round trip, which is small once the container is warm.

**`Q_container_trigger`:** build it only when provisioning dictionaries across
machines starts to hurt, or the in-process trust call below is revisited.

### The trust call: in-process for now

The supply-chain worry is low: Voikko, Hunspell and Snowball are old,
widely packaged, and come from the distro. The real exposure is different. A
stemmer is C code fed **untrusted text**: every corpus word, every query word
the model writes. A memory-safety bug there runs with the whole Ruby
process's reach, outside the trifecta map, which counts tool legs and not
native code.

Two reasons that is acceptable today:
- **The input is tiny and uniform.** A stemmer sees one word at a time. That
  is a much smaller attack surface than the office/PDF parsers
  `pikuri-extractors` isolates, which take whole files in complex formats.
- **The process already parses the same corpus in C.** SQLite's FTS5
  tokenizer reads every word, in-process, today.

So the container is about convenience, not a security requirement. The
security argument would change if a stemmer ever took more than a word, e.g.
a whole-sentence analyser.
