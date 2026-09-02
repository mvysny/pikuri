# Briefing, Stage 1: what the second leg costs

Status: **Stage 0 is built and shipped; Stage 1 is designed down to the
wiring, nothing built** — §"What Stage 1 has to build" is the buildable
list, and its forks are settled except where a bullet says otherwise.
The use case: a user gathers meeting notes from all customers
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
  demands for notes. Demanding the same for mail is *not enough*,
  though: a citation says where a claim came from, not what the human
  owes it. See "mark the claim's kind" below.
- **Adding mail automates away the step that made the agent
  one-legged.** The user's hand-curation — reading correspondence,
  deciding what matters, writing it down in their own words — *is* the
  human-author step from
  [`private-context-taint.md`](private-context-taint.md), and it is
  what makes `trusted: true` honest. That is the honest trade; write
  it down as such rather than as a feature. (`book/rag.md` states the
  trade; Stage 1 is where it is paid.)
- **The laundering pipe exists in Stage 1, and the human staffs it.**
  `D_briefing_wiring` kept a `write` tool out because it would pipe
  untrusted bytes into the vouched pool. Stage 1 shows the pipe was
  never really about a tool: paste a customer's mail into a note and
  those exact bytes move from `untrusted: :hard` to `trusted: true`,
  by hand, with nothing able to detect it. So the boot line's "paste
  nothing; paraphrase" does not go stale under `--with-mail` — it
  becomes load-bearing for a *second* reason, and it is the last
  remaining pipe. That is also the argument that keeps `write` out
  permanently rather than pending: the reason is the pool crossing,
  not the tool.
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
  use makes the pool intolerable, not before. Two notes on its shape,
  captured now because they are cheap now and would otherwise be
  re-derived: the filter belongs **inside the Gloda query, never as a
  post-filter over results** — results are ranked and capped, so
  dropping rows afterwards lets the cap be spent on mail that is then
  discarded, and a scoped search quietly returns less than it should;
  and `thunderbird_contact_search` is the natural name→address
  resolver to feed it, which is a reason the `surfaces:` knob below
  keeps contacts separable rather than folded into mail.
- **Wiring two tools instead of five reduces severity *invisibly*.**
  `thunderbird_mail_search` alone already carries
  `private + untrusted_hard`, and presence is a union, so the
  two-tool wiring and the full five-tool wiring print the **same**
  advisory and the same leg count — only the per-tool rows differ.
  The `surfaces:` knob's entire value is therefore unobservable in
  the artifact the reader is being taught to read. This is the same
  lesson as the whole-mailbox bullet from the other side: the map is
  a *presence* instrument, and every severity move Stage 1 makes —
  narrowing the surface, or widening the pool from "notes about
  customers" to the whole mailbox — happens beneath its resolution.
  It is the argument for the boot text naming the pool in words.
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
  to resist until asked.) Today the extension has no way to say that,
  which is Stage 1's one library-code gate — see the `surfaces:` knob
  below.
- **The corpus's private-leg declaration now matters for a reason.**
  In Stage 0 it was cosmetics on a quiet banner. In Stage 1 the
  agent's private leg is real on both sources, and the corpus
  declaration is what keeps the map from under-reporting the pool.
- **No auto-memory, still.** If Stage 0 had grown any, Stage 1 must
  drop it or split the agent — a one-legged `@notes` and a two-legged
  `@mail`, the human carrying facts across. It didn't, so there is
  nothing to undo; the reason is recorded in `book/rag.md`'s "which
  gem *not* to wire".

## What Stage 1 has to build

The library-code gate is **already shipped** —
`Thunderbird::Extension.new(surfaces: %i[mail])` plus `#mail_wired?`
and the per-surface usage snippet, rationale and rejected hand-wiring
in `DECISIONS.md` `D_thunderbird_surfaces`. Everything below is
`pikuri-rag/bin/pikuri-briefing` and its prompt.

