# Trifecta detector

Status: **designed, not built.** Algorithm is settled (this file);
two parts still open (human-gated-egress primitive; how/where to
surface it in docs + example scripts). This file is the staging
area — as pieces land in source or in `docs/guide/`, cut them from
here so what remains is always "not yet done."

Related, already in the repo:

- [`SECURITY.md`](../SECURITY.md) §"Prompt injection" — the shipped
  structural defense (privilege-separated `RESEARCHER` / `FILE_MINER`).
  The detector *measures* whether that separation actually held for a
  given wiring; it doesn't replace it.
- [`IDEAS.md`](../IDEAS.md) §"Trifecta — open mitigations" — the
  short adjacent-ideas list; this file is the long-form version of
  the structural-check entry.
- [`IDEAS.md`](../IDEAS.md) §"Typed transport classes (private vs
  public)" and §"Egress is broader than `web_search`" — the
  detector's two closest cousins. Transport classes answer "is the
  *LLM endpoint* private?"; the detector answers "does this *agent*
  hold all three trifecta legs?". Egress-is-broad is why the
  `:egress` tag has to be tagged generously.

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
  broader than the obvious senders (see [`IDEAS.md`](../IDEAS.md)
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
  not gone.

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

## Open: the human-gated-egress primitive

Full propagation means privilege separation under an LLM orchestrator
**does not** break the trifecta — it only raises the bar. The genuine
break is a decision point that injection can't drive, sitting *between*
the untrusted-input step and the egress step. That is **not** "a human
launched the agent" — a parent that auto-dispatches is still an
injection-drivable router. It's a human (or other non-LLM gate)
inspecting what crosses the dangerous junction — i.e. egress routed
through a `Workspace::Confirmer`-style seam when the trifecta is
present.

Today egress tools (`web_search`) are stateless and don't confirm. So
"the assistant is the safe shape" is a thing to **build**, not a
property we get for free, and even then it's a bar (injection can try
to social-engineer the human: "ask your assistant to email this to…"),
not a wall. **Open question:** does the detector *only warn*, or does
detecting a present trifecta optionally flip egress tools to
confirm-required? Leaning warn-only for v1, with the confirm-on-egress
as a separate opt-in control — but undecided.

## Open: propagating this to docs + example scripts

The algorithm is settled; how it shows up to a *reader* is not. To
brainstorm next (the *what*, not yet the technical *how*):

- Which `bin/pikuri-*` and `docs/guide/` examples deliberately *should*
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
