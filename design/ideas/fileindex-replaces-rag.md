# The desktop file index replaces rag for the secretary; rag and vectordb move to the workshop

Status: **brainstorm** (2026-11-17), direction agreed with the owner the same day. Two
decisions, deliberately separable:

- **A.** A new standalone gem in pikuri, `pikuri-fileindex`, takes the file-index code out of
  the workshop's `pikuri-os`. The secretary (and Puri, and any "Siri-shaped" assistant)
  searches your files through it, using the desktop's own file index (GNOME localsearch, or
  recoll), instead of `pikuri-rag` over a self-built vector + FTS5 index.
- **B.** `pikuri-vectordb` and `pikuri-rag` move to pikuri-workshop, with their chapters.

A needs the gem, because the secretary can't depend on the workshop. A can ship and be judged
on transcripts before B happens; until B, pikuri carries both search stacks. B has the big cost:
the book.

## Why

- **Puri already made this decision** (`puri:D_documents`, 2026-11-17): it searches through
  pikuri-os's `fileindex_search`, for the reasons below. If the secretary stays on rag, the
  book's closing binary and the app it hands off to differ on the thing a reader notices first.
  Puri also pulls in `pikuri-code` (bash) only to get the file index, which is the concrete
  case for a gem of its own.
- **The GPU bill.** `D_secretary_wiring` measured the owner's `~/Documents` (11,685 files):
  minutes of silence, then hours of a Radeon 890M at 100%, with chat queued behind the
  embedder on the same llama-server. That is why the secretary defaults to Qdrant and makes
  podman a prerequisite of the book's last chapter. A regular user doesn't want to watch
  their GPU burn so that an assistant can look up an invoice.
- **Book 1 loses its container runtime and its second model.** After B, nothing in pikuri needs
  podman, bge-m3 or a reranker. The prerequisites shrink to Ruby, llama.cpp, a chat model and a
  desktop index. `D_gem_placement` says Qdrant is Docker's last job here.
- **Hostile office files are parsed in the desktop's sandbox, not ours.** `fileindex_read`
  returns the text localsearch's extractor already pulled out, and that extractor runs under
  seccomp. A malicious `.docx` in Downloads is never parsed by pikuri, and never by native
  parsers on the host outside a sandbox. Puri's `D_extractors` already relies on this.
- **Office documents come free.** localsearch extracts text from `.docx`, `.odt` and
  spreadsheets when it indexes them. That fills the gap `D_secretary_wiring` declined to fill
  (the pure-Ruby `.docx` reader, rejected as a feature).
- **These assistants don't do deep research.** The secretary, Puri and Siri ask a few lookups
  per turn. Ornith and Qwen are fine at issuing a couple of keyword queries and rephrasing
  on a miss. Ranked semantic retrieval pays off for people for whom search quality *is* the
  product: those are the workshop's users.
- **pikuri-os already argued this.** `pikuri-workshop:pikuri-os/design/architecture.md`
  ("File search: keyword recall, not embeddings") sorts misses into three causes. Content
  that isn't indexed is structural. A wording miss is handled by the agent rephrasing its
  query. A real meaning gap is the only one embeddings fix. Measured there (2026-07): on
  indexed prose, localsearch ≈ recoll ≈ ripgrep, about 100% recall. That recall is against a
  ripgrep oracle: it shows the index finds what grep finds, not that keyword search answers the
  secretary's questions. Only the transcripts can show that (`Q_transcript_bar`).
- **Completeness comes free.** `D_rag_gem` built `rag_search_keywords` because cosine search
  can't promise "every note mentioning Acme". A keyword index with no `LIMIT` can.
- **Placement.** `D_gem_placement` test 1 says rag's future is more features: see
  `rag-hit-presentation-eval.md`, `vectordb-deferrals.md`, and the stemmers already in
  `pikuri-workshop:pikuri-stemmers`. The secretary's reader would also skip two of pikuri's
  biggest gems (vectordb + rag ≈ 4,600 lines of `lib/`, against pikuri-os's ≈ 1,000 for the
  four file-index files).

