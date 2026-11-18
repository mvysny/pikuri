# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status: direction agreed with the owner (2026-11-17). Two decisions, deliberately separable:

- **A.** The secretary (and Puri, and any "Siri-shaped" assistant) searches your files through
  the desktop's own file index (GNOME localsearch, or recoll), instead of `pikuri-rag` over a
  self-built vector + FTS5 index.
- **B.** `pikuri-vectordb` and `pikuri-rag` move to pikuri-workshop, with their chapters.

**Done (2026-11-18): the gem.** `pikuri-fileindex` holds the file-index code that used to live
in the workshop's `pikuri-os`, plus host-named roots, the path check, readiness over the roots,
legs graded from the roots' declaration, and "that's all". Its design and threat model are in
`pikuri-fileindex/design/architecture.md`, its README and its yardoc. pikuri-os already uses it
(workshop `2d74e29`). **Puri doesn't yet**: it pins workshop `9c8c84d` and gets the tools
through `pikuri-os`.

**Left:** wire the secretary and briefing onto the gem, judge it by transcripts
(`Q_transcript_bar`), then B and the book. A can ship and be judged before B; until B, pikuri
carries both search stacks. B has the big cost: the book.

## Why

- **Puri already made this decision** (`puri:D_documents`, 2026-11-17): it searches through
  `fileindex_search`, for the reasons below. If the secretary stays on rag, the book's closing
  binary and the app it hands off to differ on the thing a reader notices first.
- **The GPU bill.** `D_secretary_wiring` measured the owner's `~/Documents` (11,685 files):
  minutes of silence, then hours of a Radeon 890M at 100%, with chat queued behind the
  embedder on the same llama-server. That is why the secretary defaults to Qdrant and makes
  podman a prerequisite of the book's last chapter. A regular user doesn't want to watch
  their GPU burn so that an assistant can look up an invoice.
- **Book 1 loses its container runtime and its second model.** After B, nothing in pikuri needs
  podman, bge-m3 or a reranker. The prerequisites shrink to Ruby, llama.cpp, a chat model and a
  desktop index. `D_gem_placement` says Qdrant is Docker's last job here.
- **Hostile office files are parsed in the desktop's sandbox, not ours.** See the gem's threat
  model. Puri's `D_extractors` already relies on this.
- **Office documents come free, with one package.** localsearch extracts text from `.docx`,
  `.odt` and spreadsheets, which fills the gap `D_secretary_wiring` declined to fill (the
  pure-Ruby `.docx` reader, rejected as a feature). On Ubuntu 26.04 those extractors ship
  separately, in `localsearch-extractor-office` (universe, only "Suggests"): without it they
  are found by name only (measured 2026-11-18). `.csv` is never content-indexed.
- **These assistants don't do deep research.** The secretary, Puri and Siri ask a few lookups
  per turn. Ornith and Qwen are fine at issuing a couple of keyword queries and rephrasing
  on a miss. Ranked semantic retrieval pays off for people for whom search quality *is* the
  product: those are the workshop's users.
- **Keyword recall is enough here**: the gem's architecture note ("File search: keyword recall,
  not embeddings") sorts misses into three causes, and only the third needs embeddings. Its
  ~100% recall is against a ripgrep oracle, not the secretary's questions; only transcripts can
  show that (`Q_transcript_bar`).
- **Completeness comes free.** `D_rag_gem` built `rag_search_keywords` because cosine search
  can't promise "every note mentioning Acme". `fileindex_search` says "all shown" or "10 of 37".
- **Fresh within a second.** A note saved into the demo `~/Documents/Notes` was searchable after
  0.43–0.54 s, and gone 0.42–0.44 s after deletion (3 tries, 2026-11-18). Rag needs the
  `Watcher` and an embedding round-trip for the same.
- **Placement.** `D_gem_placement` test 1 says rag's future is more features: see
  `rag-hit-presentation-eval.md`, `vectordb-deferrals.md`, and the stemmers already in
  `pikuri-workshop:pikuri-stemmers`. The secretary's reader would also skip two of pikuri's
  biggest gems (vectordb + rag ≈ 4,600 lines of `lib/`, against ≈ 1,000 for the file index).

