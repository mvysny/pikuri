# Per-corpus `private:` / `trusted:` declaration on `VectorDb::Extension`

Status: **brainstormed, ready to implement; implementation deliberately
held.** The design is settled in
[`meeting-prep.md`](meeting-prep.md) §"The library change" (including
the check against earlier decisions); this note is the implementation
plan so the work can start cold.

## The problem

The three vectordb tools hardcode their legs:

```ruby
Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: :hard, egress_payload_review: :no_egress)
```

The tools cannot decide either value by themselves. Whether a corpus
holds the user's own words or a web crawl, and whether it is
confidential or public, are properties of the *data*, not the tool —
the two axes `book/trifecta-detector.md` §"Who declares each leg" says
the user must supply. `Workspace::Filesystem` has both knobs
(`private:`, `trusted:`) and the file tools derive their legs from
them; the corpus has neither, and the `Search` tool's own comment
names the gap and points at `Filesystem#private?` as the shape to copy.

Concrete consequence: a hand-curated, confidential notes folder
(`meeting-prep.md`'s Stage 0) is graded "1 of 3 legs (untrusted); no
private leg" — one leg, but the wrong one. Over-warned on untrusted,
under-warned on private. An agent printing the wrong leg teaches its
operator the map is wrong, which is the failure mode
`Pikuri::Trifecta`'s header names.

## The change

**Declare once, on the object that owns the corpus root:**

```ruby
Pikuri::VectorDb::Extension.new(backend:, source:, private: false, trusted: false)
```

Both default off, so every existing wiring prints exactly what it
prints today. `#configure` builds `Search` and `Read` with the derived
legs, the shape `Workspace::Read` already uses:

```ruby
legs = Pikuri::Tool::TrifectaLegs.new(
  private: private,
  untrusted: trusted ? :none : :hard,
  egress_payload_review: :no_egress
)
```

Where the value lives: `Extension` is the host-facing constructor and
already owns `source`, so the two booleans go there. Whether they are
threaded into `Tools::Search` / `Tools::Read` as two booleans or as a
pre-built `TrifectaLegs` is a nit; a pre-built `legs:` kwarg is one
line per tool and keeps the derivation in one place. Their two hardcoded
comments ("Hard untrusted: a corpus is a pile of documents pikuri did
not write…", "No private leg: there is no per-corpus declaration yet…")
are replaced by the derivation.

**`Reindex` declares `TrifectaLegs::NONE`, independent of both flags.**
Its observation is a chunk count, a "no indexable files" line, or an
infrastructure error (embedder down, backend down); per-file failures —
the only place a corpus-authored filename or an extractor's stderr would
surface — go to the logger and never reach the model. No corpus bytes
and no filenames enter the context, and the model chooses no query. That
is `Workspace::Write`'s case ("no file bytes enter the model's context —
the observation is an outcome"; `TrifectaLegs::NONE`), not `Glob`'s
(model-chosen pattern, bulk filenames back — derives both legs). The
detector chapter draws the private-leg line exactly there, between
`glob` and `write`. So this is a *second* correction in the same
change, in the quiet direction: today `Reindex` prints `untrusted: :hard`
on the strength of a comment ("the observation reports what was
indexed, and filenames are corpus-authored") that is false — the tool
has never returned filenames. No verdict moves: `Search` / `Read` keep
whatever `Reindex` had.

Residual, to be noted in the tool's comment and left: an embedder or
backend error message could echo a fragment of the chunk it choked on —
an infrastructure failure the model did not steer, carrying at most part
of one chunk. Revisit on a concrete attack vector, not a symmetry
argument (the chapter's own rule for this edge).

## What `trusted: true` means — the flag's definition

Flipping the flag is signing something, and the yardoc has to say what.
The naive reading — "I wrote everything in this folder" — is not enough,
because of *received* documents (the customer's deck, the contract they
sent) and, worse, because reading one does not vouch for it.

**The rendering gap.** A human can only vouch for what they saw, and the
flag is honest only when what they saw is what the model reads. For a
plain-text file the gap is nearly zero: an editor shows the bytes. For a
PDF or DOCX it is enormous — white-on-white text, hidden-text attributes,
off-page glyphs, comments, tracked changes, form fields, metadata — all
invisible to a reader and all present after extraction. A human who read
the rendered PDF approved a *proxy*, not the payload. pikuri already
refuses exactly this on the egress side: the `:unreviewed` rung exists
because "approving `curl` approves a program, and the bytes it sends are
computed after the click." Vouching for a rendered PDF is the ingest
mirror of that.

**The definition, for the `trusted:` yardoc:** *every source under
`source` was reviewed by you in the form the model will read it.* For
plain text that is the file. For any extracted format it is the
extraction — so either keep such files out of a trusted corpus, or
convert them first, read the conversion, and index that text instead of
the original.

**The recipe, and why it is the author seat.** Convert with pikuri's own
extractor (`Pikuri::Extractor.extract`), read the output in a plain
editor, index the *output file*, keep the original outside the corpus.
Then the reviewed artifact and the indexed artifact are the same bytes;
nothing is computed after the review. That is
[`private-context-taint.md`](private-context-taint.md)'s author-not-approver
property applied to ingest, and it needs no new code — the registry
already exposes the conversion; the recipe is a one-liner in the book.

**Recommendations for security-aware users** (book, beside the recipe):

- Review text in an editor, not a rendered preview: HTML comments and
  link-reference definitions are invisible in a Markdown preview and
  fully visible to the model.
- Scan a file you did not type yourself for non-ASCII / zero-width /
  bidi characters before trusting it — one `grep` line.
- Received documents you will not review that way go in a *second*
  corpus declared untrusted (the split-corpus shape; see
  [`meeting-prep.md`](meeting-prep.md)). The folder you vouch for
  contains only what you vouch for — the same-set principle again.

**Parser exposure is a different question, already answered.** A hostile
PDF exploiting poppler is a code-exec/DoS vector against the *extractor*,
not an injection vector against the model; the extractors gem owns it
(network-severed container; pikuri-pdf's pure-Ruby "DoS at worst").
`trusted:` says nothing about it, and the yardoc should say so in one
sentence so the flag is never read as "safe to parse". `Filesystem`'s
yardoc already separates the two questions the same way.

**The fork: document vs. refuse.** Decided: document, do not refuse.

- *Refuse non-text sources under `trusted: true`* (raise, or skip with a
  warning). Rejected. pikuri refuses a declaration only when it *cannot*
  be honest — `AllowAll` rejects `trusted:` because a whole-host reach is
  never all user-authored; a user-authored PDF *can* be honest, so this
  would be a different kind of rule. A refusal on extension also buys a
  false sense of safety — a text file hides an injection just as well
  with zero-width characters or an HTML comment; the gap is smaller, not
  zero — and it is the over-securing slope from
  [`assistant.md`](assistant.md): the user who exports their own notes to
  PDF routes around the flag and the map lies pessimistically for
  everyone who did the work.
- *Per-format grading* (the flag vouches for plain text only; extracted
  sources grade `:hard` regardless). Rejected: legs are static per tool
  and search returns chunks from every source, so one PDF takes the
  whole tool set to `:hard` — the multi-source union rule's outcome with
  extra machinery — and it moves an axis the "who declares" table assigns
  to the user back onto the framework.
- *Boot-time warning* on a non-text source under `trusted: true`.
  Rejected for the detector's own reason: a warning that fires on every
  Word-writing user is the false alarm that gets the map muted.
- **Fallback, recorded so a reopen knows what it buys:** a text-only mode
  for trusted corpora — the flag skips extracted formats with a logged
  warning unless the host opts them in. Makes the safe path the default
  path at the cost of a three-valued flag. Not now: nothing shows the
  documentation failing yet.

## Why this does not contradict an earlier decision

Investigated in `meeting-prep.md`; summary so the `D_` entry can be
written from here:

- **`D_bundle_trust_grading` is the precedent.** Trust declared per
  search base as a plain value, host answers it, tool derives the leg.
  Its principle decides this: *a trust claim is about that root, not
  about "the repo."*
- **`D_lsp_trifecta_legs` supplies the test**, and the corpus passes.
  Riding a human's answer is honest only when *the vouching and the
  reach are the same set*. `Indexer` walks exactly `source`,
  `vectordb_search` returns only chunks that walk produced, and
  `vectordb_read` is rooted at `indexer.root`. Nothing the tools return
  came from outside the folder the host vouched for. The corpus is the
  `read` case, not the `lsp` case.
- **`D_no_static_poisoned_flag` is about a different kind of flag** — a
  node-level `poisoned:` that would restate a derived value and silence
  egress propagation. A per-corpus `trusted:` is the *input* to the
  derivation on the one axis the framework cannot determine. Same
  category as the two knobs that exist.

**Not a defense.** `untrusted` and `private` are read by
`Trifecta::Report` and nothing else; the detector never blocks. This
changes what a banner prints, in whichever direction is *honest*
(quieter on untrusted for a trusted corpus, louder on private for a
confidential one).

## Multi-source, when it lands

`Extension.new(source:)` is a single root in v1
([`vectordb-deferrals.md`](vectordb-deferrals.md) §"Multi-source
indexing"). When several roots share one collection, trust must become
**per source** and the union must follow the `Bundle::Base` rule: one
unvouched root indexed into the collection takes the whole tool set to
`:hard`; `private` is `true` if any root claims it. Because
`TrifectaLegs` is declared once at tool construction, the legs are
computed from the source list at `#configure`, not from a single
boolean. Design the multi-source API with the per-source flag in it from
day one. There is no `AllowAll` analogue to guard against in v1 — one
bounded root — so no refusal is needed yet.

## Work items

1. **`Extension#initialize`** — add `private: false, trusted: false`;
   `@param` yardoc for each. `private:` mirrors `Filesystem`'s wording
   ("this corpus may hold sensitive data"). `trusted:` carries the
   definition from §"What `trusted: true` means": every source was
   reviewed by you *in the form the model will read it* — plain text is
   the file, an extracted format is its extraction, so convert, read,
   index the text; plus the one sentence that parser exposure is the
   extractor's question, not this flag's. Build `legs` once, pass to
   `Search` and `Read`.
2. **`Tools::Search` / `Tools::Read`** — accept `legs:` (default:
   today's hardcoded value, so direct construction outside the
   extension keeps working); delete the two hardcoded comments; the
   class yardoc for `Search` gets the one-paragraph "who declares"
   pointer. **`Tools::Reindex`** — hardcode `TrifectaLegs::NONE`, no
   kwarg; replace the false "filenames are corpus-authored" comment
   with the `Write`-case reasoning + the residual error-message note
   from §"The change".
3. **Specs** — rewrite
   `pikuri-vectordb/spec/pikuri/vector_db/trifecta_legs_spec.rb` on the
   pattern of `pikuri-workspace/spec/pikuri/workspace/trifecta_legs_spec.rb`:
   defaults are `:hard` / `private: false` (the framework declares
   neither for you); `trusted: true` → `:none` on `Search` and `Read`;
   `private: true` → `private` on both; egress stays `:no_egress`
   regardless; `Reindex` is `NONE` whatever the flags say. The current
   first example asserts `:hard` on all three including `Reindex` and
   must change; the second ("claims no private leg — there is no
   per-corpus declaration yet") is deleted, its comment having become
   false.
4. **`bin/pikuri-corpus`** — add `--private` and `--trusted` flags, both
   default off, passed straight through. Not hardcoded, because
   `--source PATH` lets the user point the demo at their own folder:
   `trusted: true` is honest for the bundled `book/` (pikuri wrote it)
   and a lie for an arbitrary path. The default run therefore still
   prints one untrusted leg for the guide, which is the pessimistic
   default the detector chapter defends; `--trusted` is the reader's
   first hands-on with the declaration, and the printed map is the
   payoff.
5. **`book/vectordb.md`** — the chapter already says "we treat the
   corpus as *private*" while the demo declared nothing. One paragraph
   in §"Why this agent can't leak your corpus": how to declare it, and
   what the map prints before and after. A second paragraph on what
   `trusted: true` signs you up for — the rendering gap, the
   convert-read-index recipe as a one-liner over `Pikuri::Extractor`,
   and the three recommendations from §"What `trusted: true` means".
   Optionally a sentence in
   `book/trifecta-detector.md` §"Who declares each leg" naming the
   corpus as the second place the private flag lives.
6. **`CHANGELOG.md` `[Unreleased]`** — one sentence: *Add `private:` /
   `trusted:` to `VectorDb::Extension.new` — `vectordb_search` and
   `vectordb_read` derive their trifecta legs from the declaration
   instead of hardcoding untrusted-hard / no-private, the way the file
   tools derive theirs from `Workspace::Filesystem`. See `DECISIONS.md`
   `D_corpus_trust_declaration`.* And a second: *Fix `vectordb_reindex`
   declaring an untrusted leg — its observation is a chunk count, never
   corpus content, so it now declares no legs, like `write`.*
7. **`DECISIONS.md` `D_corpus_trust_declaration`** — the fork is real:
   *keep the unconditional `:hard`* (rejected: over-warns exactly the
   operator who did the curation work; the `D_bundle_trust_grading`
   argument verbatim), *declare on `Indexer` instead of `Extension`*
   (rejected: `Indexer` is a population mechanism a host may never
   touch; the declaration belongs where the host wires the corpus),
   *hand the extension a `Filesystem`* (rejected: `D_bundle_trust_grading`
   already settled that a host answers with a value, and a corpus root
   is a path, not a workspace — a `Filesystem` would drag in
   `readable:` roots the index never walks and break the same-set
   test), *derive `Reindex` too, for symmetry* (rejected: no corpus
   bytes reach its observation; the `write` precedent, and the
   chapter's glob/write line), *refuse or down-grade non-text sources
   under `trusted: true`* (rejected, with the text-only-mode fallback
   recorded — §"What `trusted: true` means" has the three rejections).
   Consequences: the multi-source paragraph above; the flag's definition
   is the rendering-gap one, and a reopen of the refusal fork needs
   evidence the documentation failed.
8. **`ideas/`** — on landing, delete this file; trim
   `meeting-prep.md` §"The library change" to a pointer at the `D_`
   entry; add a line to `vectordb-deferrals.md` §"Multi-source
   indexing" that the per-source trust flag is part of that API.

## Open questions

None. The two that were here — `Reindex`'s legs, and a trusted corpus
holding a PDF — closed into §"The change" and §"What `trusted: true`
means" respectively.
