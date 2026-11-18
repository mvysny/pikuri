# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status (2026-11-18). Two decisions, deliberately separable:

- **A. Done.** The secretary and `pikuri-briefing` search your files through `pikuri-fileindex`
  (the desktop's own index: GNOME localsearch, or recoll), not `pikuri-rag`. Why:
  `D_secretary_wiring` (the "Files are searched through the desktop's own index" fork, "An
  index of our own" rejected) and `D_briefing_wiring`; the gem's design and threat model in
  `pikuri-fileindex/design/architecture.md`.
- **B. Left.** `pikuri-vectordb` and `pikuri-rag` move to pikuri-workshop, with their chapters.

Also left:

- **The book**, rewritten with B (the owner's call). It still teaches the rag wiring, and its
  commands name `./pikuri-rag/bin/pikuri-briefing`, which is gone. Until B, pikuri carries both
  search stacks, and only `bin/pikuri-corpus` still demos one. B has the big cost: the book.
- **Puri** pins workshop `9c8c84d` and gets the file tools through `pikuri-os`, not the gem
  (pikuri-os itself moved onto the gem in workshop `2d74e29`).

## Why B

- **Book 1 loses its container runtime and its second model.** After B, nothing in pikuri needs
  podman, bge-m3 or a reranker. The prerequisites shrink to Ruby, llama.cpp, a chat model and a
  desktop index. `D_gem_placement` says Qdrant is Docker's last job here.
- **Placement.** `D_gem_placement` test 1 says rag's future is more features: see
  `rag-hit-presentation-eval.md`, `vectordb-deferrals.md`, and the stemmers already in
  `pikuri-workshop:pikuri-stemmers`. Ranked semantic retrieval pays off for people for whom
  search quality *is* the product: those are the workshop's users. The secretary's reader would
  also skip two of pikuri's biggest gems (vectordb + rag ≈ 4,600 lines of `lib/`, against
  ≈ 1,000 for the file index).

## Supported platforms (owner, 2026-11-17)

Ubuntu 26.04 LTS or newer, or any Linux with localsearch 3.8+, or recoll with a built index,
as the gem's README states, plus `localsearch-extractor-office` on Ubuntu. **The book says it
once**, in the prerequisites chapter; the recall chapter and the binaries' "no index is ready"
message point there.

## What moves to the workshop (B)

`pikuri-vectordb`, `pikuri-rag`, `bin/pikuri-corpus`, their chapters, `D_rag_gem`,
`D_rrf_tuning`, `D_chunk_line_ranges`, `D_ruby_stemming`, `D_corpus_trust_declaration`, and
the two idea files above. `pikuri-briefing` stays (done, see A), so `D_briefing_*` stay here.
`D_secretary_wiring` keeps its rejected "index of our own", naming `pikuri-rag`. AGENTS.md's Connection
and Request seams name `VectorDb::Embedder` and `Reranker::LlamaServer`; those clauses go to
the workshop. `pikuri-pdf`'s gemspec mentions the corpus. `D_gem_placement`'s rejected
alternatives cite rag twice ("a note the rag search finds covers most of a skill", and
`pikuri-vectordb` depending on `pikuri-subagents` as a reason `pikuri-workspace` can't move).
`LocalSearch::WHOLE_TEXT_CHARS`'s yardoc sizes itself against "the 500 characters a rag hit
shows". This idea's eval harness needs `pikuri-rag` for its rag arm: it dies with the idea.

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
the secretary chapter, written as a diff against briefing with mail. Both survive now that
briefing searches the file index with legs from the roots' declaration: `~/notes` is trusted,
Documents is not. The book's spine is the trifecta; the recall section exists to give it
private data worth protecting.

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

**The cost.** The book now goes vectordb → rag → briefing → secretary. Embeddings, chunking and
rank fusion are concepts, not only features. After B, pikuri teaches search as "an agent using
the desktop's index", and the retrieval chapters move to the workshop's book. The biggest
rewrite involved.

The recall chapter's cross-language paragraph: localsearch stems in the locale's one language
and matches every word as a prefix (`pikuri-fileindex/design/architecture.md`, "File search").

## Open questions

- `Q_book_retrieval`: **resolved** (owner, 2026-11-17). The recall chapter states the keyword
  index's limits, then points at semantic search, vector databases, chunking and rank fusion
  in pikuri-workshop, linking its book (its README until B moves `vectordb.md` and `rag.md`
  there, then that chapter). No embeddings walkthrough in pikuri. The limits are named by the
  three causes, so the reader sees that vectors fix only the third (a real meaning gap:
  another language, a concept in other words), not unindexed content or a wording miss the
  agent fixes by rephrasing. The GPU measurement says why pikuri doesn't build its own.
- `Q_briefing`: **resolved and wired** (owner, 2026-11-17; done 2026-11-18, see
  `D_briefing_wiring`). What's left is the book:
  - Survives unchanged: the trifecta chapter's "One flag, one extra leg, and the same
    verdict" (only the tool names in its two maps change); the hardcoded declarations and
    the boot line stating them; local inference as the first invariant; no automatic memory.
  - Gets better: the secretary's "same retrieval, plus mail" becomes literally the same gem
    with wider roots. The boot line now names the folder limit as the boundary, so the
    one-legged agent is where "the folder limit is a security boundary" has a visible cost
    if it fails. The two recall chapters become one, with briefing as its demo
    (`pikuri-corpus` over the book goes to book 2 with `vectordb.md`).
  - "Absence stopped being reportable the same way" (trifecta chapter) needs search to say
    "that's all": **met** by `fileindex_search`'s footer. Whether "list every note mentioning
    Acme" needs more than 25 is for the briefing transcripts.
  - **The chapter must say: no git checkout for the notes under localsearch, or recoll.**
    `rag.md` argues against mtime "because it would be wrong the first time you `git clone`
    your notes", the very setup that empties the index; re-argue it with a plain copy to a
    new machine, as `D_briefing_wiring` now does.
  - **The chapter tells recoll users** to run `recollindex -m`, or re-index before a brief.
- `Q_transcript_bar`: **met** (owner, 2026-11-18): keyword recall was enough, the result is in
  `D_secretary_wiring`. The eval below stays as the recall chapter's material.

## `Q_transcript_bar`: the eval (2026-11-18)

Each round's fix has graduated: any-word matching (`pikuri-fileindex/design/architecture.md`,
"Matching"), a short file shown whole (`LocalSearch::WHOLE_TEXT_CHARS`), and the when-to-use
line opening `fileindex_search`'s description (after 5 of 10 `sauna` runs answered from general
knowledge without searching; 3 of 10 after it, too few runs to call). Coverage is accepted and
said (`D_secretary_wiring`); how "shown whole" and `pattern` fare on real file sizes, Puri will
show on the owner's `~/Documents`. What stays is the harness and the numbers the recall chapter
can use.

**Harness.** `fileindex-replaces-rag/transcript-eval.rb` runs on the dev VM (Ornith on the
host's llama-server). Each run is a fresh agent with the secretary's prompt, calculator and
workspace tools (no grep), and one retrieval stack: rag (in-memory hybrid index, bge-m3,
reranker, a `Watcher`) or the file index. No mail, no web: either would answer some tasks
around the retrieval under test. A run passes when the final answer matches every gold regex.
`fileindex-replaces-rag/hard-home.rb` builds `~/pikuri-eval/Documents` (seeded; 212 files in 23
folders) and `gold.json` beside it; the harness takes `EVAL_DOCUMENTS`. The demo documents get
the names a real home gives them (`Scans/scan_20261009_002.pdf`), among near-misses that share
each task's words but hold another answer (the paid invoice, last year's policy, the 2024
lease, a top-level `sauna plans.txt` saying "Ask Ilse. Not urgent.") and bulk. Every transcript
is in `results*/runs.jsonl`: `results` and `results-anyword` on the demo home,
`results-hardhome`, `results-hardhome-whole` and `results-hardhome-office` on the hard one.

Tasks: `invoice` (amount + IBAN, PDF), `notice` (lease, "move out"), `flood` (insurance
deductible for "water damage", asked as a flood), `sauna` (HTML), `solar` (a note, "solar
array"), `office` (board-meeting PDF), `electricity` (`budget.csv`: not content-indexed by
localsearch), `dentist` ("dental" vs "dentist"), `finnish-rent` (asked in Finnish, the lease is
in English), `bike-lock` (a note saved 5 s before the question, its code drawn per run).

The hard home, as shipped (100 runs a row):

| | pass | found the file | median time | p90 | mean calls | runs over 10 calls | searches that found nothing |
|---|---|---|---|---|---|---|---|
| rag | 100/100 | 100 | 25 s | 36 s | 2.1 | 0 | 16 / 181 (9%) |
| file index | 99/100 | 97 | 34 s | 65 s | 3.5 | 8 | 1 / 195 (1%) |

Leave out the two tasks coverage decides (`electricity`, `notice`) and the file index matches
rag: 2.01 calls a run against 2.08, median 28 s both, 79 of 80 passes. With
`localsearch-extractor-office` installed and the `.odt` re-indexed, `notice` passed 10/10 in
1.8 calls (3.9 before, rag 2.0), every one a search, mean time unchanged at 55 s
(`results-hardhome-office`). Only the `.csv` is left to coverage.

**For the recall chapter**, the misses by cause:

- **The demo home hides them.** Its 13 files sit in the boot snapshot as a map: a fifth of the
  runs never searched, and failures came back as browsing. Hence the hard home.
- **Wording (cause 2).** localsearch ANDs every word, and the model writes rag-style queries:
  71 of 140 came back empty ("dental appointment" for a note saying "Dentist … checkup"); any
  word, 21 of 107. Rag's semantic leg always returns five hits, so the habit costs it nothing.
- **Coverage (cause 1) costs the most.** `budget-2026.csv`: every run reached it by browsing,
  in 7 to 35 calls (up to 193 s). The `.odt` lease without the office extractor: "not in the
  index", then "binary", then the `.pdf`; with it, found by search.
- **Language (cause 3).** On the demo home, 1 run in 10 found the lease by search (browsing
  did the rest); on the hard home, 10 of 10, the model translating its query for one more call.
  Rag's bge-m3 ranked the lease first from an all-Finnish query.
- **Neither arm was fooled by a near-miss**, and freshness made no difference: a note saved 5 s
  before the question passed 10/10 on both.

Artefact in these runs: the hard home's HTML pages declared no charset, so localsearch read
them as Latin-1 ("â€”" for "—"); no task searched a non-ASCII word in HTML. Both generators
now declare UTF-8 (2026-11-18); a rebuilt hard home picks it up.
