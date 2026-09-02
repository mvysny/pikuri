# Briefing, Stage 1: what the second leg costs

Status: **Stage 0 is built and shipped; Stage 1 is designed, nothing
built.** The use case: a user gathers meeting notes from all customers
by hand and wants an agent to prepare them for an upcoming meeting.
They are strict: **no Thunderbird, no internet, just the hand-curated
notes folder.**

Stage 0 — that one-legged agent — shipped as
`pikuri-rag/bin/pikuri-briefing` plus `book/rag.md`; the wiring forks,
the two hardcoded declarations, the declined `KEEPER` persona, the
declined workspace tools and the declined write tool are
`DECISIONS.md` `D_briefing_wiring`. Nothing about Stage 0 is left
here.

What keeps this note alive is **Stage 1**: adding read-only mail. It is
the controlled experiment the whole idea was interesting for — the
agent goes from one trifecta leg to two, the detector's verdict stays
silent throughout, and the *human's* obligations change completely.

Related:

- `DECISIONS.md` `D_briefing_wiring` — Stage 0's forks, and the
  laundering-pipe argument that keeps a `write` tool out of Stage 1.
- `DECISIONS.md` `D_corpus_trust_declaration` — the per-corpus
  `private:` / `trusted:` declaration this note motivated.
- [`assistant.md`](assistant.md) — the federation this would be a
  member of (`@customers` / `@accounts`, not `@private`). This is the
  candidate *first member* and the "prototype someone uses for a week"
  that note says the federation is waiting on.
- `book/trifecta-detector.md` §"Who declares each leg" and §"A leg's
  presence is binary" — the two tables Stage 1's lesson leans on.

## Stage 1 — add Thunderbird, read-only, correspondence with that customer

The legs become private + untrusted (the inbound tools declare
`INBOUND_LEGS = private: true, untrusted: :hard`). Still no egress, so
the detector stays quiet: presence did not complete a trifecta. But
the human's obligations change completely, and that is the point of
running the two stages side by side.

- **Injection becomes possible, and the harm is a corrupted brief.**
  No egress and no write tools, so a hostile e-mail cannot exfiltrate.
  It can make the brief say "the customer agreed to the discount." The
  brief is a decision input; bounded harm, but real. The defense is
  citation discipline — every claim quotes and cites its source so the
  human can check, which `prompts/pikuri-briefing.txt` already
  demands for notes and would have to demand for mail.
- **Adding mail automates away the step that made the agent
  one-legged.** The user's hand-curation — reading correspondence,
  deciding what matters, writing it down in their own words — *is* the
  human-author step from
  [`private-context-taint.md`](private-context-taint.md), and it is
  what makes `trusted: true` honest. That is the honest trade; write
  it down as such rather than as a feature. (`book/rag.md` states the
  trade; Stage 1 is where it is paid.)
- **"Correspondence with that customer" is a prompt promise, not an
  enforced boundary — and Stage 1 should ship it that way.**
  `thunderbird_mail_search` searches the whole Gloda index, so the
  private pool jumps from "notes about customers" to *the entire
  mailbox*. Presence is binary, strength is not, so this is a pure
  severity move and the teaching has to say so in those words.
  Enforcing per-customer scope needs a **correspondent allowlist** on
  `Thunderbird::Extension` — filter by sender/recipient address or
  domain before results reach the model — and unlike the corpus
  declaration that is a real filter, not a label. **Deferred
  deliberately:** the honest whole-mailbox reading is what makes the
  severity lesson land, and "prompt promise vs. enforced boundary" is
  a distinction worth teaching. Build the filter when a week of real
  use makes the pool intolerable, not before.
- **The same split exists without Thunderbird.** Received documents
  the user wants searchable but will not review as text are the mail
  case in miniature: a second corpus, declared untrusted, on a
  two-legged sibling — `@notes` trusted, `@received` not. Whether the
  untrusted source is a mailbox or a folder of customer decks, the
  shape and the human's obligations are the same.
- **Wire only mail search + mail read.** The extension bundles five
  inbound tools; calendar and contacts add private pool for no
  briefing value the user asked for. (Calendar *would* answer "which
  meeting is coming up" — tempting, and a good example of scope creep
  to resist until asked.)
- **The corpus's private-leg declaration now matters for a reason.**
  In Stage 0 it was cosmetics on a quiet banner. In Stage 1 the
  agent's private leg is real on both sources, and the corpus
  declaration is what keeps the map from under-reporting the pool.
- **No auto-memory, still.** If Stage 0 had grown any, Stage 1 must
  drop it or split the agent — a one-legged `@notes` and a two-legged
  `@mail`, the human carrying facts across. It didn't, so there is
  nothing to undo; the reason is recorded in `book/rag.md`'s "which
  gem *not* to wire".

## Where Stage 1's teaching goes — and it is no longer a chapter

The old plan was `book/briefing.md`, a chapter placed before the
`assistant.md` coda. **That is now wrong, because `book/rag.md` took
the argument that tipped it to a chapter.** The tipping argument was
never the trifecta lesson: it was that no chapter points the reader at
their own real private data and hands them something they would run on
Monday morning. `book/rag.md` does exactly that, and it also absorbed
Stage 0's one-legged map, the local-inference invariant, the
which-gem-not-to-wire lesson and the corpus layout convention.

What is left is the one genuinely missing cell in the book's trifecta
table, and briefing.md's own fallback is the right shape for it: **a
section of `book/trifecta-detector.md`**, sibling to §"One binary,
three verdicts".

The cell: `os-assistant.md` Part 3 adds a leg-holder to an
*already-assembled* trifecta — presence doesn't move, severity does.
Stage 1 adds the untrusted leg to a *one*-legged agent — presence
moves 1 → 2, the verdict stays silent, and the human's obligations
change completely. The detector chapter's worked example
(`pikuri-code`, three verdicts) always has egress present, so **"what
the untrusted leg means on its own" still has no worked example
anywhere in the book**, and Stage 0 → 1 is the cleanest one available.

Write the section once Stage 1 is actually wired — a section teaching
a transition the reader cannot run is a thought experiment, and the
chapter already has one of those.

## The slope to watch

The tempting extension is "and draft the follow-up e-mail from the
brief." That is `assistant.md`'s author→approver slope: a draft built
from (Stage 1) untrusted customer content, one click from egress. If a
draft feature ever appears it belongs to the forced-authorship
handoff — landing in the input box for editing — never a send button
on the brief. In Stage 0 the same feature is merely the convenience
tax (`@comms` does the sending; the human carries the text).

## Graduation homes for what is left

- Stage 1's wiring + the two-stage lesson → a **section** of
  `book/trifecta-detector.md` (see above), plus whatever
  `bin/pikuri-briefing` needs to gain a `--with-mail` flag and a
  mail-citation paragraph in its prompt. A `D_` entry only if the
  flag-vs-second-binary fork turns out to be real.
- The correspondent allowlist → `pikuri-thunderbird/DESIGN.md` (it
  changes the read allowlist) + a `D_` entry if a fork is real — once
  it is built, which is deliberately not now.
- The "not `@private`" point → [`assistant.md`](assistant.md)'s roster
  section, when that note graduates.
