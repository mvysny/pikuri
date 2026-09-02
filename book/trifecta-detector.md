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
the [OS-assistant](os-assistant.md) and [coding-agent](code.md)
chapters, whose wirings are the worked examples here. No new
binary and nothing to install: the detector is already running in
every demo you've started.

## The decision procedure, automated

The security chapter gave you a decision procedure for your own
harness, and its first step was:

> **Count the legs on each agent.** For every agent in your
> design, does it have (a) private data, (b) untrusted content,
> (c) egress?

The detector is that step, done by machine, over the wiring that
actually booted rather than the one you meant to write. That
distinction is the whole value. You can hold a four-tool agent in
your head; `pikuri-code` wires the file tools, `bash`, three
sub-agent-only web tools and three personas — and the question
"can the parent egress?" has a non-obvious answer that turns on a
sandbox setting two files away.

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
own.** This is the rule that makes the map worth printing, because
it turns propagation into something you can *see*. Here is
`pikuri-computer`, the fullest wiring in the book:

```
pikuri-computer [:private, :untrusted_hard, :egress_reviewed]
  calculator []
  read [:private, :untrusted_hard]
  bash [:private, :untrusted_hard]
  fileindex_search [:private, :untrusted_hard]
  thunderbird_mail_search [:private, :untrusted_hard]
  thunderbird_mail_compose [:egress_reviewed]
  RESEARCHER [gate: human_reviewed] [:untrusted_hard, :egress]
    web_search [:untrusted_hard, :egress_vouched]
    fetch [:untrusted_hard, :egress]
```

`RESEARCHER` holds hard `:egress`, but the parent above it reads
`:egress_reviewed` — weaker than its own child's. No tool of
the parent's contributes that level; it arrived from below and got
capped on the way. The layout shows you the discrepancy without a
word of explanation. (Why it capped is the series rule further
down.)

Also worth noting what the egress line *doesn't* say. Exactly one
tool carries the outbound leg, and the map names it. Two dozen
words of threat model about this demo reduce to: the only way
bytes leave is a compose window you look at.

**`[gate: …]` on a sub-agent line is the delegation channel.** Not
an annotation — it's what the parent's inherited egress gets capped
*to*. Without it printed, running with `--no-confirm` would change
the parent's verdict while every visible tag stayed identical: an
effect with no visible cause.

**`[]` means checked and clear.** `calculator []` is not an
unrendered line; it's a tool that was examined and contributes
nothing.

## Reading the advisory

The map carries facts; the one-line advisory above it carries the
meaning:

```
[TRIFECTA: HARD] pikuri-code — private(read, grep, glob, file_list, bash) +
untrusted(read, grep, glob, file_list, bash, skill) + egress(bash). An injection in
what this agent reads can drive an exfiltration. Break a leg:
sever egress (a network-off sandbox), or privilege-separate the
step that reads untrusted content. See book/trifecta-detector.md in this repo.
```

Three things it does deliberately:

- **Names the contributing tools per leg**, so the line points at
  something you can go and change. "You hold egress" is a fact;
  "you hold egress *via bash*" is an action. It is also the half
  that moves when you answer a boot question differently: tell
  `pikuri-code` you wrote the files under this directory yourself
  and `skill` drops out of that `untrusted(...)` list, because the
  skills it loaded from this repo are then your own prose. The
  verdict stays `HARD` — `read` and `bash` still hold the leg — but
  the map stops naming a tool that isn't contributing one.
- **Names the leg to break**, and picks the advice from the
  *cell*, not the severity — a soft verdict reached by a weakened
  untrusted leg wants different advice from one reached by a gated
  egress leg.
