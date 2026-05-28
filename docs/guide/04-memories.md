# Chapter 4 — Memories (stub)

> **Stub chapter.** Persistent memories aren't shipped yet — the
> design is sketched, the gem isn't in tree. This chapter is a
> placeholder until that lands. For now: a one-paragraph "what
> they are," and a TBD list of what the full chapter will cover.
> The [assistant](07-assistant.md) chapter that motivates them
> is a stub for the same reason.

The defaults — local llama, no tools that could send your data
out, verified MCPs — are designed to be safe even with real data;
[chapter 6](06-security.md) explains why. Memories are the
chapter where this reassurance starts to *matter* — you're about
to give the assistant a place to remember things across
conversations. If you'd rather not stake real preferences on
unfinished software, that's also why this chapter is a stub:
there's nothing to point at your data yet.

## What they are, in one paragraph

A **memory** is a small piece of text the agent decides is worth
keeping across conversations — a preference ("I drink coffee
black"), a fact about the user ("works in Berlin"), a constraint
("don't recommend restaurants with steps at the entrance"), an
in-flight project status. Where chapter 3's vector DB does
*recall over a corpus you handed it*, memories are *recall of
notes the agent took itself*, indexed and retrieved on relevance.
Pikuri's memories store as plain text on your disk, embed through
the same local `llama-server` that runs your model, and surface
back into context only when the model decides they're relevant
— the same shape `pikuri-vectordb` already does for corpus search,
applied to the agent's own working memory of who it's talking to.
The honest comparison is [hermes-agent's](https://github.com/nousresearch/hermes-agent)
treatment of memory as a primary concept, ported to pikuri's
sensibilities.

## Why this chapter is a stub

The honest reason: the gem isn't in tree. The chapter would have
to invent the surface to walk through it, and that's the kind of
forward-promise the rest of this guide avoids.

What the full chapter will cover, once the gem lands:

- The privacy posture: where memories live on disk, what format
  they're in, how to inspect / edit / delete them by hand.
- The two operations: how the agent decides to *save* a memory,
  and how it decides to *recall* one. (The first is the harder
  problem — a chatty model that saves everything floods its
  working memory; one that saves nothing forgets things you
  explicitly asked it to remember.)
- The relationship to chapter 3's vector DB — memories ride the
  same chunker / tokenizer / backend stack, just with a different
  source (the agent's own notes) and a different surfacing rule
  (per-turn relevance check, not on-demand `search`).
- The trifecta implications: a memory store *is* private data
  (leg a) by definition. The kit from [chapter 6](06-security.md)
  is what keeps that leg from joining the other two on the same
  agent.
- The `forget` story: how the user removes a memory the agent
  shouldn't have saved, and what guarantees pikuri does and
  doesn't make about ever having stored it.
- Prior art: a sober comparison to hermes-agent's memory system
  and Claude Code's `--memory` flag, since those are the closest
  shipped designs and the differences are educational.

## What's next

[Chapter 5 — Your first MCP server](05-mcp.md) is the third
buildup piece toward `pikuri-assistant`: an external tool server
that gives the agent capabilities pikuri itself doesn't ship —
the calendar example introduces the mechanics gently. After that,
[chapter 6 — Security](06-security.md) is the chapter the prefix
reassurances above have been pointing at: read it before pointing
a memory-equipped agent at anything you care about.
