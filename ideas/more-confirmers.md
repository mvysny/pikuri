# More confirmers: human-in-the-loop shapes for the returning third leg

Status: **partly shipped, rest brainstorm.** Staging area for the
human-in-the-loop confirmer ideas surfaced while scoping web access for
`pikuri-os`. **Shipped and graduated — no longer detailed here:** all web
quarantined in the `RESEARCHER` sub-agent (no filesystem), reached via
the `agent` tool, gated on the task prompt before dispatch —
`SubAgent::Extension.new(personas:, confirmer:)` (see
[`os-assistant.md`](os-assistant.md) §"Internet access"). That gate is
now the **full author seat**: `Confirmer#ask` returns
`Approved(new_request_detail)` / `Rejected(reason)`, the task is offered
`editable: true` so the human *rewrites* rather than rubber-stamps, and a
decline carries an optional **reject-reason** back to the model as
steering (a channel wired into `Bash` too). The worked-out design has
moved to its permanent homes: {Pikuri::Workspace::Confirmer} and
{Pikuri::Workspace::Confirmer::Terminal} own the per-symbol rationale
(the `#ask` return type, the edit/reason axes, the still-rejected
`:once/:always` fatigue knob, and the sanitizer-gated editable pre-fill),
and CLAUDE.md's **Confirmer seam** owns the invariant. **Still open**
(this file): the URL confirmers for an LLM-driven `fetch`, the
ingest-axis output gate, and the structured action context on `Request`.
Drain into source + `book/` as pieces graduate.

Related, already worked out:

