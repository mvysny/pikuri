# Agent Skills (stub)

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

## Two ways a bundle gets invoked

A skill is *model-invoked*. Its description sits in the system
prompt on every turn, forever, so the model can decide the skill
applies and call `skill(name: …)`. That resident cost is what
buys the autonomy.

Some bundles never wanted it. A "generate this week's work log"
prompt is one you fire deliberately, by name — the model has no
business judging when it applies, and paying tokens every turn to
tell it *not* to is the worst of both. Those are **slash
commands**: one `.md` file under `.pikuri/commands` or
`.claude/commands`, invoked by typing `/name`, advertised to
nobody.

```markdown
---
description: Generate a weekly work log from git history.
argument-hint: <project-label>
---

Weekly log for `$ARGUMENTS`, Monday through today, from my commits.
```

Saved as `~/.claude/commands/wh.md`, that is `/wh swingai` in
`pikuri-code`. What it expands to becomes *your* message —
the command is a typing shortcut, not a second kind of
instruction, which is why it lands as a user turn and not as
the `:system` reference text a loaded skill becomes.

The distinction to carry away: **who decides**. If the model
should notice the situation and reach for it, it is a skill and
it costs prompt tokens. If you know when you want it, it is a
command and it costs nothing until you type it. A skill whose
description says "only invoked manually" is a bundle filed on
the wrong surface.

pikuri will not run shell commands out of a command file, the
way Claude Code's `` !`cmd` `` does — a `.md` that arrives with
a cloned repo would otherwise be arbitrary code execution behind
a keystroke. Such a file is refused outright, and so is one
declaring `allowed-tools:`. See the
[trifecta chapter](trifecta-detector.md) for how a command's
bytes are graded once they are in the conversation.

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
  ([the sub-agents chapter](subagents.md)) or an MCP server
  ([the MCP chapter](mcp.md) / [the MCP-revisited chapter](mcp-revisited.md))
  would fit better.

Until then: <https://agentskills.io/specification> is the
authoritative reference, and the `pikuri-skills`
[README](../pikuri-skills/README.md) covers the API surface.

## What's next

The book closes on [pikuri-assistant](assistant.md),
itself still a stub; a fleshed-out version of it — waiting on the
vectordb and memories gems stabilising — is the natural follow-on
to the whole guide. Until then, the vocabulary you have now
(`Pikuri::Agent`, `Tool`, listeners, the Extension protocol,
configure/bind, sub-agent privilege separation, the kit from
the security chapter, MCP's verifier + synthesizer + per-agent
`mcp_connect`) is enough to read any pikuri-* gem's sources
directly.
