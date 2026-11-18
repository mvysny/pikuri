# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status (2026-11-18): both decisions are done. **A**: the secretary and `pikuri-briefing` search
through `pikuri-fileindex` (`D_secretary_wiring`, `D_briefing_wiring`). **B**: `pikuri-vectordb`
and `pikuri-rag` live in pikuri-workshop (`D_gem_placement`, test 1); pikuri's half was commit Y,
in the cross-repo order of `pikuri-workshop:design/ideas/rag-vectordb-move-here.md`. The book's
recall chapter is `book/recall.md`, and `book/secretary.md` was re-recorded on the file index.

What keeps this file alive, none of it pikuri's to do:

- **The workshop** pins `PIKURI_REF` to Y (its step 5), and gives the eval's numbers below a
  durable home on its side, as its idea asks. Then this file and its sidecar go: the harness
  needs `pikuri-rag`, so it can't run here any more.
- **Puri** still pins workshop `9c8c84d` and gets the file tools through `pikuri-os`, not the
  gem (pikuri-os itself moved onto the gem in workshop `2d74e29`).
- **Siri's half** below goes to Puri's `design/research.md`, with the primary sources checked.
  The Spotlight fact pikuri's book uses is in `pikuri-fileindex/design/architecture.md`.

One choice for the owner to revisit: `secretary.md`'s reminder exchange ("Where the gate earned
its keep") is from the chapter's first recording. Seven re-runs on the file index never offered a
reminder, so it is labelled as such rather than re-recorded.

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
