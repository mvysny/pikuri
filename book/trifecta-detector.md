# Measuring the trifecta: what the detector can and can't tell you

Every binary in this book has been printing something you were
never told how to read. Here it is, from the very first
`pikuri-chat` run back in the [first-conversation
chapter](chat.md):

```
Trifecta: pikuri-chat — 2 of 3 legs (untrusted, egress); no private leg found.

pikuri-chat [:untrusted_hard, :egress]
  web_search [:untrusted_hard, :egress_vouched]
  calculator []
  web_scrape [:untrusted_hard, :egress]
  fetch [:untrusted_hard, :egress]
```

That's the **trifecta detector**. It walks the agent you just
wired, tags every tool with the trifecta legs it contributes,
folds the tags up through any sub-agents, and reports whether all
three legs ended up live in one place. Ten `bin/pikuri-*` scripts
print it at boot with no flag.

This chapter is how to read it, what its judgements actually mean,
and — the part that outlasts pikuri — the two questions it asks
about a leg that you can ask about any harness you build.

## Prerequisites

The [security chapter](security.md) for the trifecta itself, plus
the [sub-agents](subagents.md) and [hybrid-retrieval](rag.md)
chapters, whose wirings are the examples here. No new binary and
nothing to install: the detector is already running in every demo
you've started.

## The decision procedure, automated

The security chapter gave you a decision procedure for your own
harness, and its first step was:

> **Count the legs on each agent.** For every agent in your
> design, does it have (a) private data, (b) untrusted content,
> (c) egress?

The detector is that step, done by machine, over the wiring that
actually booted rather than the one you meant to write. That
distinction is the whole value. You can hold a four-tool agent in
your head. The secretary at the end of this book wires nineteen
tools from five gems, and "which of them can send bytes out, and
does a human see those bytes first?" has an answer spread across
their constructors. The map gathers it into one screen.

### What it is not

It reasons about **capability presence**, not data flow. It can
tell you that you hold the ingredients. It can tell you neither
that you are exploitable nor that you are safe. Concretely, it
over-warns and under-warns, and both are structural rather than
bugs to be fixed later:

- **Over-warns.** An egress channel too narrow to carry anything
  meaningful still counts as egress. A workspace you personally
  vetted still counts as untrusted unless you say otherwise.
- **Under-warns**, and these are the two worth memorising:
  - **A single tool that is all three legs internally.** One tool
    that reads your files, consults a remote service and returns
    the result is a complete trifecta on its own. The detector
    unions *across* tools; it does not look inside one.
  - **Private data staged through a file.** Tool A writes a
    secret into the workspace; tool B, which holds no private leg
    at all, reads it back out and sends it. Two tools, neither
    individually alarming, one exfiltration path. Capability
    presence cannot see a data flow that runs through the disk.

So: **smoke alarm, not firewall.** A smoke alarm is worth having
and it does not make a building fireproof.

### Why it only ever warns

The detector never blocks. Not "not yet" — by design, and the
reason is the under-warning above. The moment "no warning" gated
execution, a clean result would start reading as a safety
certificate, and the two blind spots above would become the ones
nobody checks for. A tool that refuses to make a claim it can't
support is more useful than one that makes it convincingly.

The same rule shapes the wording, which is why a clean wiring
gets

```
Trifecta: pikuri-chat — 2 of 3 legs (untrusted, egress); no private leg found.
```

and never "no trifecta detected". The first states a finding and
names what would tip the wiring over. The second is a safety
claim, and it would be a lie.

## Reading the map

The tree is deliberately dumb: facts only, no explanations. Four
rules cover it.

**One line per entry, indented by depth.** Agents and tools share
the shape; sub-agents nest under their parent.

**An agent line shows its *folded* legs; a tool line shows its
own.** The agent line is the union of everything below it, so you
read the verdict off one line and the reasons off the rest. Here is
`pikuri-thunderbird`, the mail demo, over a mailbox:

```
pikuri-thunderbird [:private, :untrusted_hard, :egress_reviewed]
  calculator []
  thunderbird_mail_search [:private, :untrusted_hard]
  thunderbird_mail_read [:private, :untrusted_hard]
  thunderbird_mail_attachment_read [:private, :untrusted_hard]
  thunderbird_contact_search [:private, :untrusted_hard]
  thunderbird_calendar_search [:private, :untrusted_hard]
  thunderbird_calendar_read [:private, :untrusted_hard]
  thunderbird_mail_compose [:egress_reviewed]
  thunderbird_calendar_create [:egress_reviewed]
```

Notice what the egress rows say. Exactly two tools carry the
outbound leg, the map names them, and both are reviewed. Two dozen
words of threat model about this demo reduce to: the only way
bytes leave is a window you look at.

**The folding crosses a sub-agent boundary.** Here is
`pikuri-minions` from the
[sub-agents chapter](subagents.md):

```
pikuri-minions [:untrusted_hard, :egress]
  web_search [:untrusted_hard, :egress_vouched]
  web_scrape [:untrusted_hard, :egress]
  fetch [:untrusted_hard, :egress]
  calculator []
  researcher [gate: unreviewed] [:untrusted_hard, :egress]
    web_search [:untrusted_hard, :egress_vouched]
    web_scrape [:untrusted_hard, :egress]
    fetch [:untrusted_hard, :egress]
```