- **`--with-mail` on the one binary, not a second binary (decided) —
  and it must fail loud.** Two arguments the earlier draft of this
  note was missing. *The experiment is the diff*: Stage 0 → Stage 1 is
  a controlled experiment, `pikuri-briefing` against
  `pikuri-briefing --with-mail` makes it one word and both readings
  runnable back to back, and two binaries cannot be diffed at runtime.
  *And a wiring cannot lie the way a declaration can*: `D_briefing_wiring`
  rejected flags for `private:` / `trusted:` because a forgotten flag
  fails silent, but those are human *assertions*, where `--with-mail`
  adds a tool that **declares its own legs** — the map moves to
  `2 of 3 legs (private, untrusted)` on its own and the per-tool rows
  show `rag_search [:private]` beside
  `thunderbird_mail_search [:private, :untrusted]`. Default stays the
  pessimistic reading; the flag opts into the bigger pool.
  - The flag does open exactly one new fails-silent hole, and it is
    the `D_` entry's real content. `#configure` deliberately fails
    **open and quiet** — no profile, or no Gloda index, logs at info,
    registers nothing, and the agent still constructs. So
    `--with-mail` on a Thunderbird-less host would print `1 of 3 legs`
    and the reader would believe they had run Stage 1. Right default
    for a general host; wrong for a binary whose whole purpose is
    "the second leg is present now".
  - The fix is **shipped**: `Extension#mail_wired?`, a post-`configure`
    boolean the binary reads and raises on. (The binary must not probe
    with a `Gloda` of its own — that is the two-backends-on-one-
    snapshot-path hazard the extension's "one instance per agent"
    section warns about.)
  - Mechanically the check therefore lands *after* `Agent.new` returns.
    The binary already hoists `rag_ext` to a local for the watcher, so
    hoisting the Thunderbird extension the same way costs nothing —
    just remember that path has an open agent to `close` before
    `exit 2`.
- **The prompt paragraph that becomes a lie.**
  `prompts/pikuri-briefing.txt`'s "You have no way to reach the
  internet, no mail, no calendar: only the notes folder" has one
  clause that is false under the flag, and a prompt lying about the
  agent's own surface is worse than one that says nothing. Cut that
  paragraph down to what is true in *both* stages — no internet, no
  egress, nothing leaves the machine — and append a mail paragraph
  under the flag. The division of labour is already right:
  `Thunderbird::Extension::INBOUND_USAGE` arrives *with* the wiring
  and carries the search discipline and the untrusted-content guard,
  so the binary's own paragraph owns only what no gem can — the
  **asymmetry** between a corpus the user wrote and a mailbox they did
  not. `Rag` knows nothing of mail; `Thunderbird` knows nothing of the
  corpus.
- **Mark the claim's *kind*, not just its source.** The prompt's
  citation rule was written for one vouched source. With two sources
  in one brief a citation no longer tells the human what they owe a
  claim: a note is their own writing, checkable at a glance; a message
  is attacker-authored text that needs verifying out of band. So the
  rule gains a clause — *never merge a note and a message into one
  sentence, and say which kind each claim came from.* "Acme agreed to
  10% (acme-2026-08-14.md; and their 22 Aug mail)" hides that half of
  it is unvouched. This is "the human's obligations change completely"
  made operational in one prompt line, and it is the part a reader can
  watch change between the two runs.
