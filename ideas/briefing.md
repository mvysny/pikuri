# Briefing, Stage 1: what the second leg costs

Status: **both stages are built and shipped.** What keeps this note
alive is one unwritten artifact — a section of
`book/trifecta-detector.md` teaching the Stage 0 → Stage 1 transition —
and one deliberate deferral, the correspondent allowlist. Everything
else has graduated:

- `DECISIONS.md` `D_briefing_wiring` — Stage 0's forks, and the
  laundering-pipe argument.
- `DECISIONS.md` `D_briefing_with_mail` — Stage 1's forks: the flag,
  the raise where its dependency fails open, mail + contacts without
  the calendar, one prompt plus a fragment, and the four rejected
  roads (cite-and-stop, absence-over-mail, a `write`/draft tool,
  auto-memory).
- `DECISIONS.md` `D_thunderbird_surfaces` — the `surfaces:` knob Stage
  1 needed, and why the map cannot grade what it buys.
- `DECISIONS.md` `D_corpus_trust_declaration` — the per-corpus
  `private:` / `trusted:` declaration this note motivated.
- `pikuri-thunderbird/DESIGN.md` §leg 3 — narrowing the inbound
  surface reduces severity, not presence.
- [`assistant.md`](assistant.md) — the federation this is a candidate
  first member of (`@customers` / `@accounts`, not `@private`); the
  "not `@private`" point graduates there when that note does.

## The section to write, and its material

`book/trifecta-detector.md`, a section sibling to §"One binary, three
verdicts". Not a chapter: the old plan was `book/briefing.md`, and
`book/rag.md` took the argument that tipped it to chapter size (no
chapter pointed the reader at their own real private data and handed
them something to run on Monday morning) along with Stage 0's
one-legged map, the local-inference invariant, the which-gem-not-to-wire
lesson and the corpus layout convention.

What is left is one genuinely missing cell. `book/os-assistant.md`
Part 3 adds a leg-holder to an *already-assembled* trifecta — presence
doesn't move, severity does. Stage 1 adds the untrusted leg to a
*one*-legged agent: presence moves 1 → 2, the verdict stays silent, and
the human's obligations change completely. The chapter's worked example
(`pikuri-code`, three verdicts) always has egress present, so **"what
the untrusted leg means on its own" has no worked example anywhere in
the book**, and `pikuri-briefing` against `pikuri-briefing --with-mail`
is the cleanest one available — the reader can run both in one sitting.

The spine is the **mute verdict**. On a silent verdict
`Trifecta::Report#advisory` prints presence only — no attribution, no
advice, no footer — so the reader watches the count and the per-tool
rows move while the meaning-carrying half of the report says nothing
new, and has to be told in prose what changed. Points worth making,
each of which the two runs demonstrate rather than assert:

- **Injection becomes possible and the harm is a corrupted brief.** No
  egress and no write tool, so a hostile message cannot exfiltrate; it
  can make the brief say the customer agreed to the discount. Bounded,
  real, and a decision input.
- **A citation is not enough once the sources differ in kind.** A note
  is the user's own writing, recognizable at a glance; a message is
  attacker-authorable text needing an out-of-band check. Hence the
  shipped rule: mark the kind per claim, never merge a note and a
  message into one sentence.
- **Adding mail automates away the step that made the agent
  one-legged.** The hand-curation — reading correspondence, deciding
  what matters, writing it down in one's own words — *is* the
  human-author step from
  [`private-context-taint.md`](private-context-taint.md), and it is
  what makes `trusted: true` honest. The honest trade, not a feature.
- **The pipe was never the tool.** A user pasting a customer's mail
  into a note moves those bytes from the untrusted pool into the
  vouched one by hand, undetectably — which is why the paraphrase rule
  is load-bearing and a `write` tool is permanently unnecessary rather
  than merely deferred.
- **Presence is binary; every severity move here is invisible.**
  Widening the pool from "notes about customers" to the whole mailbox
  and address book, and narrowing the wiring to two surfaces of five,
  both happen beneath the map's resolution — `thunderbird_mail_search`
  alone carries both legs and presence is a union.
- **"Correspondence with that customer" is a prompt promise, not an
  enforced boundary** — and shipping it that way is the point.
- **The corpus's private-leg declaration finally matters.** In Stage 0
  it was cosmetics on a quiet banner; in Stage 1 it is what keeps the
  map from under-reporting a pool that is now real on both sources.
- **The same split exists without Thunderbird.** Received documents
  the user wants searchable but will not review as text are the mail
  case in miniature: `@notes` trusted, `@received` not, on one
  two-legged agent. Mailbox or folder of customer decks, the shape and
  the obligations are identical.

## The one deferral

The **correspondent allowlist** — filter mail by sender/recipient
address or domain, inside the Gloda query rather than over its results
(a post-filter spends the result cap on rows it then discards), with
the contacts surface as its name→address resolver. Unlike the corpus
declaration this is a real filter, not a label, and it is what would
make "correspondence with that customer" true.

**Deferred deliberately:** the honest whole-mailbox reading is what
makes the severity lesson land, and prompt-promise-versus-enforced-
boundary is a distinction worth teaching. Build it when a week of real
use makes the pool intolerable — then `pikuri-thunderbird/DESIGN.md`
(it narrows the read surface) plus a `D_` entry if a fork turns out to
be real.