The researcher's legs are folded into the parent's line along with
the parent's own tools, after the boundary has had its say: what
crosses changes a leg's strength, and the
[propagation section](#propagation-max-in-parallel-min-in-series)
says how.

**`[gate: …]` on a sub-agent line is the delegation channel.** Not
an annotation — it's what the parent's inherited egress gets capped
*to*. `unreviewed` here: the parent writes the researcher's task and
nobody sees it before it runs. A host that shows you each task,
editable, before handing it off prints `[gate: human_reviewed]`, and
the child's egress reaches the parent capped at that. Without the
marker printed, that one setting would change the parent's verdict
while every visible tag stayed identical: an effect with no visible
cause.

**`[]` means checked and clear.** `calculator []` is not an
unrendered line; it's a tool that was examined and contributes
nothing.

## Reading the advisory

The map carries facts; the one-line advisory above it carries the
meaning. No binary in this book boots loud: each one is missing a
leg, or has no way out that skips review *and* reaches the attacker.
So here is one you might build next.
Give `pikuri-chat`'s web tools a `read` over your notes folder,
declared private. The detector is a pure function of the tool tree,
so you don't even have to start the agent to see what it would
print: build the tree from the real tools and render it.

```ruby
notes = Pikuri::Workspace::Workspace.new(
  filesystem: Pikuri::Workspace::Filesystem.new(project_root: File.expand_path('~/notes'), private: true)
)
tools = [Pikuri::Workspace::Read.new(workspace: notes), Pikuri::Web::Search.from_h(nil),
         Pikuri::Tool::CALCULATOR, Pikuri::Web::SCRAPE, Pikuri::Web::FETCH]
node = Pikuri::Trifecta::Node.new(label: 'demo',
                                  tool_legs: tools.to_h { [_1.name, _1.trifecta_legs] })
puts Pikuri::Trifecta.walk(node).render
```

```
[TRIFECTA: HARD] demo — private(read) + untrusted(read, web_search, web_scrape, fetch)
+ egress(web_search, web_scrape, fetch). An injection in what this agent reads can
drive an exfiltration. Break a leg: sever egress (a network-off sandbox), or
privilege-separate the step that reads untrusted content. See
book/trifecta-detector.md in this repo.

demo [:private, :untrusted_hard, :egress]
  read [:private, :untrusted_hard]
  web_search [:untrusted_hard, :egress_vouched]
  calculator []
  web_scrape [:untrusted_hard, :egress]
  fetch [:untrusted_hard, :egress]
```

That is the shape the [security chapter](security.md) warned about,
assembled in five lines: a page can tell the model to read your
notes and `fetch` an attacker's URL with them in the query. Three
things the advisory does deliberately:

- **Names the contributing tools per leg**, so the line points at
  something you can go and change. "You hold egress" is a fact;
  "you hold egress *via fetch*" is an action. Take `web_scrape` and
  `fetch` out of that list and render it again:

  ```
  [TRIFECTA: soft] demo — private(read) + untrusted(read, web_search)
  + egress(web_search). … Break a leg: sever egress outright — bytes still
  leave, they merely reach a destination the attacker cannot read back, and
  one unreviewed attacker-reachable tool re-hardens this node. …

  demo [:private, :untrusted_hard, :egress_vouched]
  ```

  Still assembled, but nothing left can send your notes anywhere an
  attacker reads them. Why that counts for a full step is the
  [destination section](#what-makes-a-destination-safe-can-they-read-it-back).
- **Names the leg to break**, and picks the advice from the
  *cell*, not the severity — the two renders above wanted different
  advice, and so does a soft verdict reached by a weakened untrusted
  leg.
- **Logs at `warn`, never `error`.** A loud wiring can be correct:
  the coding agent in
  [book 2](https://github.com/mvysny/pikuri-workshop/blob/master/book/README.md)
  is loud over a private repo *by design*, since you cannot take a
  leg off a coding agent without breaking the job. Shouting ERROR
  at a correct wiring teaches users that ERROR is normal, which is
  how you lose the ability to say anything.

## Who declares each leg

The three legs are not tagged by the same party, and the split is
principled: **the framework tags what it can determine; you supply
what it can't.**

| Leg | Who | Default |
|---|---|---|
| `:untrusted` — returns content pikuri didn't author | framework | **on** |
| `:egress` — sends bytes to an external sink | framework | **on** |
| `:private` — reads data that may be sensitive | **you** | **off** |

(One nuance, deferred to its own section below: *whether* a tool
reaches a sink is determined, but *where that sink can be* is a
claim its author makes. Two axes are declared, not one.)

The `:untrusted` row is "framework" in the sense that it defaults
**on** and no tool author can quietly switch it off — but you can
*answer* it. `Filesystem#trusted?` speaks for the file tools;
`trusted:` on a corpus speaks for the retrieval tools over it.
Briefing answers yes for a notes folder you wrote yourself; the
secretary answers no for `~/Documents`. Both are unverifiable
claims, so both default to the pessimistic value, and both are
claims about *one reachable set* rather than about "my files": a
corpus that holds `~/Downloads` is honestly untrusted at the same
moment the notes folder beside it is honestly yours.

The asymmetry is not an oversight. Whether a tool reaches a
network sink is a property *of the tool*, and pikuri knows it.
Whether `~/work/my/pikuri` holds secrets or public scratch is a
property *of the data*, and no amount of inspection settles it. So
you declare it, on the workspace rather than on each tool:

```ruby
Pikuri::Workspace::Filesystem.new(project_root: root, private: true)
```

and the file tools reading through that workspace inherit it. A
workspace is not the only object that owns a reachable set of
documents: `VectorDb::Extension.new(source:, private:, trusted:)` takes
the same pair of answers for an indexed corpus, and `vectordb_search` /
`vectordb_read` derive their legs from it the same way
([the vector-DB chapter](vectordb.md#why-this-agent-cant-leak-your-corpus)
has the before-and-after map).

Two consequences worth sitting with:

**This is why the demos are quiet.** `pikuri-chat` holds genuine
untrusted content and genuine egress, but nothing private, so its
pair never completes a trifecta. The alarm stays silent until you point
it at something that matters — which is the moment it's worth
hearing.

**Undeclared is presumed hostile — on the axes the framework can
determine.** A tool that declares nothing is treated as hard
untrusted, with an unreviewed egress leg that reaches anywhere. Silence from a tool author is not
evidence of safety. But the default deliberately stops short of
`private: true`: assuming that would make every wiring loud, and a
detector that always fires is exactly as useless as one that never
does.

There is one narrow exception to "the user declares private", and
it's worth naming so it doesn't read as the rule leaking. The
inbound Thunderbird tools carry `:private` by default. Not because
pikuri inspected your mail — because a *mailbox* is private by
domain, not by configuration. The framework knows because the
tool's subject matter is inherently sensitive.

### What counts as reading the private pool

The private leg grades **what a tool lets an attacker query over
the pool**, not whether any bit at all flows back. That's a
deliberately lenient reading, and the alternative is worse: every
write-ish tool leaks *something* — `write` reveals that a path
existed, `mail_compose` relays a recipient-novelty note — so
counting those would make the leg universal and the alarm
meaningless.

The line falls between `glob`, which carries it, and `write`,
which doesn't. `**/*.pdf` over a home directory *is* the payload:
the attacker chooses the query and gets bulk results back. A
`write` returns one incidental bit about an operation the model
itself initiated. Lenient on purpose; revisit on a concrete attack
vector, not on a symmetry argument.

## A leg's presence is binary. Its strength is not.

Two halves to hold at once:

> The trifecta is **binary in presence** — all three legs live
> means assembled, full stop — and **graded in severity** by the
> size of the private pool sitting beside the egress leg.

The first is the one that kills "we're probably fine": there is no
partial credit for 2.5 legs. But the severity half is sharper than
pool size alone, because **two of the three legs come in
strengths**:

```
untrusted:               none       <  weakened        <  hard
egress_payload_review:   no_egress  <  human_reviewed  <  unreviewed
egress_destination:      no_egress  <  tool_vouched    <  attacker_reachable
```

Two of them belong to the same leg, because "how strong is the
egress leg" turns out to be two questions that don't answer each
other — the next two sections are one each. A gated egress leg is
still a leg: assembled, warned, not silent.

That gives a grid, with `:private` present (without it, nothing
fires at all):

| review ↓ / untrusted → | hard | weakened |
|---|---|---|
| **unreviewed** | **loud** | soft |
| **human_reviewed** | **soft** | soft |

— and one qualifier on the loud cell: the unreviewed bytes must
also reach a destination the attacker can read, *through the same
tool*. An agent whose only unreviewed way out is a vouched
destination is **soft** even at full strength on the other two
axes, because bytes leave but nobody can read them back. And the
egress leg is graded tool by tool, not axis by axis: a vouched
search beside a reviewed compose window is soft, though the agent
holds one unreviewed tool and one attacker-reachable one. Bytes
leave through one tool, so only that tool's own pair decides.

Or in one sentence: **loud** iff all three legs are at full
strength *and* one tool sends unreviewed bytes the attacker can
read back; **soft** iff all three are present at any strength;
**silent** otherwise.

Note what the grid refuses to do. It is monotone in every axis,
and there is no cell for "two legs but they're scary".
Attenuating an axis buys you exactly one step, and only on the
axis that actually carries the exploit.

## What makes a human gate count: payload visibility

Here is the question that decides the egress row, and it is the
most portable idea in this chapter.

A naive reading says: a human is in the path, therefore
`human_reviewed`, therefore soft. Follow that and a shell tool
becomes soft too — book 2's `bash` consults its confirmer before
every command — and with it nearly every loud verdict anyone
builds. A detector whose top severity is unreachable is as useless
as one that always fires.

The tempting rescue is frequency and salience: bash confirmations
arrive by the dozen and get rubber-stamped, a compose window is
rare and irreversible. **Reject that.** It grades the human's
attention, which is the same unmeasurable thing that bars scanner
strength from counting. Grade attention and "trust the approver"
is back, just at a finer grain.

The admissible test is structural:

> **Does the human see the bytes that leave, or only a proxy for
> them?**

- **A compose window → `human_reviewed`.** The payload *is* the
  reviewed artifact. What is on screen is what egresses, byte for
  byte.
- **An editable delegation task → `human_reviewed`.** The task
  string *is* the bytes crossing into the egress-holder's reach.
- **Bash behind a confirmer → stays hard `:egress`.** You approve
  a *command* — a program, not a payload. Behind a pipe, a
  heredoc, `$(…)`, a script file, the bytes that actually leave
  are computed at runtime and were never on screen. Approving
  `curl` approves an *intent*.
- **A mail attachment → hard `:egress`.** A key in a PNG's low
  bits is invisible to any reader. You approved a *filename* and a
  thumbnail — structurally identical to `curl`: a reference to
  bytes nobody saw. (Hypothetical here: pikuri-thunderbird ships
  no attachment support, and its hand-off carries only fields that
  render literally, for exactly this reason.)

The test is derived from structure, not from anyone's diligence,
and — the practical part — it's a question a tool author can
actually answer about their own tool.

## What makes a destination safe: can they read it back?

The second egress question is not about the human at all. It is:

> **If an injection hijacks the model, can it reach the
> attacker?**

Note what that does *not* ask. The tempting version is "who picked
the destination — your code or the model?", and it fails on one
example. A tool that hard-codes a POST to `github.com` picks its
own destination and still hands the bytes over, because a gist is
world-readable. Pinning is *necessary, not sufficient*. So the two
values name the answer to the real question:

- **`:attacker_reachable`** — yes. One rung for both shapes,
  because both answer yes: the model picks the host (`fetch`,
  `bash`, `git_clone`, a compose tool with a free recipient
  field), *or* the destination is fixed but republishes what it
  receives (that gist, a public status page, a DNS lookup whose
  hostname lands in the attacker's nameserver log).
- **`:tool_vouched`** — no. The tool's code fixes the destination
  set and its author vouches that nothing in it hands the bytes to
  a third party.

`web_search` is the one pikuri tool that declares it, and it's
why its line differs from `fetch`'s in every map in this chapter.
A search query does leave your machine — but it reaches an engine
this repo picked, not a host an injection chose, so a secret can
be pushed out and not read back. That is a real, large reduction
and it is emphatically not safety.

Declare `:tool_vouched` only when all three clauses hold: the
caller cannot choose the destination, that destination does not
republish what it receives, and the request is not
attacker-readable in flight or at rest.

**It holds until something beside it is unreviewed *and*
attacker-reachable.** Put `fetch` next to it and the agent is
loud, through `fetch`, which is loud on its own. A *reviewed*
attacker-reachable tool beside it changes nothing: the query
still reaches only the engine, and a compose window still shows
you its bytes. Try to build an exfiltration out of the pair and
each attempt lands on one tool: the secret in a query has no
reader, the search results flow *in*, and whatever the model
hides in a mail it could hide without searching. The advisory
for this cell names what would re-harden it, rather than letting
a soft verdict read as settled.

**Keep the two egress questions apart.** Payload visibility grades
what the *human* saw; the destination grades what the *attacker*
can read. Genuinely orthogonal — a reviewed send to an attacker's
inbox and an unreviewed query to a vouched engine are different
animals, and neither dominates the other. That's why the map has
four egress tags rather than one scale:

```
:egress                    nobody reviewed it, it can reach anywhere
:egress_reviewed           a human saw the exact bytes
:egress_vouched            it can only reach a destination the author vouched for
:egress_reviewed_vouched   both
```

An agent can hold two of them at once. A vouched search beside a
compose window reads `[:egress_reviewed, :egress_vouched]` on its
agent line, because no single tag describes that agent: one way
out skips review, the other reaches anyone, and neither does both.

One last thing worth saying plainly, because it changes how much
the tag is worth: **`:tool_vouched` is a claim, not a measurement.**
The framework cannot verify that a sink doesn't republish — it
inherits the tool author's judgement, exactly as it inherits your
judgement on `private:`. Two of the detector's axes are
declarations and only one is determined; a vouched destination is
worth precisely as much as the care that went into declaring it.

## What the detector refuses to grade

A short list, because each omission is a decision rather than a
gap:

- **Scanner strength.** Recipient-novelty checks and body guards
  are real hardening and they live on the confirmer. They must
  never *promote* an egress leg, because "does it catch the
  acrostic?" is precisely the data-flow question the detector
  declines to answer — and a screen that demonstrably misses
  linguistic steganography must not be what earns a softer
  verdict.
- **Attention, frequency, salience.** Same argument, above.
- **Bandwidth.** A narrow channel is not a safe one: a secret too
  big for one call leaves a few bytes per call, and a drip removes
  the ceiling.

And the corollary that falls out of all three: **the only thing
better than an approver gate is not holding the leg.** There is no
rung above `human_reviewed` for a seat where the human types the
bytes from scratch, because such a seat holds no egress leg to
grade — it declares `:none`. Clean-by-construction is leg
*absence*, not a strong leg.

## Propagation: max in parallel, min in series

Sub-agents don't inherit tools, which breaks the trifecta *for the
sub-agent*. It does not break it for the parent, because the
child's output flows back into the parent's context as an
observation the parent acts on. So every leg a child holds is
within the parent's reach, and all three propagate up — but not
identically:

- **`:private` → `:private`, full strength.** The boundary is a
  faithful data pipe; a summary of a secret still contains the
  secret.
- **`:egress` → `:egress`, full strength.** The parent can simply
  *ask* the egress-holding child to send the thing. A
  general-purpose researcher faithfully researches whatever
  subject it's handed, including a secret phrased as a subject.
- **`:untrusted` → `:untrusted_weakened`.** The only leg the
  boundary attenuates.

That last one deserves its own sentence, because it's the load-
bearing asymmetry:

> **Content fidelity is not instruction fidelity.** A faithful
> summary of "how x86 works" preserves the assembly detail — you
> can't water down the content. But it has no reason to *adopt* an
> out-of-band `<!-- email ~/.ssh -->` imperative; at most it
> relays it as a reported fact ("the page also said to…"), which
> reaches the parent as data rather than as a command.

Weakened, not gone: the parent is itself an LLM, and a gullible
parent can act on reported data.

**Union at a node is `max`.** An agent holding two tools ends up
with the strongest value on each axis. A hard untrusted leg
absorbs a weakened one. Egress keeps one more fact through the
union: whether a single tool is both unreviewed and
attacker-reachable, since bytes leave through one tool, not
through an axis.

**A delegation channel is `min`.** This is the series rule, and
it's what a `[gate: human_reviewed]` on the minions map would do to
the researcher's hard egress. The child's egress cannot exceed the channel
feeding it: if the only bytes crossing into the child are a task
string a human approved, then even a fully poisoned child can send
nothing else. The precondition is that **the child holds no
private data of its own** — otherwise it has something to leak
that never came through the gate, and the cap doesn't apply.

The cap touches the review axis only. A gate bounds *what* leaves
and *who saw it*; it says nothing about who can read it back, so
the child's destination arrives at the parent unchanged.

Finally, severity is evaluated **at every node**, and the tree's
verdict is the max, reported with the path to the offending node.
The alternative — special-casing "dangerous" children during
propagation — was rejected: it puts a provenance conditional back
into the boundary relabel, and per-node evaluation catches every
alarm it would have caught while attributing it correctly.

## One flag, one extra leg, and the same verdict

The clearest way to feel the model is to watch one leg arrive at an
agent that did not have it: what the **untrusted leg means on its
own**, and how much of that the map can say. For that you want the
briefing agent
from the [hybrid-retrieval chapter](rag.md) — the book's only
one-legged wiring — and its flag:

```
./pikuri-rag/bin/pikuri-briefing --source ~/notes
./pikuri-rag/bin/pikuri-briefing --source ~/notes --with-mail
```

The first is the agent you already met: your hand-written meeting
notes, nothing else.

```
Trifecta: pikuri-briefing — 1 of 3 legs (private); no untrusted/egress leg found.

pikuri-briefing [:private]
  rag_search [:private]
  rag_search_keywords [:private]
  rag_read [:private]
  rag_reindex []
```

The second adds read-only local mail and a contact lookup — no
send, no drafts, nothing that leaves the machine:

```
Trifecta: pikuri-briefing — 2 of 3 legs (private, untrusted); no egress leg found.

pikuri-briefing [:private, :untrusted_hard]
  rag_search [:private]
  rag_search_keywords [:private]
  rag_read [:private]
  rag_reindex []
  thunderbird_mail_search [:private, :untrusted_hard]
  thunderbird_mail_read [:private, :untrusted_hard]
  thunderbird_mail_attachment_read [:private, :untrusted_hard]
  thunderbird_contact_search [:private, :untrusted_hard]
```

Presence went from one leg to two. The verdict did not move: still
silent, because two legs are not three and nothing here can send.
And that is the whole lesson — **everything that actually changed
about running this agent is outside what the detector grades.**

### What the silent line does not say

Compare the two first lines. Both are the shape the
["Reading the advisory"](#reading-the-advisory) section described:
on a silent verdict you get presence and nothing else — no attribution
naming which tool brought which leg, no *break a leg* advice, no
footer pointing you at this chapter. The map's rows moved and its
count moved; the sentence a human actually reads got one word
longer.

That is correct behaviour, not a gap to fix. The detector grades
capability presence, and presence is exactly what it reported. But
it means the second command's real consequences have to reach you
some other way — which is why that binary prints four lines of
prose beside the map saying what the pool now is. A map row cannot
carry them.

### What changed, then

**Injection became possible, and the harm is a corrupted brief.**
Nothing can exfiltrate: no egress leg, no write tool. But a brief
is a decision input, and a hostile message can make it say *the
customer agreed to the discount*. Bounded harm, real harm.

**A citation stopped being enough.** The one-legged agent already
quoted and cited every note, and that was sufficient because a
citation and a check were the same act: you wrote the note, you
recognise it at a glance. A message is text somebody else wrote and
sent you, so a claim drawn from one may need checking out of band.
Same citation, different obligation — which is why the two-legged
prompt demands the *kind* per claim and forbids merging a note and
a message into one sentence. "They agreed to 10% (acme-2026-08-14.md,
and their mail of 22 August)" hides that half of it is unvouched.

**Absence stopped being reportable the same way.** Over the notes
the agent can list every one that mentions a thing, so "there is no
note about pricing" is a claim it can stand behind. A mail search
returns ranked matches up to a cap, and mail you junked or deleted
is not searchable at all — so the honest form is "I found no mail
from them about pricing since March", and never the upgrade to
"they never wrote about it".

### Severity moved twice, invisibly

Two changes in that second wiring never reach the map at all, and
they pull in opposite directions.

The private pool jumped from *notes about customers* to **the whole
mailbox and address book**. "Correspondence with that customer" is
what the prompt asks for; the search reaches everything Thunderbird
indexed. That is a prompt promise, not an enforced boundary, and
shipping it that way is deliberate — the honest reading is what
makes this section's point land.

Meanwhile the wiring is *narrower* than it could be: the mail gem
bundles six inbound tools, and the flag takes four. The calendar
is off, though it would answer "which meeting is coming up".

Neither shows, and the reason is arithmetic:
`thunderbird_mail_search` alone declares `private` and
`untrusted: :hard`, and a node's legs are the **union** of its
tools'. Union is idempotent, so every later tool declaring the same
legs is free — five surfaces or two, the count and the advisory are
identical. This is the
["A leg's presence is binary"](#a-legs-presence-is-binary-its-strength-is-not)
section seen from both sides in one wiring, and the same
idempotence holds one level up: *adding* a leg-holder to an
already-assembled trifecta moves nothing either.

### The pipe the map will never see

One more, because it is the one people get wrong. The briefing
agent has no write tool, for the reason the
[hybrid-retrieval chapter](rag.md) gives: an agent that reads
untrusted mail and can write into the notes folder turns a
corrupted brief into durable corpus poisoning, and `write` carries
no leg, so the detector would say nothing.

Now notice that *you* are the same pipe. Paste a customer's e-mail
into a note and those bytes move from a source nobody vouched for
into a folder everything treats as vouched — by hand, undetectably,
and permanently. No tool decision closes that one. It is why the
paraphrase rule is stated in the prompt, printed at boot, and
repeated here.

So: a silent verdict is not a clean bill of health, and this is the
cleanest demonstration in the book. Run both commands, read both
maps, and notice that the detector was right about everything it
claimed and silent about everything that changed.

## Tagging your own tool

If you add a tool, you declare its legs. The declaration happens
in the **constructor**, because that's wiring time — every
collaborator that could decide a leg is already a kwarg there:

```ruby
super(name: 'read', ...,
      trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
        private:   fs.private?,
        untrusted: fs.trusted? ? :none : :hard,
        egress_payload_review: :no_egress))
```

Three rules that are easy to get wrong:

**Ask the collaborator; never read a flag.** The sandbox answers
`#egress?` and `#confined_to_workspace?` for itself; the confirmer
answers `#blocks_on_human?`. Do not inspect an argv for
`--unshare-net` and conclude "no egress".

This one is not hypothetical. The paper version of this analysis
read `--unshare-net` and wrote down "egress severed" — and was
**wrong** for every week until the session-IPC mask shipped:
`systemd-run --user curl` from inside the severed sandbox returned
HTTP 200, because the session bus spawns the fetch *outside* every
namespace. A network namespace binds your process tree, not what
that tree can ask someone else to do on its behalf. The one leg
the framework claims it can determine objectively is the one the
by-hand run got wrong, by reading a flag instead of asking the
object.

**An undeclared tool is presumed hostile.** Which means: declare,
or your demo goes loud over arithmetic. That's not a hypothetical
either — the first real render of this feature printed
`calculator [:untrusted_hard, :egress]`, and every bundled tool
across the gems had to declare before the output meant anything.

**A tool's egress grade is a property of its current field set,**
not a fixed attribute of its name. Add an attachment parameter to
a compose tool and it stops being `human_reviewed`, because the
human no longer sees the bytes. Pin a recipient and it would stop
being `attacker_reachable`. Read both axes from the tool, not from
a table keyed on tool name.

## The edges, stated plainly

Three things are deliberately absent, so you know where the map
goes quiet:

- **No persona in the soft-by-vouched cell.** The destination
  axis exists and `web_search` declares it, so you can *see* the
  distinction on any map. But every persona holding `web_search`
  also holds `fetch`, and that node is loud through `fetch`. They
  hold it for a reason: given snippets alone, a model can loop,
  narrowing its query again and again to learn one fact. One
  shipped binary sits in the cell anyway: the secretary, the book's
  last, whose search returns snippets only, and which lands there
  when you turn its search confirm off. Another way in is a reader
  that makes no request — `web_search` built
  with `page_text: true` brings each result's text back from the
  engine's index, and `web_read_cached` returns it by handle. Put
  that pair on an agent that also holds `read`, and the map drops
  from loud to soft:

  ```
  demo [:private, :untrusted_hard, :egress_vouched]
    read [:private]
    web_search [:untrusted_hard, :egress_vouched]
    web_read_cached [:untrusted_hard]
  ```

  Swap `web_read_cached` for `web_scrape` and the same node is
  loud. No bundled binary wires that pair, and no persona ships for
  it: behind a sub-agent boundary the parent is soft either way,
  because delegation already weakens the untrusted leg. Naming an
  axis you can see is worth it; inventing a persona so a verdict
  could fire was not.
- **No custody axis on writes.** Whether a workspace pointed at a
  synced folder turns a write into egress is answered on paper and
  deliberately unbuilt. The test is custody, not readability: *does
  the recipient differ from the data's owner?* A personal cloud
  sync — your own Syncthing between your own machines — keeps one
  owner throughout, so it is no leg at all; a team Drive or a public
  link changes owner exactly as a mail recipient does, so it is
  plain `attacker_reachable`. Both ends land on answers that already
  exist, and no probe can tell which one *your* folder is. So the
  framework stays quiet, and a host that knows its workspace
  replicates off-owner adds the leg itself from its extension.
- **No line for a tool nothing can call.** A tool registered for
  sub-agents, but named by no persona this wiring includes, exists
  and no agent in the tree can invoke it. It gets no line, because
  the map lists legs someone *holds* and an unreachable tool is the
  absence of one.
  Don't read the omission as a miss. The opposite direction, a
  persona naming a tool nobody registered, is a real bug and stops
  the binary at boot rather than showing up here.

And the caveat from the top, restated because it's the one to
carry out of here: a silent map means *the detector found no
assembled trifecta*, which is not the same as *you are safe*. It
under-warns on a single tool that is all three legs internally,
and on private data staged through a file. Read the map as
evidence, never as a certificate.

## What's next

Briefing with mail had two legs and stayed silent. [The
secretary](secretary.md) holds all three on purpose, a personal
assistant over your documents, mail, calendar and the web, and its
map reads soft: untrusted at full strength, private everywhere, and
every way out either shown to you before it leaves or aimed where no
attacker can read it.

→ Continue to [The secretary](secretary.md).