## Measured on the owner's box (2026-11-17, LocalSearch 3.11.0, Ubuntu)

- **The CLI is the limit, not the index.** `localsearch search -d` gives one short snippet per
  file and can't be limited to a folder. Querying the same index through `tinysparql` gives
  both: 40-word snippets (the Kettle & Co. invoice with its amount) and only hits under one
  folder. pikuri-os switched to `tinysparql` the same day (`LocalSearch::SEARCH_QUERY`: bound
  `~query` / `~prefix` / `~limit`, `fts:snippet` with `>>…<<` markers, GLib-exact
  percent-encoding of the prefix, an optional model-chosen `folder`). Its architecture note
  still says "the `localsearch search` CLI can't scope" in one place: check at graduation.
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

## Supported platforms (owner, 2026-11-17)

- **Ubuntu 26.04 LTS or newer, or any Linux with localsearch 3.8+** (the first release under
  the `org.freedesktop.LocalSearch3` D-Bus name and the `tinysparql` CLI), **or recoll with a
  built index**. Older Tracker 3 (`tracker3 sparql`, `org.freedesktop.Tracker3.Miner.Files`) is
  not supported.
- **Neither ready: the secretary prints why and exits 1.** No degraded mode with no search: a
  secretary that can't search would answer "you have no such file". Errors are loud.
- **Recoll ships on day one** (was `Q_recoll_day_one`). It's half the supported setups, and
  it's how the demo VM (`dev/demo-home`) records transcripts headless, with `recollindex` and
  no desktop session.
- **The book says it once**, in the prerequisites chapter; the recall chapter and the error
  message point there.

## Proposal

### The gem: `pikuri-fileindex`

Named for what it refuses to become: the owner of an index. It only queries the one the
desktop already keeps fresh.

- Move `LocalSearch`, `Recoll`, `FileindexSearch` and `FileindexRead` out of `pikuri-os`;
  `pikuri-os` and Puri then depend on this gem, and Puri drops `pikuri-os`. That's the allowed
  direction (workshop → pikuri).
- Mostly a move: the `tinysparql` query, the bound parameters and the snippets exist already
  (see Measured). The new parts are the roots and the readiness check below.
- **`roots:` on the extension, set by pikuri, never by the model.** Today `folder` is the
  model's argument and Puri's limit is a prompt line: a hint, not a boundary. The roots become
  a filter in the query (bound as `~root1`…, each with a trailing `/` so `Documents-old`
  doesn't match `Documents`); the model's `folder` can only narrow inside them. Default: the
  XDG user folders as `xdg-user-dir` reports them (but see `Q_default_roots`). That leaves out
  `~/snap`, `~/work` and everything else at the top of `$HOME`. The secretary passes its own
  list.
- **`fileindex_read` checks its path**: inside a root, and no hidden component. The miner
  already skips hidden paths; this second check costs one line, and the path is the model's.
- **Symlinks:** the index stores the target's URL, so a link from `~/Documents` into `~/work`
  falls outside the roots and its files vanish from search. Decide whether that's right
  (probably yes: the roots mean real paths) and say it in the tool's limitations.
- FTS syntax errors from the model (an unbalanced quote) come back as `Tool::Result.error`.
- Trifecta: graded from the roots, the way `D_bundle_trust_grading` does it, or simply fixed.
  With Downloads in the roots it is hard-untrusted. The secretary's verdict doesn't move, since
  mail already makes it hard-untrusted and it holds all three legs. Puri should check its own.

### Readiness: the backend investigates, the host only reports (owner, 2026-11-17)

The host shouldn't need to know what "ready" means for an index. Each backend does:

- **`Backend.unavailable_error(roots:)`** answers `nil` when the backend can deliver answers
  over these roots, else a String a human can act on: what's missing and the command or
  setting that fixes it. **`Backend.available?(roots:)`** is `unavailable_error(roots:).nil?`.
  One method holds the truth, because each probe is a subprocess spawn: two independent
  methods would probe twice and could disagree.
- **"Available" means ready to answer, not installed.** localsearch: `tinysparql` is on the
  `PATH`, the `LocalSearch3` service answers a probe, and the roots hold at least one
  indexed file. recoll: `recollq` runs, the index directory exists, and the roots hold at
  least one indexed file.
- **The emptiness check is over all roots together.** A single empty root is normal (an empty
  Desktop is common) and only logs a warning naming it. It also catches the silent case the
  probe misses: indexing turned off in GNOME's Search settings, or a root GNOME doesn't
  cover. The probe passes there, and every search would come back empty.
- **The fallback lives in the gem too.** pikuri-os, Puri and the secretary all pick
  "localsearch, else recoll", so three callers earn one helper (unlike the rag wiring
  `D_secretary_wiring` copied, which had one). Something like `Fileindex.backend(roots:)`:
  the first ready backend, else raise with every backend's `unavailable_error`, one per
  paragraph. The secretary rescues it, prints the message and exits 1; Puri shows it in its
  UI.

### The secretary

- Wire `pikuri-fileindex` in place of `Rag::Extension`. Drop Qdrant, podman, `--in-memory`,
  the `Watcher` and the "folders kept out of the index" prompt line. The index's coverage is
  now GNOME's Search settings (or recoll's `topdirs`) plus our roots.
