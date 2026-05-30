# Federation: the user as the trifecta leg-breaker

Status: **brainstorm — nothing designed, nothing built.** The most
speculative note in `ideas/`. It records a topology idea and stress-tests
it against the trifecta work; the federation *shape* is deliberately left
open (the user proposed the idea without one).

Related, already worked out:

- [`trifecta-detector.md`](trifecta-detector.md) — the static check, and
  crucially the **LLM auto-router** propagation rule (a parent that
  dispatches to sub-agents with no human in between unions all three legs
  upward). This note is the inverse topology, and that rule is *why* it
  works.
- [`private-context-taint.md`](private-context-taint.md) — establishes the
  human as **author, not approver** of a post-taint egress payload: clean
  by construction. The federation generalizes that one primitive from
  "egress payloads" to "the entire bus between agents."
- [`memory.md`](memory.md) §"Write-time poisoning" — the "private-only
  agent" whose input stream is all-trusted, where auto-extraction is safe.
  The federation gives that agent a home (`@private` below). Also
  §"shared-vs-private" — the federation is one agent per bucket.
- [`../IDEAS.md`](../IDEAS.md) §"Trifecta — open mitigations" and the
  bundled privilege-separated `RESEARCHER` / `FILE_MINER`.
- Likely home: the `pikuri-assistant` gem — same precedent as `LIBRARIAN`
  and `GIT_REPO_RESEARCHER` ([`CLAUDE.md`](../CLAUDE.md) inventory).

## The idea

The assistant is **not one agent**. It's a *federation* of completely
separate agents, each addressed by name with an `@`-prefix, each with its
own context, memory, tasks, system prompt, and toolset. No single agent
holds all three trifecta legs, and **the only thing connecting any two
agents is the human typing into both.** The user is the router — and
therefore the leg-breaker.

The conversation the user pictured (names invented):

```
@private  remember I need to write an e-mail for a customer,
          and remember this week I'm working on project A

@comms    send e-mail to customer B that the task will be done
          tomorrow; also slack my boss the same thing
```

- `@private` holds the **private** leg: durable personal/episodic memory.
  No egress, no untrusted ingest — purely the user's own words.
- `@comms` holds the **egress** leg: email + Slack. The *content* it sends
  is whatever the user typed in that message ("the task will be done
  tomorrow") — a human-authored payload.

The fact "I'm working on project A" lives in `@private` and **does not
flow** to `@comms` on its own. If the email needs it, the human carries it
across by typing it. That hand-carry is the whole security model.

## Why it works: the human router is the air gap

The trifecta-detector note's load-bearing failure mode is the **LLM
auto-router**: under a parent that dispatches without a human in between,
every leg a child holds is within the parent's reach, so privilege
separation *raises the bar but doesn't break the trifecta*. The federation
is the same building blocks (separate `Agent` instances, separate
toolsets) wired into the **opposite control flow**:

| | sub-agents (today) | federation (this note) |
|---|---|---|
| topology | parent → children | siblings, no parent |
| router | the parent LLM | **the human** |
| inter-agent pipe | observation flows back into parent context | the human re-types |
| trifecta legs | **propagate up** (detector's rule) | **don't propagate** |

Because the connecting pipe is a human who *authors* what they carry,
the federation inherits the private-context-taint result directly: the
human typing "book flight LHR→JFK" — or "tell the customer it's done
tomorrow" — is clean by construction, where an automatic pipe carrying the
same bytes would not be. The trifecta is broken at the machine level (no
agent has three legs; no LLM fuses them); the residual risk is exactly the
minimal, already-accepted one — a human who carries tainted content
without reading it.

## Load-bearing invariants (where it breaks if violated)

These are not ergonomics; they're the security boundary. State them as
invariants or the whole thing collapses back into a monolith with
personalities.

1. **Per-agent context isolation.** Each agent's context contains *only
   its own `@`-addressed thread and its own replies* — never the sibling
   agents' traffic. The human sees a unified, `@`-tagged transcript and
   integrates it in their head; the machine contexts never touch. Violate
   this and one context holds private + untrusted + egress = full trifecta.
2. **No LLM concierge.** Routing is a dumb string-match on `@name`, like
   IRC. The moment an LLM auto-routes un-`@`'d messages, *it* sees every
   agent's output and becomes the full-trifecta context (and re-introduces
   the auto-router propagation the detector warns about). A switchboard
   may be code; it may not be a model.
3. **No agent-to-agent channel, no shared memory store.** The human is the
   *only* permitted bus. A direct `@private → @comms` message, or one
   memory dir both can read, re-fuses the legs without the human-author
   step. (This is also why `@private`'s memory must be private to
   `@private`.)
4. **Never three legs in one agent — not "one leg each."** Two-leg agents
   are fine: `@research = {untrusted, egress}` (reads the web, can search)
   is two legs, no taint needed. The rule is only that no single agent's
   context ever holds all three, and the per-agent detector +
   private-context-taint still operate *inside* each agent to enforce it.

## How it lands the other notes

- **Memory's "private-only agent" gets a home.** `@private` has no
  untrusted ingest by construction, so the write-time-poisoning sink is
  closed there: auto-extraction ("auto-picks what to remember") is *safe*
  in `@private` specifically, and nowhere with egress or untrusted ingest.
  The federation is the structural reason memory can be auto-curated at
  all — it isolates the one agent where that's sound.
- **Taint generalizes.** private-context-taint made the human the author
  of one egress payload; the federation makes the human the author of
  every cross-agent transfer. Same primitive, whole-topology scope.
- **shared-vs-private buckets become agents.** `@private` = private
  personal + episodic memory; a `@team`/coding agent nudges `AGENTS.md`
  (shared ⇒ human-gated write, committed to git); `@comms` = egress;
  `@research` = untrusted+egress lookups. One agent per row of the
  memory-note table.

## The central tension: the convenience tax vs. the author→approver slope

The honest cost: an assistant earns its keep by *remembering context
across the conversation*, and a federation taxes the human to shuttle
facts between agents by hand. The user's own example already pays it (they
re-type "task done tomorrow" to `@comms`), so the tax is accepted in
principle — but how far does it scale? If `@comms` needs the customer's
address, and that lives in `@private`'s memory, the human has to carry it.