- **What the mail paragraph must say about completeness — and what it
  must not re-invent.** `prompts/pikuri-briefing.txt`'s central method
  is "work from the whole set, not from a sample", guaranteed for
  notes by `rag_find`'s absent cutoff. **`thunderbird_mail_search`
  already solves the capped-page problem** — it fetches `limit + 1`,
  and its header either affirms completeness ("all shown", which the
  model may lean on) or says "more exist" and names the two levers;
  there is deliberately no `page` param, because `bm25, date DESC` is
  not offset-stable across snapshot refreshes and paging tempts the
  model to walk on instead of narrowing. Do not re-derive that. Three
  residues survive it, and they matter here only because a brief is a
  decision input:
  - "All shown" is reachable at any volume for notes, only up to
    `MAX_LIMIT = 50` for mail — so a high-volume correspondent has to
    be covered by a *sequence* of narrowed searches (per month, per
    sender) rather than one exhaustive list. A prompt instruction,
    not a defect.
  - `has_more` has a documented false-negative: the backend
    over-fetches `[limit * 4, 40].max` and dedups *after*, so heavy
    Gmail label duplication can push the (limit+1)th distinct match
    outside the window and print "all shown" on an incomplete page
    (`mail_search.rb`, accepted there). Fine as a search caveat;
    named here because this is the first wiring where it becomes
    "that is everything Acme sent" in front of a human who acts on it.
  - **Absence claims are over the *indexed* mailbox.** Gloda never
    indexes Junk/Trash/Unsent, which `pikuri-thunderbird/DESIGN.md`
    records as a mitigation and never a boundary (with `[Gmail]/Trash`
    at priority 20 as the honest wrinkle). So "no mail from Acme about
    pricing" silently excludes anything the user junked. One clause.
  - And one clause worth adding regardless: search returns a
    **snippet**, so the prompt's discussed-vs-committed rule needs a
    `thunderbird_mail_read` before any commitment claim. A snippet is
    exactly where "we talked about a discount" gets promoted to "we
    agreed to 10%".
- **Context pressure changes kind, not just degree.** Stage 0's inputs
  are hand-written and pre-distilled. `MailRead::MAX_BODY` is 40 KB
  per message, and quote tails re-include prior messages verbatim, so
  walking a six-message thread can mean reading the same text six
  times. The binary's answer to overflow is `exit 1` — sanctioned
  demo crudeness, but the cost is the whole session mid-brief. Not a
  library bug; it is the argument for the mail paragraph pushing
  search-then-targeted-read over thread-walking. Two one-liners ride
  along: `max: 30` was sized for "reads several notes in full" and now
  has two sources to enumerate and read, so it wants a look (not a
  silent hole — `Synthesizer` emits `Event::FallbackNotice`, so
  exhaustion shows in the stream, though never in the brief text
  itself); and the timeline now merges day-granular filename dates
  with exact mail timestamps.
- **Boot text has to carry the obligation change, because the detector
  will not.** Confirmed against `Trifecta::Report#advisory`: on a
  `:silent` verdict it returns presence only — `Trifecta:
  pikuri-briefing — 2 of 3 legs (private, untrusted); no egress leg
  found.` No attribution, no advice, no footer. Between the two stages
  the count moves and the per-tool rows move, while the
  *meaning*-carrying half of the report stays mute. So the flag earns
  a paragraph beside the existing `trusted:`-claim `puts` —
  `D_briefing_wiring` already sanctioned that shape as "cheap, and it
  cannot fail silent".

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

The section's spine is the mute-verdict finding above: the reader runs
the same binary twice, watches the map's count and its per-tool rows
move, reads a verdict line that says nothing it did not say before,
and has to be told — in prose, by the binary and by this section —
that what changed is what *they* now owe every claim in the brief.
That is the honest lesson of a detector that grades capability
presence and not risk.

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
  `book/trifecta-detector.md` (see above), plus the `--with-mail`
  flag, the prompt split and the claim-kind clause in
  `bin/pikuri-briefing`.
- **A `D_` entry for the binary is expected, and the fork it records
  is not the one this note first guessed.** Flag-vs-second-binary
  settles in a paragraph; what earns the entry is that Stage 1 makes
  the binary **invert its dependency's deliberate fail-open** —
  `--with-mail` raises where `Thunderbird::Extension` logs at info and
  carries on — which is this binary's third inversion, so the entry
  has company in `D_briefing_wiring`. It should cite
  `D_thunderbird_surfaces` for the extension half rather than repeat
  it; the two are separable, one being a gem decision and the other a
  wiring decision.
- The `surfaces:` knob → **done**: yardoc for the per-symbol truth,
  `D_thunderbird_surfaces` for the rejected hand-wiring, the
  don't-borrow-`allow_` rule and the map-cannot-grade-it argument.
- The correspondent allowlist → `pikuri-thunderbird/DESIGN.md` (it
  changes the read allowlist) + a `D_` entry if a fork is real — once
  it is built, which is deliberately not now.
- The "not `@private`" point → [`assistant.md`](assistant.md)'s roster
  section, when that note graduates.