## Supported platforms (owner, 2026-11-17)

- Ubuntu 26.04 LTS or newer, or any Linux with localsearch 3.8+, or recoll with a built index:
  stated in the gem's README. **Add `localsearch-extractor-office` on Ubuntu** (see Why), or
  the book's reader finds their `.docx` by name only.
- **Neither ready: the secretary prints why and exits 1.** No degraded mode with no search: a
  secretary that can't search would answer "you have no such file". It rescues
  `Fileindex::Unavailable` and prints its message; Puri shows it in its UI.
- **The book says it once**, in the prerequisites chapter; the recall chapter and the error
  message point there.

## The secretary

- Wire `Fileindex::Extension` in place of `Rag::Extension`. Drop Qdrant, podman, `--in-memory`,
  the `Watcher` and the "folders kept out of the index" prompt line. The index's coverage is
  now GNOME's Search settings (or recoll's `topdirs`) plus our roots.
- **Roots: Desktop and Documents** (owner, 2026-11-18; was `Q_default_roots`). Not Downloads:
  it fills with whatever a page pushed when the user clicked a link, so it's the easiest place
  for a stranger to plant a file the search then serves. A file on the Desktop or in Documents
  was put there on purpose. The verdict doesn't move: Documents still holds other people's
  files, so the roots stay `private: true, trusted: false`. The cost, a vendor's invoice
  never moved out of Downloads, is a miss the model can explain, since `fileindex_search`'s
  description lists the folders it searches. The list lives in the secretary, not the gem:
  every caller so far names its own roots (briefing `~/notes`, pikuri-os `/`), so a gem default
  would be a knob nobody sets. Resolve the folders with `xdg-user-dir DESKTOP` / `DOCUMENTS`
  (localized names), through `Subprocess.spawn`; AGENTS.md's "never read an `XDG_*` variable"
  is about pikuri's own paths, so add a clause there so the next agent doesn't flag it.
- **Two read tools: `read` and `fileindex_read`** (owner, 2026-11-18; was `Q_one_read_tool`),
  each described by what it's for. `read` stays for live files and for read-before-write on
  `Notes/`; a localsearch-backed `Extractor` entry would break "Attachments are bytes" (the
  registry turns bytes into text, not paths into text). Puri already runs with both.
- Notes it just wrote: findable within a second (see Why). Recoll has no daemon unless
  `recollindex -m` runs; state what recoll users lose.

## What moves to the workshop (B)

