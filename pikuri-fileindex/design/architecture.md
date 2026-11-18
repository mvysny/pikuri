# pikuri-fileindex — design & threat model

Audience: someone extending this gem or auditing it. Each class's YARD
header holds its own rationale; this file holds what spans
{Pikuri::Fileindex::LocalSearch}, {Pikuri::Fileindex::Recoll} and the two
tools: the threat model, why keyword recall is the whole posture, and
which backend earns the default. Why pikuri borrows the desktop's index
instead of building one: `design/ideas/fileindex-replaces-rag.md` until
that idea graduates.

## Threat model

What the gem promises, and what it leaves to the host:

- **No parser of ours touches a stranger's file.** `fileindex_read`
  returns the text the index already extracted. localsearch runs its
  extractors in a separate process under seccomp, so a malicious `.docx`
  in Downloads is parsed by the desktop's sandbox, never by pikuri and
  never by a native parser in our process. recoll's extractors run in
  `recollindex`, outside our process but unsandboxed: that is the user's
  choice of indexer, not ours.
- **The model's words never become query text.** localsearch takes the
  query, the folder prefix and the limit as bound `tinysparql` parameters
  (`--arg name:s:value`, referenced as `~name`); the SPARQL text is a
  constant. recoll takes the query as one argv element; recoll's own
  query language is the model's to use, and a folder containing `"` is
  refused because that language can't quote one.
- **Nothing is written.** Both backends are queried read-only. pikuri
  never builds, configures or refreshes an index.
- **Reach is the whole index, for now.** The model's `folder` narrows a
  search, but nothing bounds it: on a stock LocalSearch 3.11 the index
  covers all of `$HOME` (hidden paths, git checkouts and source text
  aside). Hence both tools declare the private leg and hard-untrusted
  content, fixed. Host-set `roots:` that the model can only narrow inside
  are the next step (`design/ideas/fileindex-replaces-rag.md`); the legs
  can then be graded from the roots.
- **No egress.** Neither tool sends bytes anywhere; `tinysparql` speaks to
  the session bus, `recollq` reads a local Xapian database.

## File search: keyword recall, not embeddings

`fileindex_search` is only as good as the backend's lexical match. When
it misses, the cause is one of *three*, and they have different answers.
Only the third is a genuine "nothing we can do":

1. **Content not indexed / not reachable**: the dominant real limit, and
   it's *structural*, not a quality problem. `localsearch`
   **mime-gates** extraction: `text/plain` / Markdown / PDF / office get
   full body text, but **source code is filename-only** (`text/x-java`
   etc. store zero content; a 90 KB `.java` indexes 0 chars), and any
   tree containing `.git` is skipped wholesale. The fix is grep or a
   *different indexer* (`recoll`; survey below), not embeddings.
2. **Phrasing / synonym miss**: the doc is indexed but the user's words
   differ ("the doc about our refund policy" vs. a file that says
   "returns & cancellations"). The agent handles it by reformulating
   (synonyms, narrower terms), and a host that wires grep can fall back
   to it. `localsearch`'s index is already stemmed ("jumping" finds
   "jumps"), so regular inflections come free; irregular ones don't
   ("mice" misses "mouse", measured 2026-11). The residue is true
   synonymy, which query iteration handles better than any lexical index.
3. **Genuine semantic / conceptual gap**: cross-lingual, or "that thing
   about being frugal" → an unlabelled budget spreadsheet. The only cause
   embeddings address. Declined, not because a vector index "would
   re-index what `localsearch` already holds" (that conflates indexing
   cost with retrieval *modality*), but because owning a live `$HOME`
   embedding index means reinventing the freshness daemon `localsearch`
   hands us for free, plus the embedding GPU bill and a large new
   surface. Semantic *re-ranking* of `localsearch` hits doesn't rescue
   this either: it fixes precision, not recall. A doc the keyword miss
   kept out of the candidate set can't be re-ranked back in.

## Backend engine: `localsearch` vs `recoll`

Both sit behind the same duck type, and {Pikuri::Fileindex.pick} takes
the first ready one in `BACKENDS` order, so this is a wiring outcome,
not a rewrite.

`recoll` wins for *coverage and scoping*, **not for search quality** and
not for the semantic gap. Both are **lexical** (stemmed keyword)
indexers; neither closes cause (3) above.

**Measured (2026-07; `localsearch` vs `recoll` vs `rg` over a 59-file
Markdown corpus and ~825 Java files; throwaway bench).** On content
`localsearch` indexes (the Markdown), the two are **equivalent**: both
reach ~100% recall against a ripgrep oracle across distinctive, common,
morphological and multi-word queries, with near-identical file sets.
The apparent recoll win on the Java corpus was an artifact: `localsearch`
doesn't content-index source, so its "hits" there were filename matches.
That recall is against grep: it shows the index finds what grep finds,
not that keyword search answers an assistant's questions.

The `localsearch search` CLI sorts hits by path, not relevance, before
applying its limit, and can't filter by folder: "lease" gave five Android
SDK `NOTICE.txt` files. So the backend skips that CLI and asks the
index's SPARQL endpoint through `tinysparql`, ranked by `fts:rank` and
filtered by URL prefix; ranked, the lease agreement comes first
(measured 2026-11).

| | `localsearch` | `recoll` |
|---|---|---|
| Backend | GNOME's SPARQL store (tinysparql) | Xapian |
| Setup | **zero** on GNOME: already running | install + pick dirs + build index |
| Freshness | continuous daemon (GNOME-managed) | cron *or* inotify daemon (`recollindex -m`) |
| Recall on indexed prose | ~100% (**= recoll**, measured) | ~100% |
| Source code | **filename-only** (mime-gated); `.git` trees skipped | full text |
| Folder filter | URL-prefix filter in SPARQL | `dir:` clause + per-config `topdirs` |
| Query ops | stemmed AND / OR | + phrase / proximity / wildcard / field filters |
| Desktop tie-in | **GNOME-only** | DE-independent (KDE, Xfce, headless) |
| Headless CLI | `tinysparql query` (SPARQL over D-Bus) | `recollq` |

On a GNOME box `localsearch` is the right default: already indexing,
always fresh, nothing to configure, and as good as recoll at prose.
recoll is the backend for the **non-GNOME host**, and for a headless box
that records transcripts (`recollindex` with no desktop session).

Two shape notes: recoll's blind spot is the **inverse** of localsearch's.
It indexes exactly the configured `topdirs` (source code included), which
is why its `limitations` is a *method* reading the live `topdirs` rather
than a constant (see {Pikuri::Fileindex::Recoll.limitations} vs
{Pikuri::Fileindex::LocalSearch::LIMITATIONS}). And "ready" means "can
answer", not "installed": each backend's `unavailable_reason` requires an
index holding at least one file, lest an installed-but-empty index win
{Pikuri::Fileindex.pick} and then answer every search with nothing.

## Testing

The `localsearch` backend's index specs run against a real indexer in a
private sandbox: its own session bus, settings and database
(`spec/support/private_local_search.rb`), so they never read the user's
index. recoll's index specs build a scratch index (`RECOLL_CONFDIR` +
`recollindex` over a temp folder). A host without the binaries, CI
included, skips both and keeps the stubbed unit specs.

Sources: local measurement (above);
[recoll.org](https://www.recoll.org/),
[Tracker SupportedFormats](https://wiki.gnome.org/Projects/Tracker/SupportedFormats).
