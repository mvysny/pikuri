# Quarantined handles (opaque variables for untrusted output)

Status: **draft, shelved.** The shape is sketched (this file); nothing
is settled and nothing is built. Parked deliberately because its
payoff is narrow (see "When it applies" — the general assistant is the
*wrong* shape for it). Revisit when a concrete pipeline-shaped agent
actually wants it. Staging area: drain into source + `book/`
only if/when it graduates from draft.

Prior art:

- **Dual LLM pattern** (#4 in *Design Patterns for Securing LLM Agents
  against Prompt Injections*, arXiv 2506.08837, Jun 2025) — the
  privileged LLM orchestrates; a quarantined LLM touches untrusted
  content; the privileged one never sees that content directly.
- **CaMeL** (*Defeating Prompt Injections by Design*, arXiv 2503.18813)
  — the symbolic-variable sharpening: the quarantined output is a
  `$VAR` reference the privileged LLM passes around but cannot read,
  with a capability system governing what each value may flow into.

Siblings already in the repo:

- `book/trifecta-detector.md` + {Pikuri::Trifecta} — the **static** audit
  ("this wiring *could* hold all three legs"), shipped. This note is the
  structural mechanism behind its `:untrusted → :weakened` attenuation
  (see "The integrity dual" below).
- [`private-context-taint.md`](private-context-taint.md) — the
  **dynamic confidentiality** enforcement (private in → sever egress).
  This note is its **integrity** counterpart (untrusted in → sever
  control). Same per-context, structural spirit; opposite axis.
- [`templated-subagent-replies.md`](templated-subagent-replies.md) —
  §"Shape 4 — Declassification = schema-narrowing" below, promoted to
  standalone: the narrow return type *without* handles or a
  `VariableStore`, so it costs a post-processing step at an existing
  choke point rather than the machinery that shelved this note. If that
  one graduates, cut Shape 4 here to a pointer.

## The idea, in one paragraph

A parent agent delegates "read and process this untrusted blob" to a
child agent with a deliberately tiny toolset. The child's result does
**not** flow back into the parent's context as text — that would
propagate any injection in the blob straight up into the orchestrator.
Instead the runtime stores the result and tells the parent: *"stored in
`VAR25`; you can't read it, but you can pass it to tools that accept a
variable reference."* The parent keeps orchestrating turn-by-turn over
the **handle**, never the **value**. There is no `read_variable` tool,
by construction.

This is the Dual-LLM subset, not full CaMeL: pikuri's iterative
ruby_llm loop is not plan-then-execute, so the parent's control flow is
*not* itself un-injectable here — we only keep the untrusted **bytes**
out of the parent. That's a meaningful narrowing to state up front.

## The integrity dual