- [`private-context-taint.md`](private-context-taint.md) — the
  load-bearing primitive these all orbit: **the human as _author_, not
  _approver_** of a post-taint egress payload. Authoring is clean by
  construction; approving is not (a human can't judge laundered content).
- [`quarantined-handles.md`](quarantined-handles.md) — the integrity
  dual, and specifically its **"human as reader"** shape (untrusted bytes
  reach the human's eyes without round-tripping through the parent LLM).
  The ingest-axis idea below is its human-in-the-loop cousin.
- [`assistant.md`](assistant.md) §"The central tension" — the
  **forced-authorship handoff knife-edge**: a pre-filled draft the human
  *edits* is convenience; one the human *rubber-stamps* is approver-mode.
  Every idea here lands on one side of that edge or the other.
- [`trifecta-detector.md`](trifecta-detector.md) — the three legs and the
  destination-control distinction (`web_search` pikuri-picks-destination
  vs `fetch` LLM-picks-destination) that motivates the whole file.
- [`os-assistant.md`](os-assistant.md) §"Internet access" — "the third
  leg returns," the deferred chapter these feed.

## Why these exist

`pikuri-os` offers web access behind `--with-internet`, quarantined in the
`RESEARCHER` sub-agent (web tools, no filesystem) and gated by a
confirmation of the *task prompt* before dispatch. That gate is the
**egress-axis input confirmation** — it already ships as a full author
seat with a reject-reason channel (design now in
{Pikuri::Workspace::Confirmer} + CLAUDE.md's Confirmer seam).
What remains are the *harder* confirmer shapes this file collects:

1. **An LLM-driven `fetch` on the parent** — the LLM picks the entire URL
   incl. host, so the destination *is* the attack (`exfil.com/?d=<secret>`).
   Can a human-in-the-loop make that safe without the sub-agent hop?
   (Egress axis.)
2. **Untrusted web content entering the private context** — the
   researcher summary flows back to the parent unconfirmed. Can a human
   gate what gets *in*? (Ingest axis.)

(The original list opened with a third item — "make the task-prompt gate
a true author seat plus a reject-reason channel." That one shipped; its
worked-out design graduated to {Pikuri::Workspace::Confirmer} +
{Pikuri::Workspace::Confirmer::Terminal} and CLAUDE.md's Confirmer seam,
so it is no longer detailed here.)

The ideas split along two axes. Keeping them distinct is load-bearing: a
confirmer that governs *where bytes go* (egress) is a different mechanism
from one that governs *what bytes come in* (ingest). The shipped gate is
egress-axis; note that for `pikuri-os` egress is the axis that *needed*
protecting (ingest is already accepted — it reads hostile files off disk
today).

## Egress axis — destination control for a future `fetch`/scrape

The single question: **who picks the destination host?** If it's ever
the LLM, an injection can point it at an attacker server. A human in the
loop can only help if it moves destination-authorship back to the human.

### Pre-filled, editable URL — the safe shape

The LLM proposes a URL; it lands in the human's input box **pre-filled
and editable**; the human edits or accepts, then it fires. Because the
human can rewrite the host, they sit in the *author* seat — clean by
construction, exactly the `private-context-taint.md` result generalized
from egress *payloads* to the fetch *destination*. The pre-fill is pure
convenience (saves typing a long URL the human was going to type anyway).

### One-click URL approve — the unsafe twin, same knife-edge

Drop the editability and it collapses into *approver* mode: the human
only says yes/no to the LLM's URL. This is the seat both taint notes and
`assistant.md` reject — a human can't reliably spot a laundered secret in
a plausible-looking URL (`exfil.com/aGVsbG8=/…`, or a redirect chain).
The user's own intuition ("little value in the human editing the URL") is
*precisely* the gravitational pull toward this seat; naming it as the
unsafe twin of the editable form — not an interchangeable variant — is
the point of recording it. If a UI offers pre-fill, it must **refuse
one-click send** (force a keystroke through the field) or it has silently
become the approver.

### "Clean URL" auto-approve — REJECTED

Tempting: auto-approve URLs that "look clean" (no query args, tidy path)
and only prompt on suspicious ones. This is the
[killed fetch-whitelist](private-context-taint.md) trap in miniature and
must be recorded as rejected, with the reasoning:

- **Path segments leak** — `host/SECRET` carries data with an empty query
  string.
- **Subdomains leak** — `SECRET.attacker.com`; the DNS resolution alone
  reaches the attacker's authoritative nameserver before any HTTP.
- **A spotless URL is still a sink** — `pastebin.com/raw/x` has no query
  args and is a perfect exfil target (the attacker reads the paste).

Syntax cannot detect **attacker-readability** — that's the
unjudgeable-content problem one level down. The only defensible levers
are the *seat* (author vs approver) and *who picks the destination*
(pikuri vs LLM), never URL shape. A "clean-URL" heuristic trains the user
to trust exactly the URLs an attacker will craft to look clean.

## Ingest axis — human-as-injection-verifier (the promising one)

The idea most worth pursuing, and structurally different from the egress
confirmers above. Shape:

- A **privilege-separated investigator sub-agent** holds the web tools
  and has **no filesystem access** (can't read the private context).
- It researches and returns a **summary**.
- Before that summary is appended to the *parent's* context, the **human
  confirms** it — a human-in-the-loop gate on the untrusted return
  channel. The human is the *reader/verifier*, the
  [`quarantined-handles.md`](quarantined-handles.md) "human as reader"
  shape made into a gate.

Why it's the strongest of the batch:

- **It composes with the existing attenuation.** The summary already
  crosses the sub-agent boundary as `:untrusted → :untrusted_weakened`
  (instruction → reported-fact, per `trifecta-detector.md`); the human is
  a *second* filter on top, not the only one.
- **It gives the human a bounded, reviewable artifact.** One short
  summary to eyeball — a world apart from asking them to adjudicate a raw
  URL or a wall of scraped HTML. The review surface is small enough that
  human attention is actually useful.
- **It keeps the private context off the web side entirely** — the child
  never sees the files, so even a fully-captured child can't read them;
  it can only try to *re-inject* through the summary, which is exactly
  what the human gate is there to catch.

Caveat, stated honestly: a *subtle* injection buried in otherwise
legitimate research text is still the unjudgeable-content problem — the
human can miss it. So this **raises the bar, it does not close the leg**
(same honesty as the taint model's "soft, not gone"). It is a
defense-in-depth layer, not a proof.

Open sub-questions if this graduates:
- Does the parent get the summary *at all* if the human declines, or is
  it dropped entirely (dropped is cleaner — a "declined but summarized"
  state re-leaks)?
- Is the gate per-return or session-sticky ("trust this investigator run
  for the rest of the turn")? Sticky slides toward approver-fatigue.
- Reuse of `pikuri-subagents` (`SubAgentTool` already returns the child's
  text straight into the parent — that return is the exact point to
  interpose the gate).

## Structured action context on the `Request` — the remaining seam gap

The Confirmer's *role* — last-line-of-defense for the parent agent in
`bin/pikuri-code`, where structural defense has run out and the human
gate is what stops a poisoned context from leaking — is documented in
[chapter 6 §"The human gate, and why fatigue is the enemy"](../book/06-security.md).
The two requirements (bother the human only on the genuinely
consequential; be excellent when it does fire) and the dependency on the
rest of the kit carrying the routine load are stated there.

The not-yet-shipped technical piece survives the shipped `#ask` seam
({Pikuri::Workspace::Confirmer}). `Request` today carries a `question` +
optional verbatim `detail` + `editable` flag (plus a `change:` for
diffable writes) — enough for the author seat, but the chrome still
largely *echoes* a caller-built string. To live up to the guide's
"headline the consequence, not the 80-char `curl` pipe" framing, the
`Request` wants **structured action context** (kind: write / bash /
fetch; target path or URL; egress destination; in/out of workspace), so
the seam can *render* the load-bearing presentation rather than echoing
whatever the caller built. Composes with the per-pattern stickiness
wishlist in [`bash-confirmer.md`](bash-confirmer.md)
§"Permission-model granularity" — sticky rules key naturally on
structured fields, badly on raw strings.

## Open (cross-cutting)

- **Where confirmers live.** *Partly answered by the built gate.* The
  existing seam *stretched*: `Confirmer::Request` grew an `editable:`
  flag, and `#ask` now returns `Approved`/`Rejected` instead of a bool
  — no sibling seam was needed for the egress *author seat*. The still-open
  question is whether the *ingest* gate (confirming a returned summary,
  not a mutation about to happen) also fits `Request`/`ask`, or whether
  gating *inbound* content is different enough to want its own shape.
- **The forced-authorship UI contract.** Every idea here that pre-fills
  anything must, by construction, refuse a one-click accept — otherwise
  it decays into the approver seat. That's a UI invariant, not an
  ergonomic preference; state it as such wherever it lands. *Reality
  check from the built terminal:* a terminal can't structurally forbid a
  rubber-stamp keystroke, so it only *partially* honors this — the
  built compromise is to force a full retype for sanitizer-flagged tasks
  (see {Pikuri::Workspace::Confirmer::Terminal}). The pure invariant
  remains a richer-UI (web) target.
- **Which of these earns a build.** Leaning: the investigator +
  human-verifier (ingest axis) first — it's the one that makes `pikuri-os`
  materially safer *while keeping web useful*, and it doesn't reopen the
  attacker-controlled-destination hole that the egress-axis ideas
  wrestle with.