- Keep `read` (with `pikuri-pdf`) for live files: a note the agent just wrote must be read
  from disk, not from the index's copy, and `edit`/`write` need read-before-write on `Notes/`.
- Notes it just wrote: the miner picks changes up over inotify, usually within seconds. Check
  in transcripts that "write a note, then find it" holds in one session. Recoll has no daemon
  unless `recollindex -m` runs, so state what recoll users lose here.

### What moves to the workshop (B)

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
searches the file index, as long as legs are graded from the roots: `~/notes` is trusted,
Downloads is not. The book's spine is the trifecta; the recall section exists to give it private
data worth protecting.

Options weighed:

- **Teach RAG on the desktop index; vectors go to book 2.** RAG is retrieve-then-generate, and
  agentic RAG is the model issuing the queries. That needs no vectors. `rag.md`'s completeness
  vs. ranking and exactness arguments survive, because a keyword index is what it argues you
  need anyway. New lessons it brings: borrowing an index vs. building one (who keeps it fresh,
  who pays), the folder limit as a security boundary, bound parameters vs. splicing (SQL
  injection's cousin), and whose parser touches a hostile file. Lost to book 2: embeddings,
  chunking, cosine, the reranker, rank fusion. They go under a "building your own index"
  chapter for people for whom ranking is the product.
- **Keep vectors; the book ends on a different persona** (a researcher over a library of
  papers, where ranking quality is the job). The recall chapters then pay off, but every
  reader pays the GPU bill and podman for a persona they won't run day to day. Puri would
  diverge from the book's closing binary.
- **Keep vectors in the book, the secretary on the file index.** The recall chapters build
  something the last binary never uses: a dead end.
- **Agreed: the first** (owner, 2026-11-17). The recall chapter gets a better order than
  `rag.md`'s "vectors can't do X, so add keywords": start from the index the desktop already
  keeps, look at what it misses, sort the misses into pikuri-os's three causes, and show that
  only the third needs book 2's vectors. The prerequisites chapter loses containers, which it
  says "first earn their keep" in the vector-DB chapter, and gains the supported-platforms
  section above.

## Costs

- **The book.** It now goes vectordb → rag → briefing → secretary. Embeddings, chunking and
  rank fusion are concepts, not only features. After B, pikuri teaches search as "an agent
  using the desktop's index", and the retrieval chapters move to the workshop's book. The
  biggest rewrite involved.
- **Platform.** pikuri is Linux-first, not GNOME-first: recoll covers KDE, Xfce and headless
  boxes, but only with an index the user built. Readers on Ubuntu 24.04 LTS or older Tracker 3
  are out (see Supported platforms).
- **Coverage is the desktop's to decide.** Our roots narrow; they can't add a folder GNOME
  skips.
- **Code and git checkouts are invisible** to localsearch. That's fine for a secretary, and
  it's the reason the coding agent keeps `grep`.
- **Cross-language search is lost.** bge-m3 matched an English query to a Finnish document; a
  keyword index needs the query in the document's language (and `pikuri-stemmers` ships
  Voikko, so the owner's files likely include Finnish). Check which language localsearch stems
  in (likely one, taken from the locale), and whether "search again in the other language"
  works in the transcripts. That's pikuri-os's cause 3, and it may not be as rare here as
  "the rarest on a personal machine" says.

## Open questions

- `Q_book_retrieval`: **resolved** (owner, 2026-11-17). The recall chapter states the keyword
  index's limits, then points at semantic search, vector databases, chunking and rank fusion
  in pikuri-workshop, linking its book (its README until B moves `vectordb.md` and `rag.md`
  there, then that chapter). No embeddings walkthrough in pikuri. The limits are named by
  pikuri-os's three causes, so the reader sees that vectors fix only the third (a real meaning
  gap: another language, a concept in other words), not unindexed content or a wording miss
  the agent fixes by rephrasing. The GPU measurement says why pikuri doesn't build its own.
