# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status: **brainstorm** (2026-11-17). Two decisions, deliberately separable:

- **A.** The secretary (and Puri, and any "Siri-shaped" assistant) searches your files
  through the desktop's own file index (GNOME localsearch, recoll as a fallback) instead of
  `pikuri-rag` over a self-built vector + FTS5 index.
- **B.** `pikuri-vectordb` and `pikuri-rag` (and `pikuri-briefing` with them) move to
  pikuri-workshop. A new standalone gem in pikuri, `pikuri-fileindex`, takes the file-index
  code out of the workshop's `pikuri-os`.

A can ship and be judged on transcripts before B happens. B has the big cost: the book.

## Why

- **The GPU bill.** `D_secretary_wiring` measured the owner's `~/Documents` (11,685 files):
  minutes of silence, then hours of a Radeon 890M at 100%, with chat queued behind the
  embedder on the same llama-server. That is why the secretary defaults to Qdrant and makes
  podman a prerequisite of the book's last chapter. A regular user doesn't want to watch
  their GPU burn so that an assistant can look up an invoice.
- **These assistants don't do deep research.** The secretary, Puri and Siri ask a few lookups
  per turn. Ornith and Qwen are fine at issuing a couple of keyword queries and rephrasing
  on a miss. Ranked semantic retrieval pays off for people for whom search quality *is* the
  product: those are the workshop's users.
- **pikuri-os already argued this.** `pikuri-workshop:pikuri-os/design/architecture.md`
  ("File search: keyword recall, not embeddings") sorts misses into three causes. Content
  that isn't indexed is structural. A wording miss is handled by the agent rephrasing its
  query. A real meaning gap is the only one embeddings fix, and it's the rarest on a personal
  machine. Measured there (2026-07): on indexed prose, localsearch ≈ recoll ≈ ripgrep, about
  100% recall.
- **Completeness comes free.** `D_rag_gem` built `rag_search_keywords` because cosine search
  can't promise "every note mentioning Acme". A keyword index with no `LIMIT` can.
- **Office documents come free.** localsearch extracts text from `.docx`, `.odt` and
  spreadsheets when it indexes them. That fills the gap `D_secretary_wiring` declined to fill
  (the pure-Ruby `.docx` reader, rejected as a feature).
