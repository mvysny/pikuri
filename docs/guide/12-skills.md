# Chapter 12 — Agent Skills (stub)

> **Stub chapter.** This is a holding place. The guide doesn't yet
> have a workflow concrete enough to motivate Agent Skills the way
> they deserve — coming back to flesh this out once the assistant
> walkthrough and a few more advanced coding-agent recipes land in
> the guide. For now: a one-paragraph "what they are," a minimal
> `lol` demo, and a TBD list of what a fuller chapter will cover.

## What they are, in one paragraph

[Agent Skills](https://agentskills.io/specification) is a small
standard for packaging "when you see *X*, do *Y*" instructions as
a folder. Each skill is a directory with a `SKILL.md`
(YAML frontmatter — `name`, `description` — followed by a free-form
Markdown body) plus any sidecar files the skill needs. Both
`pikuri-code` and `pikuri-assistant` discover skills at startup
under `.pikuri/skills`, `.claude/skills`, or `.agents/skills`
beneath the project root and the user's home directory.
A skill's description gets advertised to the LLM in an
`<available_skills>` system-prompt block; the `skill` tool loads
the body into the conversation on demand. The same folder works
across `pikuri`, Claude Code, and `pi` — all three implement the
same standard.

## A minimal `lol` skill

The smallest skill that works. Drop this at `~/.claude/skills/lol/SKILL.md`:

```markdown
---
name: lol
description: Reply with "lol" to anything.
---

When the user asks anything, just reply "lol". Nothing else.
```

Restart `pikuri-code` (or `pikuri-assistant`). The boot banner
now reports the skill is loaded. Asking anything should trigger
the model to call `skill(name: "lol")`, load the body into
context, and answer accordingly.

That's the whole mechanism. The `<available_skills>` snippet
tells the model the skill exists; the `skill` tool loads the body
when the model decides the skill applies; the body is just text
that joins the conversation.

## Why this chapter is a stub

The honest reason: a skill is a refactor of *repetition*. The
chapter that motivates skills well is the one where the reader
has used `pikuri-code` or `pikuri-assistant` enough to feel "I
keep retyping the same setup at the start of every session" —
and the guide isn't there yet. A `lol` demo proves the wiring
works, but it doesn't show why anyone would write a real skill.

What a fuller chapter will cover, once the guide has the
workflows to anchor it:

- The anatomy of a `SKILL.md`: what goes in frontmatter vs the
  body, what sidecars (scripts, templates, reference docs) are
  used for, how the body length tradeoff plays out against
  context window pressure.
- The Agent Skills standard itself — how `pikuri`'s
  implementation lines up with Claude Code's and `pi`'s, what's
  portable, what isn't.
- One or two skills the guide author actually uses, with the
  pain that motivated each.
- Discovery order, naming collisions, scoping skills to a
  specific project vs the user's home directory.
- When a skill is the right tool versus when a fresh persona
  ([chapter 2](02-subagents.md)) or an MCP server
  ([chapter 5](05-mcp.md) / [chapter 10](10-mcp-revisited.md))
  would fit better.

Until then: <https://agentskills.io/specification> is the
authoritative reference, and the `pikuri-skills`
[README](../../pikuri-skills/README.md) covers the API surface.

## What's next

This is the last chapter. The natural follow-on is a fleshed-out
version of [chapter 7 — pikuri-assistant](07-assistant.md),
which itself waits on the vectordb and memories gems
stabilising. Until then, the vocabulary you have now
(`Pikuri::Agent`, `Tool`, listeners, the Extension protocol,
configure/bind, sub-agent privilege separation, the kit from
chapter 6, MCP's verifier + synthesizer + per-agent
`mcp_connect`) is enough to read any pikuri-* gem's sources
directly.