- **Logs at `warn`, never `error`.** `pikuri-code` over a private
  repo is loud *by design*; it's a coding agent and you cannot take
  a leg away without breaking the job. Shouting ERROR at a correct
  wiring teaches users that ERROR is normal, which is how you lose
  the ability to say anything.

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
*answer* it, and the two questions `pikuri-code` asks at boot are
exactly that. `Filesystem#trusted?` speaks for the file tools;
`Bundle::Base(trusted:)` speaks for each place skills were loaded
from. Both are unverifiable claims, so both default to the
pessimistic value, and both are claims about *one reachable set*
rather than about "the repo": a workspace that can read
`~/.m2/repository` is honestly untrusted at the same moment the
project's own `.pikuri/skills` beside it is honestly yours.

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

**This is why the demos are quiet.** A public checkout declares no
private leg, so the coding agent's genuine untrusted + egress pair
never completes a trifecta. The alarm stays silent until you point
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

The [OS-assistant chapter](os-assistant.md) ended on a line worth
re-reading:

> The trifecta is **binary in presence** — all three legs live
> means assembled, full stop — and **graded in severity** by the
> size of the private pool sitting beside the egress leg.

Both halves still hold, and the first is the one that kills "we're
probably fine": there is no partial credit for 2.5 legs. But the
severity half is now sharper than pool size alone, because **two
of the three legs come in strengths**:

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

— and one qualifier on the loud cell: it also needs the
destination to be `attacker_reachable`. An agent whose only way
out is a vouched destination is **soft** even at full strength on
the other two axes, because bytes leave but nobody can read them
back.

Or in one sentence: **loud** iff all three legs are at full
strength *and* what leaves can be read back; **soft** iff all
three are present at any strength; **silent** otherwise.

Note what the grid refuses to do. It is monotone in every axis,
and there is no cell for "two legs but they're scary".
Attenuating an axis buys you exactly one step, and only on the
axis that actually carries the exploit.

## What makes a human gate count: payload visibility

Here is the question that decides the egress row, and it is the
most portable idea in this chapter.

A naive reading says: a human is in the path, therefore
`human_reviewed`, therefore soft. Follow that and `Code::Bash`
becomes soft too — it consults its confirmer before every command
— and with it *every* loud verdict in the repo. A detector whose
top severity is unreachable is as useless as one that always
fires.

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
  no attachment support, and [that
  chapter](os-assistant.md)'s hand-off carries only fields that
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

`web_search` is the one bundled tool that declares it, and it's
why its line differs from `fetch`'s in every map in this chapter.
A search query does leave your machine — but it reaches an engine
this repo picked, not a host an injection chose, so a secret can
be pushed out and not read back. That is a real, large reduction
and it is emphatically not safety.

Declare `:tool_vouched` only when all three clauses hold: the
caller cannot choose the destination, that destination does not
republish what it receives, and the request is not
attacker-readable in flight or at rest.

**It only holds while it is the sole egress leg.** Add one
attacker-reachable tool beside it and `max` hardens the whole
node — which is not a special case but the union rule doing its
job, since results that depend on the secret become a targeting
stage the moment anything readable exists. The advisory for this
cell says so out loud rather than letting a soft verdict read as
settled.

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
- **Bandwidth.** A narrow channel is not a safe one. The
  OS-assistant chapter's "too big to hide" section is the long
  version; the short version is that a drip removes the ceiling.

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
absorbs a weakened one.

**A delegation channel is `min`.** This is the series rule, and
it's what capped `RESEARCHER`'s hard egress to `human_reviewed` in
the map earlier. The child's egress cannot exceed the channel
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

## One binary, three verdicts

The clearest way to feel the whole model is `pikuri-code`, whose
verdict moves on **two declarations** and nothing else. Here is
the real output, in order.

One thing to be straight about before you try to reproduce it.
`bin/pikuri-code` **asks you the private question at startup** — on
a TTY, every session, remembered nowhere — so the first two
readings below are the ones you actually get, depending on how you
answer. A question rather than a flag on purpose: a forgotten flag
fails *silent*, and silent is the reading you least want over a
repo full of secrets.