- **Placement.** `D_gem_placement` test 1 says rag's future is more features: see
  `rag-hit-presentation-eval.md`, `vectordb-deferrals.md`, and the stemmers already in
  `pikuri-workshop:pikuri-stemmers`. The secretary's reader would also skip two of pikuri's
  biggest gems, and Docker would leave pikuri entirely (`D_gem_placement` says Qdrant is
  Docker's last job here).

## Measured on the owner's box (2026-11-17, LocalSearch 3.11.0, Ubuntu)

- **The CLI is the limit, not the index.** `localsearch search -d` gives one short snippet per
  file and can't be limited to a folder; those are the two limits pikuri-os's `LIMITATIONS`
  states. Querying the same index through `tinysparql` gives both:

  ```
  tinysparql query --dbus-service org.freedesktop.LocalSearch3 -a term:s:invoice -q \
    'SELECT ?url fts:snippet(?f, ">>", "<<", "…", 40) WHERE {
       ?f fts:match ~term ; nie:isStoredAs ?u . ?u nie:url ?url .
       FILTER(STRSTARTS(?url, "file:///home/mavi/Documents/")) }'
  ```

  That returned 40-word snippets (the Kettle & Co. invoice with its amount) and only hits
  under `~/Documents`. pikuri-os's architecture note "no directory scoping" is true of the
  CLI only. Correct it at graduation.
- **Bound parameters work**: `-a NAME:s:VALUE`, referenced as `~NAME`. The type must be `s`;
  `string` and `xsd:string` are refused. So the model's words never get spliced into the
  SPARQL text.
- **`fts:offsets(?f)` runs**, but its output looks wrong: `(null):17 (null):17 (null):17`
  for the invoice, with no property names and repeated offsets. Don't build on it without
  digging further.
- **The stock index covers all of `$HOME`, recursively.** The schema LocalSearch 3.11 ships
  (`/usr/share/glib-2.0/schemas/org.freedesktop.Tracker3.Miner.Files.gschema.xml`) defaults
  `index-recursive-directories` to `['$HOME']`. The older XDG-folders-only default is gone.
  This box also has that same value written into the user's dconf database. Nothing found
  shows pikuri-os or anyone else setting it: no `gsettings`/`dconf` write in the repos, their
  git history or the Claude transcripts, and the one `localsearch index` in shell history
  (2026-06-28) is the read-only listing form. Either way it equals the default, so it changes
  nothing. Consequence: on any stock install the index holds `~/work`, `~/snap` (4,258 files
  here), `~/backups`, `~/Android`, everything. **pikuri's own folder limit is required, not a
  nicety.**
- **Hidden paths are never indexed**, even with `$HOME` recursive: zero indexed URLs contain
  `/.`, so `~/.ssh`, `~/.gnupg`, `~/.config`, `~/.local` and `~/.git-credentials` are all
  absent. No settings key turns hidden files on (checked `gsettings list-keys`). Also skipped
  by default: any tree holding `.git`, `.hg`, `.trackerignore` or `.nomedia`. Secrets in
  non-hidden places (`~/ssh-vherd`, a `passwords.txt` in Documents) *are* indexed. Whatever
  is inside the roots is readable, just as `rag_read` reads all of `~/Documents` today.

## Proposal

### The gem: `pikuri-fileindex`

Named for what it refuses to become: the owner of an index. It only queries the one the
desktop already keeps fresh.

- Move `LocalSearch`, `Recoll`, `FileindexSearch` and `FileindexRead` out of `pikuri-os`;
  `pikuri-os` then depends on this gem. That's the allowed direction (workshop → pikuri).
- localsearch's search goes through `tinysparql query` with one constant query text, user
  input bound as `~term`, and 30–50-word `fts:snippet`s. The roots come from pikuri's own
  configuration, never from the model, but bind them too (`~root1`…) rather than building the
  filter by hand.
- **`roots:` on the extension.** Default: the XDG user folders (Desktop, Documents, Downloads,
  Music, Pictures, Videos, Public, Templates) as `xdg-user-dir` reports them. That leaves out
  `~/snap`, `~/work` and everything else at the top of `$HOME`. The secretary passes its own
  list.
- **`fileindex_read` checks its path**: inside a root, and no hidden component. The miner
  already skips hidden paths; this second check costs one line, and the path is the model's.
- FTS syntax errors from the model (an unbalanced quote) come back as `Tool::Result.error`.
- Trifecta: graded from the roots, the way `D_bundle_trust_grading` does it, or simply fixed.
  With Downloads in the roots it is hard-untrusted. The secretary's verdict doesn't move, since
  mail already makes it hard-untrusted and it holds all three legs. Puri should check its own.

### The secretary

- Wire `pikuri-fileindex` in place of `Rag::Extension`. Drop Qdrant, podman, `--in-memory`,
  the `Watcher` and the "folders kept out of the index" prompt line. The index's coverage is
  now GNOME's Search settings plus our roots.
- Keep `read` (with `pikuri-pdf`) for live files: a note the agent just wrote must be read
  from disk, not from the index's copy.
- Notes it just wrote: the miner picks changes up over inotify, usually within seconds. Check
  in transcripts that "write a note, then find it" holds in one session.

### What moves to the workshop (B)

`pikuri-vectordb`, `pikuri-rag`, `bin/pikuri-corpus`, `bin/pikuri-briefing`, their
chapters, `D_rag_gem`, `D_rrf_tuning`, `D_chunk_line_ranges`, `D_ruby_stemming`,
`D_corpus_trust_declaration`, `D_briefing_*`, and the two idea files above. AGENTS.md's
Connection and Request seams name `VectorDb::Embedder` and `Reranker::LlamaServer`; those
clauses go to the workshop. `pikuri-pdf`'s gemspec mentions the corpus.

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
searches the file index, as long as legs are graded from the roots: `~/notes` is trusted,
Downloads is not. The book's spine is the trifecta; the recall section exists to give it private
data worth protecting.

Options weighed:

- **Teach RAG on the desktop index; vectors go to book 2.** RAG is retrieve-then-generate, and
  agentic RAG is the model issuing the queries. That needs no vectors. `rag.md`'s completeness
  vs. ranking and exactness arguments survive, because a keyword index is what it argues you
  need anyway. New lessons it brings: borrowing an index vs. building one (who keeps it fresh,
  who pays), the folder limit as a security boundary, bound parameters vs. splicing (SQL
  injection's cousin). Lost to book 2: embeddings, chunking, cosine, the reranker, rank
  fusion. They go under a "building your own index" chapter for people for whom ranking is
  the product.
- **Keep vectors; the book ends on a different persona** (a researcher over a library of
  papers, where ranking quality is the job). The recall chapters then pay off, but every
  reader pays the GPU bill and podman for a persona they won't run day to day. Puri would
  diverge from the book's closing binary.
- **Keep vectors in the book, the secretary on the file index.** The recall chapters build
  something the last binary never uses: a dead end.
- Leaning: the first. GNOME-only would then lock non-GNOME readers out of the recall chapter,
  so the book forces `Q_recoll_day_one`.

## Costs

- **The book.** It now goes vectordb → rag → briefing → secretary. Embeddings, chunking and
  rank fusion are concepts, not only features. After B, pikuri teaches search as "an agent
  using the desktop's index", and the retrieval chapters move to the workshop's book. The
  biggest rewrite involved.
- **GNOME.** pikuri is Linux-first, not GNOME-first. Recoll is already written as the
  fallback (KDE, Xfce, headless).
- **The demo VM** (`dev/demo-home`) needs a desktop session with the miner running to record
  transcripts. Specs fake the subprocess and need no localsearch.
- **Coverage is GNOME's to decide.** Our roots narrow; they can't add a folder GNOME skips.
- **Code and git checkouts are invisible** to localsearch. That's fine for a secretary, and
  it's the reason the coding agent keeps `grep`.

## Open questions

- `Q_book_retrieval`: after B, do embeddings and rank fusion stay in pikuri's book at all
  (say, as a pointer to the workshop's book), or does pikuri teach search as a keyword index
  only?
- `Q_briefing`: `pikuri-briefing` searches a small hand-picked corpus, the one place rag
  doesn't burn the GPU. Does it go with rag, or get rewired onto the file index and stay?
- `Q_default_roots`: are the XDG user folders the right default? Pictures, Music and Videos
  are mostly metadata; Public and Templates are rarely useful. Should `~/work`-style
  top-level folders be opt-in only? Read the folders with `xdg-user-dir`, or by parsing
  `user-dirs.dirs`? AGENTS.md's "never read an `XDG_*` variable" is about pikuri's own
  paths, but should be checked against this.
- `Q_one_read_tool`: one read tool or two? The index's copy is the only `.docx`/`.odt`
  extractor we'd have. Options: keep `read` + `fileindex_read` and say which is for what (two
  read tools confuse a small model), or a localsearch-backed `Extractor` entry so `read`
  handles `.docx` (a feature: name it as one).
- `Q_recoll_day_one`: ship the recoll arm from the start, or GNOME-only first? Recoll has its
  own folder filter (`dir:`), so roots map onto it.
- `Q_all_matches`: does a 40-word snippet plus `read` cover "context around the matches", or
  is a find-in-this-file over extracted text worth it? Depends on fixing `fts:offsets`.
- `Q_transcript_bar`: what counts as "the secretary does fine on the file index" before B?
  Owner's rule: a handful of runs is an anecdote.
