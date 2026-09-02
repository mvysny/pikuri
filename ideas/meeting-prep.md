# Meeting prep: the one-legged agent, and what the second leg costs

Status: **brainstorm, nothing built.** The use case: a user gathers
meeting notes from all customers by hand and wants an agent to prepare
them for an upcoming meeting — summarize the timeline, say what was
discussed last. The user is strict: **no Thunderbird, no
internet, just the hand-curated notes folder.** That strictness is what
makes the idea interesting: it is the first agent pikuri would ship
that holds *one* trifecta leg, and it gives a controlled experiment for
what changes when the second leg (read-only mail) is added.

Related:

- [`assistant.md`](assistant.md) — the federation this would be a member
  of. This note is a candidate *first member* and the "prototype someone
  uses for a week" that note says the federation is waiting on.
- `DECISIONS.md` `D_corpus_trust_declaration` — the per-corpus
  `private:` / `trusted:` declaration this note motivated, now shipped.
- [`vectordb-deferrals.md`](vectordb-deferrals.md) — the per-tool pool
  choice and multi-source indexing, both of which interact with that
  declaration.
- `book/trifecta-detector.md` §"Who declares each leg" — the table this
  note leans on: untrusted and egress are the framework's, private is
  the user's.
- `DECISIONS.md` `D_lsp_trifecta_legs`, `D_bundle_trust_grading`,
  `D_no_static_poisoned_flag` — the three entries checked for a
  contradiction with the declaration. None found; the check is recorded
  in `D_corpus_trust_declaration`.

## Stage 0 — the one-legged agent

The wiring: a local model, `Pikuri::VectorDb::Extension` over the notes
folder, a briefing persona, nothing else. No web, no bash, no mail, no
memory gem.

### What the user says vs. what the detector says

The user: "one leg, *private*." The detector, before the corpus could
declare itself: "1 of 3 legs (untrusted); no private leg found." Both
agreed the agent was one-legged and disagreed on *which* leg, which is
exactly the "who declares" split — untrusted defaults on and only the
user can answer it, private defaults off and only the user can turn it
on.

That was the one library change this idea earned, and it has shipped:
`Extension.new(private: true, trusted: true)` now prints *"1 of 3 legs
(private)"* (`D_corpus_trust_declaration`). What is left for this note
is the *wiring* — which values this agent passes, and the persona
obligations below that make `trusted: true` honest.

### What a purely private agent buys, and what it makes redundant

- **Prompt injection is impossible by construction.** Every byte the
  model reads was authored by the person reading its output. This is
  the `@private` posture from `pikuri-memory/DESIGN.md` — the all-trusted
  input stream — realised without the memory gem.
- **The private leg alone is inert.** Private data with no exit and no
  untrusted input is a personal tool, not an attack surface. No
  confirmer, no sandbox, no gate. "Start slowly" in its purest form.
- **`pikuri-memory` is redundant here.** The notes folder *is* the
  durable memory: human-written, human-curated, already distilled.
  Auto-extracting from it would summarize a summary. Skip it; if the
  user wants to remember something, they write a note.
- **The user's hand-curation is the federation's human bus, done by
  habit.** They read correspondence, decide what matters, write it
  down in their own words. That is the *author* step from
  [`private-context-taint.md`](private-context-taint.md), performed
  before the agent ever sees anything. Keep this observation — Stage 1
  is what happens when it is automated away.

### The one place the user is stricter than the trifecta model