`pikuri-vectordb`, `pikuri-rag`, `bin/pikuri-corpus`, their chapters, `D_rag_gem`,
`D_rrf_tuning`, `D_chunk_line_ranges`, `D_ruby_stemming`, `D_corpus_trust_declaration`, and
the two idea files above. `pikuri-briefing` stays, rewired onto the file index (see
`Q_briefing`), so `D_briefing_*` are rewritten here rather than moved. AGENTS.md's Connection
and Request seams name `VectorDb::Embedder` and `Reranker::LlamaServer`; those clauses go to
the workshop. `pikuri-pdf`'s gemspec mentions the corpus. `D_gem_placement`'s rejected
alternatives cite rag twice ("a note the rag search finds covers most of a skill", and
`pikuri-vectordb` depending on `pikuri-subagents` as a reason `pikuri-workspace` can't move).

## Siri does the same: it borrows the OS's index (2026-11-17)

- WWDC26 (2026-06-08) Siri AI reaches personal context through the **Spotlight index**, on
  device, via a system orchestrator. That comes from secondary coverage of Apple's newsroom
  post. Siri doesn't own an index; it queries the OS's.
- Core Spotlight has had a *semantic* index since WWDC24 (session 10131): apps donate items,
  `title` / `textContent` "will be processed in the semantic index", and indexing is
  scheduled for idle time (device asleep). Apple hasn't published the embedding model or
  index format. "Local vector search" claims are secondary and unverified.
- So Puri on localsearch has Siri's architecture without the semantic half. GNOME's index is
  lexical, Apple's is semantic and built on the NPU while the device is idle. If GNOME ever
  gains a semantic index, the borrowing shape picks it up unchanged.
- For Puri's `design/research.md` at graduation, with the primary sources checked.

## Linux has no semantic desktop index yet (checked 2026-11-17)

- **GNOME localsearch: proposals only.** A GSoC 2026 proposal, "gnome-semsearch" (2026-03-31):
  MiniLM-L6 int8 (~22 MB) on the CPU via ONNX, sqlite-vec, results to the Shell over
  `SearchProvider2`. Carlos Garnacho, the localsearch/tinysparql maintainer, replied that
  wrapping sqlite-vec "through SPARQL extension points" is no big problem and that it belongs
  under the LocalSearch umbrella (file watches are scarce), but "code indexing … has been a
  established non-goal". No mentor had committed by the thread's last post (2026-04-08). A
  sibling community proposal on Ubuntu Discourse has the same shape (a localsearch extractor
  plugin, sqlite-vec keyed by tinysparql URNs) and no Canonical reply.
- **If it lands, it most likely lands inside tinysparql**, so `pikuri-fileindex`'s query is
  where it would show up: a new SPARQL function beside `fts:match`, with no change to our
  shape.
- **Ubuntu:** secondary sources say Canonical plans "smarter search" as an opt-in snap from
  26.10. Nothing primary found, and nothing on whether 26.10 shipped it.
- **KDE:** the 2026 goal "Make Plasma smart" (Baloo/KRunner scoring, background tagging) is
  intent, not code. digiKam has its own natural-language photo search: an app, not the
  desktop.
- **Recoll: experimental, in master.** Python scripts outside the core, ollama
  (`nomic-embed-text`) + chromadb, behind a `-Dsemantic=true` build flag. Its author: "orders
  of magnitude slower than the original indexing", reranking "has proven impossible" on his
  hardware, "rather primitive", useful "beyond litterary 'research'" remains to be seen. That
  is the same cost wall `D_secretary_wiring` measured.
- Everyone who tries hits the same cost. The proposals answer it with a tiny English-only
  CPU model, Apple with the NPU and indexing while the device is idle. For the book: "why
  Linux doesn't have this yet" is a good paragraph, with our own measurement as the evidence.

## The book

Outside `vectordb.md` and `rag.md`, retrieval carries two things: the trifecta chapter's worked
example (`pikuri-briefing` vs `--with-mail`, one flag adds a leg without moving the verdict) and
the secretary chapter, written as a diff against briefing with mail. Both survive if briefing
searches the file index, as long as legs come from the roots' declaration: `~/notes` is
trusted, Documents is not. The book's spine is the trifecta; the recall section exists to give
it private data worth protecting.

**Agreed** (owner, 2026-11-17): teach RAG on the desktop index; vectors go to book 2. RAG is
retrieve-then-generate, and agentic RAG is the model issuing the queries: no vectors needed.
`rag.md`'s completeness vs. ranking and exactness arguments survive, because a keyword index is
what it argues you need anyway. New lessons: borrowing an index vs. building one (who keeps it
fresh, who pays), the folder limit as a security boundary, bound parameters vs. splicing (SQL
injection's cousin), and whose parser touches a hostile file. Lost to book 2: embeddings,
chunking, cosine, the reranker, rank fusion. The recall chapter starts from the index the
desktop already keeps, looks at what it misses, sorts the misses into the three causes, and
shows that only the third needs book 2's vectors. The prerequisites chapter loses containers,
which it says "first earn their keep" in the vector-DB chapter, and gains the supported
platforms above.

Rejected: keeping vectors and ending the book on a different persona (a researcher over a
library of papers): every reader pays the GPU bill and podman for a persona they won't run day
to day, and Puri diverges from the closing binary. Keeping vectors in the book with the
secretary on the file index: the recall chapters build something the last binary never uses.

## Costs

- **The book.** It now goes vectordb → rag → briefing → secretary. Embeddings, chunking and
  rank fusion are concepts, not only features. After B, pikuri teaches search as "an agent
  using the desktop's index", and the retrieval chapters move to the workshop's book. The
  biggest rewrite involved.
- **Platform.** pikuri is Linux-first, not GNOME-first: recoll covers KDE, Xfce and headless
  boxes, but only with an index the user built. Readers on Ubuntu 24.04 LTS or older Tracker 3
  are out (see Supported platforms).
- **Coverage is the desktop's to decide.** Our roots narrow; they can't add a folder GNOME
  skips, nor a format it doesn't extract (`.csv`; office files without the extra package).
- **Code and git checkouts are invisible** to localsearch. That's fine for a secretary, and
  it's the reason the coding agent keeps `grep`.
- **Cross-language search is lost.** bge-m3 matched an English query to a Finnish document; a
  keyword index needs the query in the document's language (and `pikuri-stemmers` ships
  Voikko, so the owner's files likely include Finnish). Check which language localsearch stems
  in (likely one, taken from the locale). The eval's Finnish question measures whether the
  agent searches again in the other language (`Q_transcript_bar`).

## Open questions

- `Q_book_retrieval`: **resolved** (owner, 2026-11-17). The recall chapter states the keyword
  index's limits, then points at semantic search, vector databases, chunking and rank fusion
  in pikuri-workshop, linking its book (its README until B moves `vectordb.md` and `rag.md`
  there, then that chapter). No embeddings walkthrough in pikuri. The limits are named by the
  three causes, so the reader sees that vectors fix only the third (a real meaning gap:
  another language, a concept in other words), not unindexed content or a wording miss the
  agent fixes by rephrasing. The GPU measurement says why pikuri doesn't build its own.
- `Q_briefing`: **resolved** (owner, 2026-11-17): rewire `pikuri-briefing` onto the file
  index, root `~/notes` declared private and trusted, and keep it. Checked against the book:
  - Survives unchanged: the trifecta chapter's "One flag, one extra leg, and the same
    verdict" (only the tool names in its two maps change); the hardcoded declarations and
    the boot line stating them; local inference as the first invariant; no automatic memory.
  - Gets better: the secretary's "same retrieval, plus mail" becomes literally the same gem
    with wider roots. The boot line's "the index holds nothing but what that folder put
    there" is false for a borrowed index that holds all of `$HOME`; the root filter is the
    only thing keeping a Downloads file from coming back as vouched, so the one-legged agent
    is where "the folder limit is a security boundary" has a visible cost if it fails.
    Reword the line to say so. The two recall chapters become one, with briefing as its demo
    (`pikuri-corpus` over the book goes to book 2 with `vectordb.md`). `D_briefing_wiring`'s
    `--watch` fork and `rag_read`'s membership gate go: the miner keeps the index fresh.
  - "Absence stopped being reportable the same way" (trifecta chapter) needs search to say
    "that's all": **met** by `fileindex_search`'s footer. Whether "list every note mentioning
    Acme" needs more than 25 is for the briefing transcripts.
  - **Requirement: the notes folder can't be a git checkout under localsearch**, which skips
    any tree holding `.git`. `rag.md` argues against mtime "because it would be wrong the
    first time you `git clone` your notes", the very setup that empties the index. The
    readiness check catches it (zero indexed files under the roots, so the binary exits),
    but the chapter must say it: no git for the notes, or recoll. Re-argue the mtime point
    with a plain copy to a new machine.
  - **Requirement: recoll freshness.** Without `recollindex -m`, this morning's note is
    missing from the brief: the silent gap `--watch` existed to close. The chapter tells
    recoll users to run the daemon or re-index before a brief. A boot warning when recoll's
    index is older than the newest file under the roots would be a feature; propose it as
    one only if transcripts show the gap.
  - Don't root briefing at the secretary's `Documents/Notes/`: the secretary writes there
    from turns that read mail (the stored injection `book/secretary.md` warns about), so
    "trusted" would be false. Briefing's folder stays one only the user writes into.
- `Q_all_matches`: does a 40-word snippet plus `fileindex_read`'s `pattern` cover "context
  around the matches"? See the brainstorm below.
- `Q_transcript_bar`: agreed (owner, 2026-11-18): ten lookup tasks on the demo home, ten runs
  each on Ornith, hit rate rag vs file index, including "write a note, then find it" and a
  cross-language question. Harness and results below.

## `Q_all_matches`: brainstorm (2026-11-18)

What each side shows per hit, from the code:

- **rag**: up to 5 hits, several may be windows of the same file. Each is a 512-token chunk
  shown as its **first 500 characters** (`VectorDb::Tools::Search::SNIPPET_LENGTH`), so the
  match may sit past the cut, plus the chunk's line range for `rag_read`.
- **fileindex**: up to 25 files, one hit each, a **40-word window centred on the match** with
  the matched words marked `>>like this<<`, plus the size of the file's indexed text.

So the owner's "40 words ≈ the vector's window" holds, and per hit the snippet is the more
targeted of the two: shorter, but around the match rather than at the chunk's start. What
fileindex lacks is a *second* match in the same file. `pattern` is meant for that.

Measured (2026-11-18, the demo home's index): localsearch keeps the PDF's line breaks (the
invoice is 12 lines; the 176 KB book is 2,181 lines, median 100 characters, longest 219), and
HTML comes back a line per paragraph. So a line grep is the right unit there; a
whole-document-on-one-line format would break it. `.docx`/`.odt` are unmeasured: this box lacks
`localsearch-extractor-office`.

Options:

- **A. As is**: the snippet locates; `fileindex_read(pattern:)` greps the file's indexed text
  for the lines; `offset` reads around one. A regex, not the index's stemmed words, so the
  model writes `notice|terminat` where the index matched "notice terminate". The description's
  example (`"total|amount due"`) teaches the alternation.
- **B. `context:` lines on `pattern`** (grep's `-C`): saves the `offset` round-trip per
  match. A feature; earn it only if transcripts over long files show `pattern` → `read`
  pairs eating turns.
- **C. Every match with its context, from `fts:offsets`**: the index's own match positions,
  so stemmed like the search. Its output looked wrong on LocalSearch 3.11 (`(null):17`
  three times for the invoice, no property names). Reject unless someone digs into that, and
  B covers the same need.
- **D. A stemmed find-in-file in Ruby**: a second matcher that disagrees with the index's
  tokenizer. Reject.

Leaning **A**, with B as the fallback. The demo home can't decide it: its files are a few
hundred characters, so the model reads them whole (see the eval's tool counts). The owner's
`~/Documents` would. When this resolves, the `fts:offsets` trap graduates as a why-not line on
`Read`'s pattern paragraph.

## `Q_transcript_bar`: the eval (2026-11-18)

`fileindex-replaces-rag/transcript-eval.rb` runs on the dev VM (the demo home in
`~/Documents`, its localsearch index, Ornith on the host's llama-server). Each run is a fresh
agent with the secretary's prompt, calculator and workspace tools (no grep), and one retrieval
stack: rag (in-memory hybrid index, bge-m3, reranker, a `Watcher`) or the file index (roots
`[~/Documents]`). No mail, no web: either would answer some tasks around the retrieval under
test. A run passes when the final answer matches every gold regex.

Tasks: `invoice` (amount + IBAN, PDF), `notice` (lease, "move out"), `flood` (insurance
deductible for "water damage", asked as a flood), `sauna` (HTML), `solar` (a note, "solar
array"), `office` (board-meeting PDF), `electricity` (`budget.csv`: not content-indexed by
localsearch), `dentist` ("dental" vs "dentist"), `finnish-rent` (asked in Finnish, the lease is
in English), `bike-lock` (a note saved 5 s before the question, its code drawn per run).

### Results (200 runs, 2026-11-18)

| | pass | mean time | mean calls | searches that found nothing |
|---|---|---|---|---|
| rag | 100/100 | 19 s | 2.1 | 9 / 118 |
| file index | 100/100 | 20 s | 2.9 | 71 / 140 |

Per task, calls (rag / file index): `electricity` 3.1 / 6.1, `finnish-rent` 2.4 / 4.3, every
other task within one call. `runs.jsonl` holds every transcript.

**The pass rate can't separate the arms on this home.** The workspace's boot snapshot puts the
top of `~/Documents` in the prompt, and with 13 files under `Housing/`, `Finance/`, … that is a
map: about a fifth of the runs in each arm never searched, and `sauna` was a direct `read` of
the file every time. The failures a real home would show come back as browsing instead.

**Half the file-index queries find nothing, because localsearch ANDs every word.** The model
writes rag-style queries, and one word the file lacks sinks the whole query: "dental
appointment" (the note says "Dentist … checkup"), "office relocation address" (the minutes say
"move the office"), "deductible flood water kitchen", "rent monthly rent due date" (the lease
says "due on the 5th day"). Two-word queries were empty 24 of 29 times, four or more words 22 of
35. Rag's semantic leg always returns five hits, so the same habit costs it nothing. The model
recovered every time by rephrasing or by browsing, but on a home where browsing doesn't work
that recovery is the whole question. `fileindex_search`'s description never says every word
must appear.

**Cross-language: one run in ten found the lease by search.** 7 of 10 file-index runs searched;
every query with a Finnish word in it came back empty, mixed ones too ("vuokra monthly rent
payment due"), because of the AND. Run 6 switched to "rent monthly due" and hit; the other nine
reached the lease by browsing `Housing/`. Rag's arm searched in 5 runs and ranked the lease
first every time, twice from an all-Finnish query ("kuukausivuokra vuokrasopimus maksupäivä"):
bge-m3 matching across languages, the one thing only embeddings do.

**Structural misses cost turns, as predicted.** `budget.csv` (not content-indexed): every
file-index search for it missed, and the model found it in the listing after 2 to 16 calls.
The missing office extractor cost 19 calls on `.odt`/`.docx` in the file-index arm (3 in rag's):
`fileindex_read` on `lease-agreement.odt` says "not in the index", `read` says binary, then the
`.pdf`.

**Freshness: no difference.** `bike-lock`, asked 5 s after the note was saved, passed 10/10 on
both (rag 1.3 calls in 14 s, the file index 2.1 calls in 11 s).

**`Q_all_matches` data:** 4 of 49 `fileindex_read` calls used `pattern`; the files are short
enough to read whole, as expected.

### Any-word matching (owner, 2026-11-18), re-measured

Of the 71 empty queries, 27 were the `.csv`, 28 had a word in the right file, and 16 had none
("dental appointment"; all-Finnish queries). localsearch has no OR at all (`fts:match` reads
`OR`, `NOT` and parentheses as words), and recoll has Google's. So rather than teach a syntax,
`fileindex_search` now matches any word, with files holding every word first and counted, and
quotes as a group of words that must all appear in any order (the gem's architecture note,
"Matching"). Built and re-run on the file-index arm (100 runs; rag's code didn't change):

| | pass | mean calls | searches that found nothing |
|---|---|---|---|
| rag | 100/100 | 2.05 | 9 / 118 (8%) |
| file index, every word | 100/100 | 2.91 | 71 / 140 (51%) |
| file index, any word | 100/100 | 2.23 | 21 / 107 (20%) |

Calls per task, every word → any word: `notice` 3.0 → 2.1, `office` 2.5 → 1.6, `electricity`
6.1 → 2.9, `dentist` 2.6 → 2.0, `invoice` 2.9 → 2.4, `flood` 2.5 → 2.1, `bike-lock` 2.1 → 1.8,
`finnish-rent` 4.3 → 4.3. Mean run time 21 s, as before.

What's left empty is what any-word can't fix: `electricity` 11 ("electricity October": the
`.csv` isn't content-indexed and no file says "October"), `finnish-rent` 9 (all-Finnish
queries, no word of them in the English lease), `dentist` 1 ("dental"). The model never quoted
and never wrote `OR` (0 of 107 queries); mean 3.4 words a query.

### What the bar needs next

1. **A home where browsing doesn't work**, so the pass rate measures search: the demo
   documents a few folders deep among a few hundred distractor files (the snapshot then says
   "too many entries"), or the owner's real `~/Documents` (rag needs its hours of embedding
   there, or a Qdrant collection that survived).
2. **The language gap** is cause 3 and stays: only one Finnish run in ten mixed English words
   in, though the description's example (`rent lease vuokra`) mixes languages. Either accept it
   (the recall chapter's "what vectors buy" example), or nudge in the secretary's prompt that
   the user's files may be in another language than the question. Decide on 1's numbers.
