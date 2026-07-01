# More confirmers: human-in-the-loop shapes for the returning third leg

Status: **partly shipped, rest brainstorm.** Staging area for the
human-in-the-loop confirmer ideas surfaced while scoping web access for
`pikuri-os`. **Shipped:** all web quarantined in the `RESEARCHER`
sub-agent (no filesystem), reached via the `agent` tool, gated on the
task prompt before dispatch — `SubAgent::Extension.new(personas:,
confirmer:)` (see [`os-assistant.md`](os-assistant.md) §"Internet
access"). That gate is now the **full author seat**: `Confirmer#decide`
returns `Approved(new_request_detail)` / `Rejected(reason)`, the task is
offered `editable: true` so the human *rewrites* rather than
rubber-stamps, and a decline carries an optional **reject-reason** back
to the model as steering — a channel wired into `Bash` too (see
"Task-prompt gate" below). **Still open** (this file): the URL confirmers
for an LLM-driven `fetch`, and the ingest-axis output gate. Drain into
source + `docs/guide/` as pieces graduate.

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
**egress-axis input confirmation** (see "Task-prompt gate" below) — it
already ships, now as a full author seat with a reject-reason channel.
What remains are the *harder* confirmer shapes this file collects:

1. **An LLM-driven `fetch` on the parent** — the LLM picks the entire URL
   incl. host, so the destination *is* the attack (`exfil.com/?d=<secret>`).
   Can a human-in-the-loop make that safe without the sub-agent hop?
   (Egress axis.)
2. **Untrusted web content entering the private context** — the
   researcher summary flows back to the parent unconfirmed. Can a human
   gate what gets *in*? (Ingest axis.)

(The original list opened with a third item — "make the task-prompt gate
a true author seat plus a reject-reason channel." That one is now built;
its worked-out design is the "Task-prompt gate" section immediately
below.)

The ideas split along two axes. Keeping them distinct is load-bearing: a
confirmer that governs *where bytes go* (egress) is a different mechanism
from one that governs *what bytes come in* (ingest). The shipped gate is
egress-axis; note that for `pikuri-os` egress is the axis that *needed*
protecting (ingest is already accepted — it reads hostile files off disk
today).

## Task-prompt gate — shipped (author seat + reason)

The delegation gate: before the parent dispatches a task to a
network-capable sub-agent, a `Confirmer` confirms the task string. This
is the egress break — the parent's only way to leak private data is to
launder it into the task, and the human approves that. Both refinements
that were deferred here are now built.

### The seam change: a richer-than-bool return

`Confirmer#confirm?` used to return a bare `Boolean`, and the yardoc had
deliberately rejected a richer return. The refinements need two things a
bool can't carry — the *edited* task, and a *decline reason* — so the
primitive is now `Confirmer#decide(request:)`, returning one of two
value types (idiomatic-Ruby "case classes" — two `Data.define`s
dispatched by pattern matching, no shared base):

- `Approved(new_request_detail)` — the (possibly edited) `Request.detail`
  to act on.
- `Rejected(reason)` — the human's optional steering text, or `nil`.

`confirm?` survives as the derived boolean convenience
(`decide(request:).is_a?(Approved)`) for the mutation gates (`Write`,
`ExitPlanMode`) that need neither field. Two orthogonal axes ride the
richer return, and keeping them orthogonal is the point:

- **Reason (universal).** *Any* decline can carry steering back to the
  model as the next observation. Wired into the delegation gate *and*
  `Bash` (a declined command now says *why*), exactly the "useful well
  beyond delegation" the earlier draft called out.
- **Editing (opt-in per request).** `Request` grows an `editable:` flag,
  set `true` only where `detail` is the *verbatim actionable payload* —
  the `agent` task, where `detail == task`. Bash's `"$ <command>"` is a
  decorated display string, not a payload, so it stays reason-only.

Both are distinct from the `:once/:always` scope knob the yardoc still
rejects: that manages *decision fatigue*, this manages *authorship and
steering*. The added axes don't reopen it.

### The terminal chrome, and the sanitizer knife-edge

For an editable task the terminal offers `[y] approve  [e] edit  [n]
reject`; `e` opens the raw task in a Reline-editable buffer, `n` prompts
for the optional reason. But pre-filling that buffer surfaced a sharp
tension worth recording: **the payload sent onward must be raw bytes,
while the terminal must *display* sanitized bytes** (the `Sanitizer`
control-byte defense). Pre-filling an editable line with raw bytes would
reintroduce the very `\rrm -rf ~/` overwrite attack the sanitizer exists
to defang.

Resolution — **the sanitizer's warning set gates the pre-fill**:

- **Clean task** (no warnings): pre-fill the raw task, editable — the
  convenience shape, `[y]/[e]/[n]`.
- **Flagged task** (warnings present): refuse the pre-fill *and* drop the
  bare-approve path — `[e] edit  [n] reject`, where `e` makes the human
  retype from scratch. Forced authorship exactly where it matters most,
  and no raw hostile bytes ever hit the terminal.

Honest limit, in the same spirit as the taint model's "soft, not gone": a
terminal cannot *structurally* forbid a rubber-stamp `y` on a clean task
— the pure no-rubber-stamp author seat is a richer-UI (web) invariant
(see "Open (cross-cutting)"). The warning-gated forced-retype is the
terminal's partial answer, not a proof.

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

## Open (cross-cutting)

- **Where confirmers live.** *Partly answered by the built gate.* The
  existing seam *stretched*: `Confirmer::Request` grew an `editable:`
  flag, and `#decide` now returns `Approved`/`Rejected` instead of a bool
  — no sibling seam was needed for the egress *author seat*. The still-open
  question is whether the *ingest* gate (confirming a returned summary,
  not a mutation about to happen) also fits `Request`/`decide`, or whether
  gating *inbound* content is different enough to want its own shape.
- **The forced-authorship UI contract.** Every idea here that pre-fills
  anything must, by construction, refuse a one-click accept — otherwise
  it decays into the approver seat. That's a UI invariant, not an
  ergonomic preference; state it as such wherever it lands. *Reality
  check from the built terminal:* a terminal can't structurally forbid a
  rubber-stamp keystroke, so it only *partially* honors this — the
  built compromise is to force a full retype for sanitizer-flagged tasks
  (see "Task-prompt gate"). The pure invariant remains a richer-UI (web)
  target.
- **Which of these earns a build.** Leaning: the investigator +
  human-verifier (ingest axis) first — it's the one that makes `pikuri-os`
  materially safer *while keeping web useful*, and it doesn't reopen the
  attacker-controlled-destination hole that the egress-axis ideas
  wrestle with.
