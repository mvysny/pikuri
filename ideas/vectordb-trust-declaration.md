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
prints today. `#configure` builds the three tools with the derived
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
threaded into `Tools::Search` / `Tools::Read` / `Tools::Reindex` as two
booleans or as a pre-built `TrifectaLegs` is a nit; a pre-built `legs:`
kwarg is one line per tool and keeps the derivation in one place. The
three hardcoded comments ("Hard untrusted: a corpus is a pile of
documents pikuri did not write…", "No private leg: there is no
per-corpus declaration yet…") are replaced by the derivation.

**All three tools derive both axes**, `Reindex` included. Its
observation lists what was indexed — corpus-authored filenames, so
untrusted follows `trusted:` — and a filename list of
`customers/acme/2026-08-14.md` is itself private information, so it
carries `private:` too. (One could argue `Reindex` is the `write` case
from the detector chapter — a model-initiated operation with no
attacker-chosen query — and drop its private leg. Lean: derive all
three for consistency with the file tools, where everything reading
through the workspace inherits the flag. Revisit on a concrete case,
not a symmetry argument.)

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
   `@param` yardoc for each, mirroring `Filesystem`'s wording (private:
   "this corpus may hold sensitive data"; trusted: "every byte under
   `source` is user-authored — claim it only if nothing pasted or
   downloaded lives there"). Build `legs` once, pass to the three
   tools.
2. **`Tools::Search` / `Tools::Read` / `Tools::Reindex`** — accept
   `legs:` (default: today's hardcoded value, so direct construction
   outside the extension keeps working); delete the three hardcoded
   comments; the class yardoc for `Search` gets the one-paragraph "who
   declares" pointer.
3. **Specs** — rewrite
   `pikuri-vectordb/spec/pikuri/vector_db/trifecta_legs_spec.rb` on the
   pattern of `pikuri-workspace/spec/pikuri/workspace/trifecta_legs_spec.rb`:
   defaults are `:hard` / `private: false` (the framework declares
   neither for you); `trusted: true` → `:none` on all three tools;
   `private: true` → `private` on all three; egress stays `:no_egress`
   regardless. The current second example ("claims no private leg —
   there is no per-corpus declaration yet") is deleted, its comment
   having become false.
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
   what the map prints before and after. Optionally a sentence in
   `book/trifecta-detector.md` §"Who declares each leg" naming the
   corpus as the second place the private flag lives.
6. **`CHANGELOG.md` `[Unreleased]`** — one sentence: *Add `private:` /
   `trusted:` to `VectorDb::Extension.new` — the three `vectordb_*`
   tools derive their trifecta legs from the declaration instead of
   hardcoding untrusted-hard / no-private, the way the file tools
   derive theirs from `Workspace::Filesystem`. See `DECISIONS.md`
   `D_corpus_trust_declaration`.*
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
   test). Consequence: the multi-source paragraph above.
8. **`ideas/`** — on landing, delete this file; trim
   `meeting-prep.md` §"The library change" to a pointer at the `D_`
   entry; add a line to `vectordb-deferrals.md` §"Multi-source
   indexing" that the per-source trust flag is part of that API.

## Open questions

- **Reindex and the private leg** — see the parenthetical under §"The
  change". Lean: derive.
- **A trusted corpus containing a PDF.** `Extractor` output is still
  the user's bytes if the user authored the PDF, so `trusted:` stands.
  A downloaded datasheet in the folder falsifies the claim exactly as a
  pasted e-mail does. Documentation, not code.