The tempting fix is a **handoff**: `@private` emits *"suggested message to
`@comms`: …"* that the human delivers. This is the knife-edge:

- If the human **edits/authors** the pre-filled draft, they stay in the
  clean *author* seat — the handoff is pure convenience (saves typing).
- If the human **rubber-stamps** it, they've slid back to *approver* — the
  role both trifecta notes reject, because a human can't judge laundered
  content (a secret hidden in a plausible-looking draft).

So a handoff, if it exists at all, must *force authorship* (drop the draft
into the input box for editing, never a one-click "send") and must be
framed and measured as ergonomics, not automation. The blind-copy-paste
failure mode is the same slope by hand: nothing stops a user pasting
`@research` output straight into `@comms` unread. The air gap is only as
thick as the human's attention — which is the irreducible residual the
whole trifecta line of notes already accepts.

## Candidate federation shapes (none chosen)

- **Switchboard TUI.** One prompt; `@name` prefix routes; each agent is a
  persistent isolated `Agent`. Un-prefixed message sticks to the
  last-addressed agent or errors asking for a target. Routing is code.
- **Channels.** IRC/Slack-style: each agent is a channel you switch into.
  The `@` is just the channel selector; isolation is per-channel history.
- **Forced-authorship handoff** (layered on either of the above). Agents
  may *propose* a message to a sibling; it lands in the human's input box
  pre-filled and editable, never auto-delivered. The interesting middle —
  reduces the tax without crossing into approver-mode, *if* the UI refuses
  one-click send.

## Open questions

- **Discovery.** How does the user know which agent to address, and each
  agent's leg-profile? Leaning: `@`-autocomplete that lists agents *and
  advertises their legs* ("@comms can send things out — don't paste
  secrets here you don't want sent"). The leg-profile is user-facing
  safety information, not just a label.
- **Who defines the roster?** Fixed bundled set (`@private` / `@comms` /
  `@research`)? User-declared? A persona registry like the sub-agent
  `Persona` record, but instantiated as siblings instead of children?
- **Unified transcript vs. isolated contexts.** The human wants one
  readable scrollback; the agents must each see only their slice. Confirm
  the rendering layer can show the union while feeding each agent only its
  thread — and that nothing in the union view leaks back into a context.
- **Does this fight pikuri's "start slowly" ethos?** A federation is more
  upfront surface than one chat box. Possibly it's a *growth-tier* shape:
  `bin/pikuri-chat` stays single-agent; the federation is what
  `pikuri-assistant` graduates into once the user has private data + comms
  + research to keep apart.
- **Relationship to the sub-agent gem.** Reuse `Agent` + `Persona`
  wholesale, but the orchestration is human, not `SubAgentTool`. Worth a
  paragraph in `COMPARISON.md` so "federation (human-routed siblings)" vs
  "sub-agents (LLM-routed children)" is an explicit, teachable contrast —
  it's the same distinction the detector draws between safe and unsafe
  separation.

## My honest take

What's strong: it's not a new mechanism to get wrong — it's the
human-as-author break the taint note already validated, made into the
top-level UX, and it finally gives auto-memory a context where it's safe.
The machine-level trifecta break is real and clean.

What's shaky: the security collapses entirely if context isolation or
the no-concierge rule is relaxed for convenience, and there will be
pressure to relax both (a smart router, a shared scratchpad, a one-click
handoff all "just make it nicer"). And the convenience tax is real — a
federation that's annoying enough gets worked around by the user
funnelling everything to one over-privileged agent, which is the monolith
again. The design has to make the *safe* path the *low-friction* path, or
it loses to the very habit it's trying to prevent.
