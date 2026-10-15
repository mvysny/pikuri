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
  stripper gives *kadu* / *kadu* / *katu*. There is no `hunspell-fi` in the
  distro: Finnish morphology does not fit Hunspell's affix model, which is why
  LibreOffice spellchecks Finnish through Voikko.
- **The binding is the `voikko` gem**, released 0.1.0 from its own repo
  (`github.com/mvysny/ruby-voikko`), outside this monorepo. FFI to the distro's
  `libvoikko.so.1`; `ffi ~> 1.17` and Ruby `>= 3.3` match this lockfile and
  floor. It knows nothing about pikuri. What it gives the adapter:
  - `Voikko.new(language: 'fi')`, or `Voikko.open` with a block; `#close`.
  - `#analyze(word)` → `Array<Voikko::Analysis>`, one per reading, `[]` for an
    unknown word, an empty one or one over 255 bytes. Readers per libvoikko
    key: `base_form`, `structure`, `word_bases`, …
  - `#base_forms(word)` → the distinct base forms, **in the dictionary's case**
    (*HELSINGISSÄ* → *Helsinki*): downcasing is the adapter's job.
  - Raises `ArgumentError` on a NUL byte or invalid UTF-8, which
    `Query.tokenize`'s `[\p{L}\p{N}]+` can never produce, so the adapter
    rescues nothing.
  - No Unicode normalisation: an NFD word gets `[]`.
- **Later languages fit the same duck.** Hunspell (`ffi-hunspell`, distro
  dictionaries) for Slovak / Czech, which Snowball lacks; Snowball
  (`libstemmer0d` is in the distro) as the fallback for languages with no good
  dictionary; `trigram` stays the fallback of last resort, as `D_rag_gem`
  says.
- **Keep porter in the tokenizer** (`tokenize='porter unicode61'`), and run it
  over the stems column too:
  - English in a mixed corpus keeps working with no English stemmer in Ruby.
    Voikko does not know an English word, answers the surface form, and porter
    stems it as today.
  - Porter runs on both sides, so a Finnish base form it mangles is mangled
    identically in the query.
  - Distinct lemmas rarely collide: 4 groups in 2 278, one of them a real
    false match (see Measured). Re-check on a real corpus once it ships.
- **The adapter is `Pikuri::Rag::Stemmer::Voikko`, in `pikuri-rag`**, taking an
  open handle by injection: `Stemmer::Voikko.new(Voikko.new(language: 'fi'))`.
  Lowercasing, the unknown-word fallback and the compound split make it
  stemming *policy* that wants yardoc and specs, so it does not belong in a
  `bin/` script. It has no novel threat model, so it is not a new gem either.
  - `pikuri-rag` neither requires nor depends on `voikko`; only the host does.
  - Zeitwerk eager-loading never touches the native library.
  - The adapter only calls `#analyze` and reads `#base_form` / `#structure`,
    so its specs use a fake handle and CI needs no libvoikko.
- **An unknown word answers its surface form only**, with no Snowball stem as
  well. Snowball is erratic on exactly these words: *nokian* / *nokialla* →
  *nokia*, but *nokia* → *nok*; *bluetoothin* stays as it is, while
  *bluetoothia* → *bluetooth*. Unioned with the surface form on both sides it
  would still catch *Nokian* ↔ *Nokia*, but it would add a second native
  dependency for the first language. Revisit with a real corpus.