- `Q_briefing`: **resolved** (owner, 2026-11-17): rewire `pikuri-briefing` onto the file
  index, root `~/notes` graded private and trusted, and keep it. Checked against the book:
  - Survives unchanged: the trifecta chapter's "One flag, one extra leg, and the same
    verdict" (only the tool names in its two maps change); the hardcoded declarations and
    the boot line stating them; local inference as the first invariant; no automatic memory.
  - Gets better: the secretary's "same retrieval, plus mail" becomes literally the same gem
    with wider roots, still graded per root. The boot line's "the index holds nothing but
    what that folder put there" is false for a borrowed index that holds all of `$HOME`; the
    root filter is the only thing keeping a Downloads file from coming back as vouched, so
    the one-legged agent is where "the folder limit is a security boundary" has a visible
    cost if it fails. Reword the line to say so. The two recall chapters become one, with
    briefing as its demo (`pikuri-corpus` over the book goes to book 2 with
    `vectordb.md`). `D_briefing_wiring`'s `--watch` fork and `rag_read`'s membership gate go:
    the miner keeps the index fresh.
  - **Requirement: search must be able to say "that's all".** The trifecta chapter's
    "Absence stopped being reportable the same way" rests on "over the notes the agent can
    list every one that mentions a thing". pikuri-os's `fileindex_search` caps at 25
    (`MAX_LIMIT`) and doesn't say whether more matched. The gem needs an uncapped listing (as
    `rag_search_keywords` has) or a truthful "25 of 37".
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
- `Q_default_roots`: leaning Desktop, Documents and Downloads only. Pictures, Music and Videos
  are mostly metadata; Public and Templates are noise. Top-level folders like `~/work` stay
  opt-in. `xdg-user-dir` is a subprocess through `Subprocess.spawn`, not an `XDG_*` read, and
  AGENTS.md's "never read an `XDG_*` variable" is about pikuri's own paths; add a clause there
  so the next agent doesn't flag it.
- `Q_one_read_tool`: leaning two tools, `read` + `fileindex_read`, each described by what it's
  for. `read` must stay for read-before-write on `Notes/`, and a localsearch-backed `Extractor`
  entry would break "Attachments are bytes" (the registry turns bytes into text, not paths into
  text). Puri already runs with both: its transcripts are the evidence on whether two read
  tools confuse a small model.
- `Q_all_matches`: does a 40-word snippet plus `read` cover "context around the matches", or
  is a find-in-this-file over extracted text worth it? pikuri-os's `fileindex_read` already
  takes a `pattern`; check whether that answers it. Depends on fixing `fts:offsets` otherwise.
- `Q_transcript_bar`: what counts as "the secretary does fine on the file index" before B?
  Owner's rule: a handful of runs is an anecdote, ~100 is the bar. Leaning: a fixed set of
  ten or so lookup tasks on the demo home, ten runs each on Ornith, comparing the hit rate
  between rag and the file index. Include "write a note, then find it" and one cross-language
  query.