The detector attenuates the untrusted leg across a sub-agent boundary
(`:hard → :weakened`, {Pikuri::Tool::TrifectaLegs#relabel_inbound}) but
admits the weakening is *soft*: the parent is itself an LLM, and a captured
summarizer can author a re-injection payload — hence soft, not gone. The
handle pattern is the structural version of that attenuation. A captured child's re-injection payload lives **in
the variable**, and the variable's bytes never enter the parent's token
stream — so for the parent the leg is *severed*, not merely weakened.

| | trigger | mechanism | trifecta leg | property |
|---|---|---|---|---|
| `private-context-taint.md` | **private** data enters a context | sever **egress** | the private leg | confidentiality |
| **quarantined handles** | **untrusted** data would enter the parent | keep the **bytes** out (handle only) | the untrusted leg | integrity |

The whole guarantee rests on one invariant — the dual of "no
`read_variable`":

> **No tool may echo a variable's bytes back into the parent's
> context.** Grep-enforceable in the same spirit as the subprocess /
> finalizer seams: a handle-consumer tool returns a *new handle*, a
> *typed declassified value*, or *nothing* — never the raw bytes.

## The hard part: which tools may touch a handle

A variable that can never be touched is useless; a variable that can be
read defeats the point. The safe operations share one principle: **the
variable flows as payload, never as control, and the parent supplies
the structure.** Four shapes:

1. **Handle → handle transforms.** `summarize(VAR12) -> VAR13`,
   `extract_field(VAR12, "price") -> VAR14`. Output stays opaque; the
   parent picks *what* operation, the bytes never surface.
2. **Sinks with a parent-chosen destination + var leaf.**
   `append_to_file(path: <parent literal>, content: VAR12)`. Parent
   owns the destination; the var is only the payload. (If the sink is
   itself egress, `private-context-taint.md`'s rules still apply on top
   — the two models compose. Note the axes don't collide: there the var
   is *private* and the destination is the danger; here the var is
   *untrusted* and the destination is parent-controlled.)
3. **Human as reader.** Render `VAR12` to the *user* via a listener,
   never into the parent's context window. The exact dual of
   `private-context-taint.md`'s "human is the only clean post-taint
   egress / human-as-author": here the human is the clean **reader**.
   The human isn't injectable, so untrusted content reaching their eyes
   is safe — it just must not round-trip through the parent LLM.
4. **Declassification = schema-narrowing.** The only safe way a value
   *re-enters* the parent is forced through a type that can't carry an
   injection: a `Float`, an enum, a regex-bounded short string. Force
   the child to return `{price: Float}` and a Float has no attack
   surface. Every declassification is an injection **bit-channel** (a
   captured child picks which enum value), so it must be rare and
   narrow — but a 4-way enum leaks 2 bits, a world apart from free text.

Shape 4 is also the answer to the obvious usability objection — *real
tasks branch on content* ("if the email is from my boss, do X"). The
answer is not to let the parent read the value; it's to let the
**child** decide and return a typed, narrow verdict. The parent sees
*structure* (type, length, schema), never free text.

## When it applies — and when it doesn't (why it's shelved)

The payoff is narrow, and that's the reason this is parked rather than
pursued. It helps exactly the agents whose job is **orchestration over
opaque payloads** — pipeline-shaped work where the parent never needed
to understand the content:

- "Read these 50 untrusted scraped pages and append a structured row
  per page to a file." Parent orchestrates; bytes never need to land in
  its context.
- "Triage this inbox: for each message, the child returns an enum
  `{spam, personal, work}`; act on the enum." Declassification is
  narrow by design.

It helps **least** in a general conversational assistant — the shape
`bin/pikuri-assistant` actually is. That agent reads → reasons →
responds in one context, and its entire value is that the model *did*
see the bytes. Quarantining the content there removes the thing the
user came for. So the assistant is the wrong home; this wants a
purpose-built, pipeline-shaped agent (more like a future
`pikuri-minions` fan-out than a chat binary).

> The general rule: the more the parent's job is *understanding* the
> untrusted content, the less this helps. The more its job is *routing*
> the content somewhere, the more it does.

## Residual: it protects the parent, not the child

The child is still fully injectable, and every tool the child holds —
and every tool that *accepts a handle* — is driveable by the injection
in the blob. The pattern relocates all the trust into "the child's
toolset + the handle-consumer toolset," which is why tool design (above)
is the crux. It buys parent integrity, nothing more.

## Cost honesty (the over-securing-into-uselessness check)

A variable store + variable-reference substitution in the strict
`Parameters` validator + capability metadata on values + a curated
consumer-tool set + a declassification policy is plausibly the
*heaviest* security feature pikuri could grow — and it fights the
"auditable in an evening" north star harder than the taint model does.
Combined with the narrow payoff, that's the case for shelving. If it
ever graduates, it earns its way in one slice at a time, smallest
first.

## If it graduates: the smallest first slice

The natural seam already exists in `pikuri-subagents`:
`SubAgent::SubAgentTool#execute` today returns the child's final text
**straight into the parent's context** — that *is* the upward
propagation to stop. Minimal end-to-end slice:

- a per-`Agent` `VariableStore` (same lifecycle as `Tasks::List` —
  in-memory, dropped on close; content-as-identifier precedent lives
  there too),
- a persona flag (`returns_handle: true`) so `execute` stores the text
  and returns `"Result in VAR7 — you can't read it; pass it to a tool
  that accepts a variable reference,"`
- and **exactly one** consumer tool to prove the pattern:
  `present_to_user(var:)`, rendering to the terminal via a listener,
  never into the parent context.

That slice is complete and honest — untrusted content reaches the
human's eyes without ever touching the parent LLM — with zero
declassification/schema machinery. Handle→handle transforms and typed
declassification come later, only when a concrete task demands them.

## Open (everything)

- Is there a real pipeline-shaped agent in pikuri's roadmap that wants
  this, or is `pikuri-minions` the only candidate? (If none, stays
  shelved.)
- Variable-reference substitution: does it live below the LLM (runtime
  resolves `VAR12` → value before the tool body runs) or as an explicit
  `Parameters` type? The former is more CaMeL-faithful; the latter is
  more visible in the schema.
- How much *structure* (type/length/schema) the parent may see about a
  handle without it becoming a bit-channel.
- Whether any of this can reuse the taint listener/control machinery
  from `private-context-taint.md` rather than standing up its own.