- **Compound parts are split by `STRUCTURE`, not `WORDBASES`**, as an option of
  the Voikko adapter, not of the seam, **on by default**. Indexing the parts
  lets "kone" find "tietokone", which is a large part of Finnish recall, and
  recall is the point. The cost: longer bm25 document lengths, and a
  `rag_find` ("every note mentioning kone") broader than the literal word.
  Measure the ranking cost on a real corpus once it ships.
  - `WORDBASES` gives each part's *root*, so derivations go back to verbs:
    *yritys* → *yrittää* + `+ys`. It also drops parts:
    *versionhallintajärjestelmää* lists *versio*, *hallita*, *järjestelmä*
    (no *hallinta*), and *kahdeksankymmentä* lists only *kahdeksan* (the
    format is in the gem's
    [research](https://github.com/mvysny/ruby-voikko/blob/master/design/research.md)).
  - `STRUCTURE`'s `=` marks each morpheme start, one character per character
    of the *surface* word. Cut the surface word there, then `base_forms` each
    piece again: *yrityskirjautumisen* → *yritys* + *kirjautua*;
    *versionhallintajärjestelmää* → *versio* + *hallinta* + *järjestelmä*;
    *kahdeksankymmentä* → *kahdeksan* + *kymmenen*; *tietokoneella* → *tieto*
    + *kone*. That costs one extra analysis per part.
  - The cutting itself is requested from the gem
    ([ruby-voikko#1](https://github.com/mvysny/ruby-voikko/issues/1)), since
    it decodes libvoikko's own format; until it ships, the adapter cuts.
  - A bound prefix that does not analyse alone (*esi* in *esikäsittelin*)
    falls back to its surface form, like any unknown word.
- **A stemmer change raises in v1 and rebuilds in v2.** An index built with
  one stemmer and queried with another quietly returns nothing. So the index
  stores `#id` in a one-row meta table, with a schema version, since the
  `stems` column already invalidates every existing index.
  - v1: on a mismatch, raise, since errors are loud. The message names
    `rag_reindex` and both ids.
  - v2: rebuild automatically.
  - A `voikko-fi` upgrade is not a mismatch: it changes a few words' analyses,
    not the whole index, and libvoikko exposes no dictionary version to put in
    the id anyway.

## Resolved by the gem's release

- **Threads (was `Q_voikko_threads`).** A libvoikko handle silently returns
  wrong analyses when two threads share it, so the gem puts every call under
  the handle's own mutex ([its decisions](https://github.com/mvysny/ruby-voikko/blob/master/design/decisions.md)
  say why). The `Watcher` and agent
  threads can share one handle; the posture is `P_shared_locked` with the
  state owned by the `Voikko` instance, and the adapter adds no lock. At the
  throughput below, contention does not matter.
- **Licence (was `Q_license`).** The gem is MIT and ships no Voikko code or
  data. libvoikko (MPL 1.1 / GPL 2+ / LGPL 2.1+) and `voikko-fi` (GPL 2) come
  from the distro. MIT pikuri stays MIT as long as no pikuri gem depends on
  `voikko`, which the injected adapter above guarantees.
- **Cache (was `Q_cache`): not needed.** 41 000 distinct words/s, and 71 000
  tokens/s over running text. A million-token corpus is about 15 s uncached,
  far below the embedding cost the hybrid backend already pays per chunk.

## Measured

Corpus: the 28 Finnish gettext catalogs under `/usr/share/locale/fi/`. That
is 16 319 tokens and 4 943 distinct, run through `Query.tokenize`. It is UI
text, small, and heavy on country and language names, so treat the
percentages as rough. Versions: `voikko` 0.1.0, libvoikko 4.3.3, voikko-fi
2.5, 2026-10-14.

- **Unknown words:** 30% of the distinct alphabetic words. Mostly English UI
  words (*backend*, *drop*) and exotic names (*pataca*, *sasak*), but also
  real Finnish: *bluetoothin*, *esikäsittelintä*.
- **Ambiguity is mild.** 3 160 known words have one base form, 265 have two,
  9 have three or four (*tulosta* → tulostaa / tulonen / tulo / tulos). Mean
  1.08 base forms per word, so the union barely grows the index.
- **The index vocabulary shrinks:** 4 895 distinct surface words become 3 738
  index terms (base forms for known words, the surface form for unknown ones).
- **Porter over base forms:** it rewrites 742 of 2 278 base
  forms, identically on both sides. Only 4 groups of distinct lemmas collide:
  *tulos/tulo*, *peru/perus*, *jo/jos*, *suriname/surinam*. *tulos* (result)
  vs *tulo* (income) is the one real false match.
- **Compounds:** 18% of known words have at least two parts in some reading.

## The seam

A duck, so a lambda or a Voikko adapter both qualify:

- `#stems(word)` → `Array<String>`: every form to index under, lower-cased,
  never empty (an unknown word answers itself). Several forms is normal: Voikko
  returns one analysis per reading of an ambiguous word, and the index takes
  their union, which is the "run every stemmer, index the union" shape
  `D_rag_gem` sketched.
- `#id` → `String`: names the stemmer and its configuration, e.g.
  `"voikko-fi+identity"`. It is written into the index, so a stemmer change is caught (decided above).

The default is the identity stemmer (`[word]`). With porter kept in the
tokenizer that is exactly today's behaviour.

## Where it plugs in

**Tokenizing: `Rag::Query.tokenize`** NFC-normalises before it splits, since
Voikko does not normalise and NFD text (from macOS, some PDFs) would
otherwise go unanalysed. Index and query both tokenize here, so both sides
stay consistent.

**Index side: `Fts5#upsert`.**
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
  The `voikko` gem's input checks narrow it further: a NUL byte or invalid
  UTF-8 never reaches libvoikko, and libvoikko returns nothing for a word
  over 255 bytes.
- **The process already parses the same corpus in C.** SQLite's FTS5
  tokenizer reads every word, in-process, today.

So the container is about convenience, not a security requirement. The
security argument would change if a stemmer ever took more than a word, e.g.
a whole-sentence analyser.
