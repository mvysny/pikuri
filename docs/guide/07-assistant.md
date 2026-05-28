# Chapter 7 — pikuri-assistant (stub)

> **Stub chapter.** `pikuri-assistant` exists as a binary in the
> repo, but the surface it integrates — vector-DB recall
> ([chapter 3](03-vectordb.md)), persistent memories
> ([chapter 4](04-memories.md)) — isn't stable yet. This chapter is
> a placeholder until those land. For now: a one-paragraph "what
> it is," and a TBD list of what the full chapter will cover.

You've just read [chapter 6](06-security.md) — the kit, the
trifecta, the decision procedure. `pikuri-assistant` is the first
binary in this guide where the kit's reassurances are
*load-bearing* rather than aspirational: an assistant that
remembers things about you, can look across your notes, and
plugs into MCP servers is an agent with all three legs at the
parent if you're not careful. The chapter that walks it through
end-to-end will be the chapter that shows you which legs each
piece holds, and where the kit cuts.

## What it is, in one paragraph

`pikuri-assistant` is the privacy-conscious-user-facing binary in
the pikuri lineup — a Q&A-shaped sibling to `pikuri-code`, but
without the file-edit / shell stack that makes the coding agent
the dense one. Its toolset, on the design board: vector-DB recall
over your notes (chapter 3), persistent memories about you across
conversations (chapter 4), a curated set of MCP servers you wired
in (chapter 5), and the four bundled tools from chapter 1
(calculator, web search, web scrape, fetch). All four pieces have
been introduced by the time you reach this chapter; the chapter's
job is to show how they compose into a single binary that's
useful for a non-developer audience — somebody who wants an AI
assistant that knows their notes and stays on their machine, not
somebody who wants help refactoring code.

## Why this chapter is a stub

The honest reason: two of the four pieces (`pikuri-vectordb`,
memories) aren't shipped yet, and writing the assistant chapter
without them would either ship inventions or skip the parts that
make `pikuri-assistant` worth a chapter at all. The
[MCP](05-mcp.md) and [security](06-security.md) chapters before
it are real; the assistant chapter waits until the buildup is
real too.

What the full chapter will cover, once the gems land:

- The end-to-end tour: start `pikuri-assistant`, watch it index
  your notes, ask it something that exercises both vector recall
  and memory, see the output.
- The full wiring block — `Pikuri::Agent.new` with the four
  extensions assembled, side by side with `pikuri-code`'s denser
  block from chapter 8, calling out what's the same and what's
  different.
- The trifecta calculus for this binary: which agents in the
  graph hold which legs, where the kit (chapter 6) cuts, what
  the residual risks are.
- The hosted-provider opt-in path: what `--api-key-env` buys you
  if you want to point it at a cloud model, and what changes in
  the privacy posture when you do.
- The split between assistant-shape and code-shape harnesses,
  the choices that shape each, and when to reach for which.

## What's next

The remaining chapters revisit the kit on the
sharper-edges side — [chapter 8 — the in-repo coding
agent](08-code.md) is the dense file/shell/sandbox chapter,
[chapter 9 — security revisited](09-security-revisited.md) closes
on the code-track threat model, and [chapter 10 — MCPs
revisited](10-mcp-revisited.md) wires the GitHub MCP server in
Docker as the worked example for higher-stakes integrations.
