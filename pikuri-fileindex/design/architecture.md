# pikuri-fileindex — design & threat model

Audience: someone extending this gem or auditing it. Each class's YARD
header holds its own rationale; this file holds what spans
{Pikuri::Fileindex::LocalSearch}, {Pikuri::Fileindex::Recoll} and the two
tools: the threat model, why keyword recall is the whole posture, and
which backend earns the default. Why pikuri borrows the desktop's index
instead of building one: `design/decisions.md` `D_secretary_wiring`.

## Threat model

What the gem promises, and what it leaves to the host:

- **No parser of ours touches a stranger's file.** `fileindex_read`
  returns the text the index already extracted. localsearch runs its
  extractors in a separate process under seccomp, so a malicious `.docx`
  in Downloads is parsed by the desktop's sandbox, never by pikuri and
  never by a native parser in our process. recoll's extractors run in
  `recollindex`, outside our process but unsandboxed: that is the user's
  choice of indexer, not ours.
- **The model's words never become SPARQL.** localsearch takes each
  word group, each folder prefix and the limit as bound `tinysparql`
  parameters (`--arg name:s:value`, referenced as `~name`); the SPARQL
  text is generated from how many groups and folders there are, nothing
  else. recoll takes the query as one argv element, with the model's
  words spliced into recoll's query language inside our parenthesised
  groups, so a word can still carry recoll syntax (`dir:`, `-word`); the
  roots check below bounds what that reaches. A folder containing `"` is
  refused because that language can't quote one.
- **Nothing is written.** Both backends are queried read-only. pikuri
  never builds, configures or refreshes an index.
- **Reach is the host's roots, never the model's choice.** On a stock
  LocalSearch 3.11 the index covers all of `$HOME`, recursively (the
  shipped `index-recursive-directories` default is `['$HOME']`): `~/work`,
  `~/snap`, backups. It skips only hidden paths and any tree holding
  `.git`, `.hg`, `.trackerignore` or `.nomedia`, and keeps source files by
  name only. So {Pikuri::Fileindex::Roots} is the boundary, enforced three
  times over:
  - the backend searches only under the roots (bound URL prefixes for
    localsearch, an OR-ed `dir:` group for recoll);
  - the model's `folder` and `fileindex_read`'s `path` must resolve inside
    a root, judged by their real path, so neither `..` nor a symlink leads
    out, and a path outside is refused before anything checks whether it
    exists;
  - every search hit is checked against the roots before the model sees
    it. That last check is the guarantee: recoll's query language is
    spliced, so its `dir:` group narrows but isn't trusted to bound.
- **Nothing hidden.** A dot-named file or folder below a root is never
  returned or read. localsearch never indexes one (no setting turns that
  on); recoll does, so the check is load-bearing there.
- **Everything else in a root is reachable.** A `passwords.txt` in
  Documents is as readable as the invoice beside it. Choosing the roots is
  choosing what the agent may see.
- **Legs come from the owner's declaration.** `Roots.new(private:,
  trusted:)` grades both tools, as a vectordb corpus or a workspace
  does; nothing inspects the files. A root with Downloads in it is never
  `trusted:`.
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

## Matching: any word, files with all of them first

{Pikuri::Fileindex::Query} parses what the model typed into word groups:
a bare word is a group, double quotes make one group of their words, in
any order. A file matches when it holds every word of any group. Both
indexes want every word by default, and an agent that lists alternatives
(synonyms, a second language, everything the file might say) mostly
found nothing that way: of 140 queries Ornith wrote over the demo home,
71 came back empty, and 28 of those had a word in the right file
(measured 2026-11).

- **localsearch** has no OR: `fts:match` reads `OR`, `NOT` and
  parentheses as words. So {Pikuri::Fileindex::LocalSearch} unions one
  `fts:match` per group and ranks a file by how many groups it matched,
  then by relevance.
- **recoll** gets `(w1 w2) OR (w3)`; its `OR` binds tighter than the
  implicit AND, so the folder group appended after it bounds the whole.
- **The tool** asks a several-group query twice: any group, then every
  word ({Pikuri::Fileindex::Query#all_of}). The files with every word go
  first and are counted ("3 contain all of your words"), so the strict
  match stays visible whatever order the backend ranked in.

Quotes are a group, not a phrase: looser than a phrase, so a model that
expects one still gets every file a phrase would find, and the extra
files show their snippet. It also needs no proximity operator, which
localsearch doesn't expose.

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
| `.docx` / `.odt` / `.xlsx` / epub | Ubuntu: **filename-only** unless `localsearch-extractor-office` is installed (measured 2026-11) | full text (`.docx`, `.odt`; recoll 1.43, measured 2026-11) |
| `.csv` | **filename-only**: the text extractor takes only `text/plain` and `text/markdown` (measured 2026-11) | full text (recoll 1.43, measured 2026-11) |
| Folder filter | URL-prefix filter in SPARQL | `dir:` clause + per-config `topdirs` |
| Query ops | stemmed AND, phrase, `prefix*` on stems; no OR (measured 2026-11) | + OR / exclusion / proximity / wildcard / field filters |
| A hit shows | a 40-word snippet; a file of up to 600 characters whole | recoll's abstract (its own length setting) |
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
answer", not "installed": each backend's `unavailable_reason(folders:)`
requires at least one file under the roots, lest an installed-but-empty
index win {Pikuri::Fileindex.pick} and then answer every search with
nothing. That also catches the cases a bare probe passes: indexing
turned off in GNOME's Search settings, roots GNOME doesn't cover, a notes
folder that is a git checkout. One empty root among others is normal (an
empty Desktop), so it only logs a warning.

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