The trifecta does not count the inference provider as egress; the
user's "no internet" does. With a cloud model every customer note
ships to the provider by design and the one-legged story is false at
the transport level. **Local inference is the agent's first invariant**,
not a preference. (`Agent::ChatTransport` already makes this a wiring
choice, so nothing to build — but the persona's docs must say it.)

### Is `trusted: true` honest for hand-curated notes?

Only as long as the user writes in their own words. The moment they
paste a customer e-mail into a note, the corpus is untrusted again and
nothing can detect it. Same unverifiable claim as `Filesystem#trusted?`
and `Bundle::Base(trusted:)`; same posture — the human asserts, the
framework records, the detector reports. Worth one sentence in the
persona docs: *paste nothing; paraphrase.*

And "own words" is not the whole of it. A received document — the
customer's deck, the contract they sent — is not vouched for by having
*read* it: a rendered PDF hides white-on-white text, comments and
metadata that extraction surfaces for the model. The flag's real
definition is *reviewed in the form the model will read it*, and the
recipe for received documents is convert with pikuri's extractor, read
the text, index the text, keep the original out of the corpus — or put
received documents in a second corpus declared untrusted and accept a
two-legged agent. The flag's three clauses are
`Extension#trusted?`'s yardoc and `book/vectordb.md`'s; for Stage 0 the
one-line rule is: **the trusted corpus holds only what the user typed or
reviewed as text.**

## The library change: shipped

The per-corpus `private:` / `trusted:` declaration this note motivated
landed as `VectorDb::Extension.new(private:, trusted:)`, with the two
reading tools deriving their legs from it and `vectordb_reindex`
declaring none. The reasoning, the flag's three-clause definition, the
five rejected forks and the deferred boot-time reconcile all live in
`DECISIONS.md` `D_corpus_trust_declaration`; the reader-facing half is
`book/vectordb.md` §"Why this agent can't leak your corpus".

What stays open for *this* note is the wiring: which values a
meeting-prep agent passes (both `true`), whether that is a constant or a
boot question (§"Open questions"), and the persona obligations above.

## Stage 1 — add Thunderbird, read-only, correspondence with that customer

The legs become private + untrusted (the inbound tools declare
`INBOUND_LEGS = private: true, untrusted: :hard`). Still no egress, so
the detector stays quiet: presence did not complete a trifecta. But the
human's obligations change completely, and that is the point of running
the two stages side by side.

- **Injection becomes possible, and the harm is a corrupted brief.** No
  egress and no write tools, so a hostile e-mail cannot exfiltrate. It
  can make the brief say "the customer agreed to the discount." The
  brief is a decision input; bounded harm, but real. The defense is
  citation discipline — every claim quotes and cites its source so the
  human can check, which `persona-librarian.txt` already does for
  corpus hits and the briefing persona must do for mail.
- **Auto-extraction is no longer safe.** If Stage 0 had grown any
  auto-memory, Stage 1 must drop it or split the agent — a one-legged
  `@notes` and a two-legged `@mail`, the human carrying facts across.
  Carrying facts from mail into notes is precisely the hand-curation
  the user already does. **Adding mail access automates away the
  step that made the agent one-legged.** That is the honest trade;
  write it down as such rather than as a feature.
- **"Correspondence with that customer" is a prompt promise, not an
  enforced boundary.** `thunderbird_mail_search` searches the whole
  Gloda index. Enforcing per-customer scope needs a *correspondent
  allowlist* on `Thunderbird::Extension` — filter by sender/recipient
  address or domain before results reach the model. Without it the
  private pool jumps from "notes about customers" to "the entire
  mailbox"; presence is binary, strength is not
  (`book/trifecta-detector.md` §"A leg's presence is binary"), and an
  injected or wandering model can surface unrelated private mail into
  the brief. This is the second library change the idea might earn,
  and unlike the first it is a real filter, not a label.
- **The same split exists without Thunderbird.** Received documents the
  user wants searchable but will not review as text (§"Is `trusted:
  true` honest") are the mail case in miniature: a second corpus,
  declared untrusted, on a two-legged sibling — `@notes` trusted,
  `@received` not. Whether the untrusted source is a mailbox or a folder
  of customer decks, the shape and the human's obligations are the same.
- **Wire only mail search + mail read.** The extension bundles five
  inbound tools; calendar and contacts add private pool for no briefing
  value the user asked for. (Calendar *would* answer "which meeting
  is coming up" — tempting, and a good example of scope creep to
  resist until asked.)
- **The private-leg declaration on the corpus now matters for a
  reason.** In Stage 0 it was cosmetics on a quiet banner. In Stage 1
  the agent's private leg is real on both sources, and the corpus
  declaration is what keeps the map from under-reporting the pool.

### Why keep both stages as a teaching example

Same agent, same persona, same absence of egress, and the detector's
verdict barely moves. Yet the human must now verify citations, stop
trusting the brief blindly, give up auto-memory, and decide whether
mailbox scope is enforced or promised. It is the cleanest demonstration
available of what the *untrusted* leg means on its own, without egress
muddying it. Candidate for the book beside the detector chapter.

## What else the idea needs (none of it a gem)

- **A briefing persona** (`prompts/persona-*.txt`): given a customer
  name, produce the timeline, the last discussion, open commitments,
  each with a cited `source`. Same precedent as `LIBRARIAN`. Lives in
  `pikuri-assistant` (the `LIBRARIAN` / `GIT_REPO_RESEARCHER` precedent
  named in `assistant.md`), as a `bin/` demo + book example — the
  `pikuri-computer` shape, not a gem: no novel threat model, no
  cohesive lib code.
- **A corpus layout convention so "last discussed" is answerable.**
  Chunks carry `source` and a content hash, no dates. The date has to
  live in the path or frontmatter — `customers/acme/2026-08-14.md` — and
  the persona has to know to read it off the `source`. A documented
  convention, not a feature. (A `mtime`-derived date would be wrong the
  first time the notes are `git clone`d.)
- **Not `@private`.** In the federation this is `@customers` /
  `@accounts`, a sibling. `@private`'s auto-memory argument rests on
  *no untrusted ingest ever*; a corpus that is one paste away from
  untrusted, and that Stage 1 deliberately makes untrusted, must not be
  the agent that argument depends on.

## The slope to watch

The tempting extension is "and draft the follow-up e-mail from the
brief." That is `assistant.md`'s author→approver slope: a draft built
from (Stage 1) untrusted customer content, one click from egress. If a
draft feature ever appears it belongs to the forced-authorship handoff
— landing in the input box for editing — never a send button on the
brief. In Stage 0 the same feature is merely the convenience tax
(`@comms` does the sending; the human carries the text).

## Open questions

- **Does the briefing persona need the corpus to be *one* customer per
  folder, or can one collection hold all customers?** One collection is
  simpler and `vectordb_search` with the customer's name in the query
  probably suffices; but a per-customer collection would make
  "everything about Acme" a `read` of a folder listing rather than a
  search. Try the simple thing first.
- **Should `trusted:` on the corpus be a boot question** like
  `bin/pikuri-code`'s three, or a wiring constant? For a
  personal-notes agent the answer never changes, so a constant in the
  `bin/` script; the boot question is for a checkout that differs per
  run.
- **The correspondent allowlist — address, domain, or Thunderbird
  address-book membership?** Domain is the natural unit for a
  customer; address-book membership would let Thunderbird own the
  roster. Decide when Stage 1 is actually built.

## Graduation homes

- ~~The per-corpus declaration~~ — done: `VectorDb::Extension` yardoc,
  the derived legs, `D_corpus_trust_declaration`, `book/vectordb.md`.
- The two-stage teaching example → the book, beside the detector
  chapter.
- The persona + corpus layout convention → the persona's yardoc + the
  `bin/` script header.
- The correspondent allowlist → `pikuri-thunderbird/DESIGN.md` (it
  changes the read allowlist) + a `D_` entry if a fork is real.
- The "not `@private`" point → [`assistant.md`](assistant.md)'s roster
  section, when that note graduates.
