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

## A third answer: the model decides, once the project proves relevant

"Model-invoked, so it costs prompt tokens forever" has a middle
setting. Ten skills at a couple of hundred words each is five
kilobytes on every turn, and in any one session nine of them are
about a language you are not writing today. A skill can name the
files it is about:

```yaml
paths:
  - "**/*.rb"
  - "**/*.gemspec"
```

Now it is not in the prompt at all — not its description, not its
name, not a placeholder saying something was left out. The first
time the agent reads or edits a `.rb` file, its description
appears in the conversation and the model can load it. Nothing
happens in your Java project. `/clear` puts it back to sleep.

Patterns follow `.gitignore` rules, which is a good thing to know
before writing one: `build.gradle` with no slash matches at any
depth, `src/main` with a slash is pinned to the project root, and
a bare `ideas` covers everything under it. One trap: `paths: []`
does **not** mean "never advertise" — an empty list, `["**"]`, and
a `paths:` with nothing under it all mean *always*, because that
is how the other harnesses reading this key behave.

This is a relevance filter, not a permission: the agent can reach
a hidden skill any time it reads a matching file, and *it* chooses
which files to read. What it buys is a smaller prompt and fewer
irrelevant instructions competing for attention — not containment.

An inventory that grows mid-conversation may sound unsettling, but
it is not new: `mcp_connect` already adds tools to a running agent
the same way. What arrives here is smaller — a description, never a
body. Loading still takes the deliberate `skill` call.

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

[The messages array is not the prompt](wire.md) is the
debugging chapter, and it opens on a skills bug: a path-triggered
promotion that fired correctly, appended correctly, and reached
the HTTP payload correctly, while the model went on insisting it
could only see five skills. It could. The chapter is about the
step between your messages array and what the model actually
reads — the one place none of your own assertions can reach.
