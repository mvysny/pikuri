# More confirmers: human-in-the-loop shapes for the returning third leg

Status: **partly shipped, rest brainstorm.** Staging area for the
human-in-the-loop confirmer ideas surfaced while scoping web access for
`pikuri-os`. **Shipped and graduated — no longer detailed here:** all web
quarantined in the `RESEARCHER` sub-agent (no filesystem), reached via
the `agent` tool, gated on the task prompt before dispatch —
`SubAgent::Extension.new(personas:, confirmer:)` (see
[`pikuri-os.md`](pikuri-os.md) §"Internet access"). That gate is
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
(this file): whether a *parent-level* `fetch` should ever be gated by an
editable-URL confirmer (the author-vs-approver dichotomy is settled by the
shipped seat — only this wiring question remains), the ingest-axis output
gate, and the structured action context on `Request`. Drain into source +
`book/` as pieces graduate.

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
- `book/trifecta-detector.md` — the three legs, the payload-visibility test
  that decides whether a gate counts, and the destination distinction
  (`web_search` reaches an engine pikuri picked, `fetch` a host the model
  chose) that motivates the whole file. Both shipped as
  {Pikuri::Tool::TrifectaLegs}' two egress axes.
- [`pikuri-os.md`](pikuri-os.md) §"Internet access" — "the third
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

## Egress axis — destination control for a `fetch`/scrape

The single question: **who picks the destination host?** If it's ever
the LLM, an injection can point it at an attacker server. A human in the
loop can only help if it moves destination-authorship back to the human.

The author-vs-approver *dichotomy* below is **settled** — the shipped
author seat decided it (see the status note at the top of this file). What
stays open is narrower: whether a *parent-level* `fetch` should ever be
gated by an editable-URL confirmer at all, given that the two wirings
that ship today both answer "no" a different way —

- **pikuri-os** keeps `fetch`/`web_scrape` *off* the parent entirely,
  quarantined in the `RESEARCHER` sub-agent (no filesystem) and reached
  through the task-prompt author seat (`c.add_sub_agent_tool` in
  `bin/pikuri-os`). So there is no parent URL to confirm — the
  egress question was answered by the **sub-agent hop**, the very move
  item 1 of "Why these exist" was probing whether we could *avoid*. We
  didn't avoid it; we leaned on it.
- **pikuri-assistant** puts `fetch`/`web_scrape` *on* the parent
  (`c.add_tool`) with **no URL confirmer at all** — the egress-capable
  shape, a different threat model where the trifecta isn't being broken.

So a parent `fetch` gated by an editable-URL confirmer is the one shape
nobody has built. The two sub-shapes it could take are already decided:

### Pre-filled, editable URL — the safe shape (mechanism shipped)

The LLM proposes a URL; it lands in the human's input box **pre-filled
and editable**; the human edits or accepts, then it fires. Because the
human can rewrite the host, they sit in the *author* seat — clean by
construction, exactly the `private-context-taint.md` result generalized
from egress *payloads* to the fetch *destination*. The pre-fill is pure
convenience (saves typing a long URL the human was going to type anyway).

The **mechanism** this needs already ships — the editable, sanitizer-gated
author seat ({Pikuri::Workspace::Confirmer::Request}'s `editable:` flag +
{Pikuri::Workspace::Confirmer::Terminal}'s pre-fill), applied today to the
`agent` **task string**. Pointing it at a URL instead is a wiring, not a
new primitive. It stays unbuilt only because neither shipping wiring
routes a `fetch` through the parent in a shape that wants it (see above).

### One-click URL approve — the unsafe twin — REJECTED

Drop the editability and it collapses into *approver* mode: the human
only says yes/no to the LLM's URL. **Rejected**, and it's the same
rejection the shipped author seat already enforces (a rubber-stamp is
never the intended path; the terminal even forces a full retype for
sanitizer-flagged payloads). Recorded here because the URL case is where
it's most tempting: a human can't reliably spot a laundered secret in a
plausible-looking URL (`exfil.com/aGVsbG8=/…`, or a redirect chain). The
user's own intuition ("little value in the human editing the URL") is
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
  (instruction → reported-fact, per `book/trifecta-detector.md`); the human is
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
[the security chapter §"The human gate, and why fatigue is the enemy"](../book/security.md).
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

## The barrier is not uniform — its strength varies by action type

A human-in-the-loop gate is only as strong as the human's attention and
comprehension at the moment they approve — and those are **not constant
across actions.** Three factors set where a given confirmer sits on a
weak→strong spectrum, and they compound:

- **Frequency (fatigue).** The rarer the prompt, the more attention each
  gets. Bash fires dozens of times a task → the forty-first is
  rubber-stamped (the whole premise of
  [`bash-confirmer.md`](bash-confirmer.md)). A once-a-session action gets
  real scrutiny.
- **Legibility.** The gate is only as strong as the human's ability to
  *understand what they're approving*. Natural-language actions
  (an email's recipient/subject/body) are fully legible; a bash pipeline
  is often opaque, so even an un-fatigued approval is weak — the human
  can't occupy the author seat competently for something they can't read.
- **Cultural weight / irrevocability.** Some actions carry a built-in
  ceremony. Sending email is weighty and unrecallable, so people re-read
  meticulously; a `web_search` is perceived as read-only and waved
  through ("fan out, get more results").

So the confirmers this file collects do **not** all buy the same safety.
Rough ranking, weakest to strongest: **bash** (frequent + opaque) <
**`fetch`/`web_search`** (frequent-ish, but perceived harmless — the
destination-control problem is *because* the human won't scrutinize a
search) < **email compose** (rare + fully legible + ceremonial). The
compose gate is the strongest human barrier we have — which is partly
*why* the Thunderbird design leans on it (see
[`thunderbird.md`](thunderbird.md) Q10).

**The sharp caveat, so this isn't oversold:** ceremony is a
*quality-assurance* mindset, not a *security-audit* one. People re-read an
email to make it **good** (right recipient, no typos, right tone), not to
detect exfiltration. That catches a blatantly-wrong recipient
(`to=attacker@evil.com`) and gross gibberish, but **not** secrets
laundered into plausible prose, nor a subtle channel (BCC, Reply-To, a
look-alike domain). The barrier is strong on the **recipient** and
**gross** content, soft on **subtle body-exfil**. And the corollary that
bites the forced-authorship contract below: **pre-filling a polished draft
erodes the very ceremony that makes email strong** — a finished draft
flips the human from author to editor and invites "looks good, send." So
the strength premium is *conditional on not fully pre-filling*.

**Mechanical pre-filters shore up the soft spot — machine covers the
invisible, human covers the visible.** The caveat's blind spot (a
look-alike recipient) partly closes with a *deterministic* check, never an
AI verdict: {Pikuri::Sanitizer} already flags the invisible/reordering/
mixed-script classes a human literally cannot see, and a field-scoped
rule can close what Sanitizer punts (e.g. ASCII-only on an *address*
catches the all-Latin `@mícrosoft.com` — affordable there because the
false positives are rare and human-recoverable, unlike on free text).
What stays the human's job is the *visible* look-alike the machine can't
tell from legitimate (`rnicrosoft.com`, a `.net`-for-`.com` swap) — which
is exactly what the ceremony is good at. Worked example:
[`thunderbird.md`](thunderbird.md) Q10's compose recipient guard.

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