`trusted:` it does **not** expose, and that gap is deliberate too.
The flag covers everything the workspace can *read*, and this
binary's read set is wider than your project — it carries the
toolchain paths (`/usr`, `~/.gem`, `~/.cargo/registry`, …) so the
model can grep a dependency's source. Vouching for your own repo is
a reasonable claim; vouching for every gem and crate you have ever
downloaded is not, and a flag that quietly bundled the second into
the first would be a lie you can type. So the last two readings are
what *your* host gets when it scopes its workspace and declares
them.

**A public checkout — answer no.** Genuine untrusted content,
genuine egress, no private leg. Two legs, silent (tools elided;
the real map lists all of them, plus the `file_miner` and
`git_repo_researcher` personas):

```
Trifecta: pikuri-code — 2 of 3 legs (untrusted, egress); no private leg found.

pikuri-code [:untrusted_hard, :egress]
  read [:untrusted_hard]
  grep [:untrusted_hard]
  glob [:untrusted_hard]
  edit []
  ...
  bash [:untrusted_hard, :egress]
  ...
  researcher [gate: unreviewed] [:untrusted_hard, :egress]
    web_search [:untrusted_hard, :egress_vouched]
    web_scrape [:untrusted_hard, :egress]
    fetch [:untrusted_hard, :egress]
```

**Your real work repo — answer yes.** Now loud, and this is the
only loud reading anywhere in the book:

```
pikuri-code [:private, :untrusted_hard, :egress]
  read [:private, :untrusted_hard]
  ...
  bash [:private, :untrusted_hard, :egress]
```

Read that map against a plausible belief: *the web tools live on
the sub-agent, so the parent can't egress.* The map says
otherwise — `bash` carries `:egress` directly, because Bubblewrap
keeps `--share-net` (a coding agent that can't reach its package
registry is barely a coding agent). Quarantining the web tools
bought **context hygiene, not an egress break.** This is exactly
the kind of belief the detector exists to check, and it's why
egress is read from the sandbox's actual posture rather than from
which tools are nominally "network tools".

**A repo you vouch for** — `private: true, trusted: true`, which
takes a host that scopes its own workspace. Soft:

```
pikuri-code [:private, :untrusted_weakened, :egress]
  read [:private]
  grep [:private]
  ...
  researcher [gate: unreviewed] [:untrusted_hard, :egress]
```

The file tools drop their untrusted leg, so the only untrusted
content reaching the parent comes via the sub-agents — weakened by
the boundary. Still assembled, still warned, one notch down.

Three verdicts, one binary, two declarations. And a fourth reading
that shows they aren't independent of the rest of the wiring: take
that same trusted repo with the sandbox off and it goes **loud
again**. The `trusted:` declaration vouches for what the
*workspace* can reach; an unsandboxed bash reads `~/Downloads`
regardless, so the claim stops being honest and the untrusted leg
comes back hard. All four readings are pinned in
`pikuri-code/spec/pikuri/code/dry_run_spec.rb`, so a wiring change
that moves a verdict fails the build.

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

- **A soft verdict no shipped wiring reaches.** The destination
  axis exists and `web_search` declares it, so you can *see* the
  distinction on any map. But no wiring in this repo is
  search-only: every persona holding `web_search` also holds
  `fetch`, so `max` hardens the node and the soft-by-vouched-
  destination cell never fires here. It is tested from hand-built
  nodes and waits for the first host that wants a search-only
  agent. Naming an axis you can see is worth it; inventing a
  persona so a verdict could fire was not.
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
- **No line for a tool nothing can call.** Boot `pikuri-computer`
  and no line mentions `git_clone`, though the binary registers it:
  it composes the coding extension, which offers that tool to a
  persona this wiring doesn't include. So the tool exists and no
  agent in the tree can invoke it. It gets no line, because the map
  lists legs someone *holds* and an unreachable tool is the absence
  of one.
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

[MCPs revisited](mcp-revisited.md) takes the MCP surface to its
harder shapes — servers whose code you can't read, servers holding
credentials, and the full threat model. It's worth reading right
after this one: foreign tools are the case where the framework
knows least, which is why an MCP tool declares `{untrusted,
egress}` by default and picks up `:private` the moment any
registered server declares it.
