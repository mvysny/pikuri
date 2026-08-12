# pikuri-assistant (stub)

> **Stub chapter, and the book's coda.** `pikuri-assistant` exists
> as a binary in the repo, but the surface it integrates — vector-DB
> recall ([the vector-DB chapter](vectordb.md)), persistent memories
> ([the memories chapter](memories.md)), MCP ([the MCP chapter](mcp.md)) —
> isn't all stable yet. This chapter is a placeholder until those
> land. For now: a one-paragraph "what it is," and a TBD list of
> what the full chapter will cover.

Every other agent in this book holds at most two of the trifecta's
three legs. The OS assistant ([the OS-assistant chapter](os-assistant.md)) keeps
the disk and severs the network; the coding agent
([the coding-agent chapter](code.md)) keeps the network and confines the disk.
`pikuri-assistant` is the one binary that *reaches for all three* —
an assistant that remembers things about you (private data), looks
across your notes, browses the web, and plugs into MCP servers
(untrusted content + egress) is an agent with the full trifecta at
the parent if you're not careful. That's exactly why it's last, and
why it's still a stub: the chapter that walks it through end-to-end
is the chapter that has to show which legs each piece holds and where
the kit ([the security chapter](security.md)) cuts — and the quarantined
wiring that makes those cuts real isn't built yet (below).

## What it is, in one paragraph

`pikuri-assistant` is the privacy-conscious-user-facing binary in
the pikuri lineup — a Q&A-shaped sibling to `pikuri-code`, but
without the file-edit / shell stack that makes the coding agent
the dense one. Its toolset, on the design board: vector-DB recall
over your notes (the vector-DB chapter), persistent memories about you across
conversations (the memories chapter), a curated set of MCP servers you wired
in (the MCP chapter), and the four bundled tools from the first-conversation chapter
(calculator, web search, web scrape, fetch). All four pieces have
been introduced by the time you reach this chapter; the chapter's
job is to show how they compose into a single binary that's
useful for a non-developer audience — somebody who wants an AI
assistant that knows their notes and stays on their machine, not
somebody who wants help refactoring code.

## Documents: the sandbox takes over from the vector-DB chapter

One piece of the assistant is already real and worth reading now.
[The vector-DB chapter](vectordb.md) plugged PDF support into the extractor
registry with `pikuri-pdf` — in-process, pure Ruby, nothing to
install: training wheels, and the right call for an agent with no
egress reading a corpus *you* chose. The assistant flips both
assumptions: it browses the open web, so the documents it parses
are exactly the bytes an attacker controls. Its wiring therefore
drops `pikuri-pdf` entirely and registers
`Pikuri::Extractors::DOCUMENTS` instead:

```ruby
require 'pikuri-extractors'

Pikuri::Extractors::DOCUMENTS.register
```

Same registry, same one-call pattern you learned in the vector-DB chapter —
but now every conversion runs inside a one-shot **networkless
docker container** (`--network=none --read-only --cap-drop=ALL`,
bytes in via stdin, Markdown out via stdout, no volume mounts), so
a malicious PDF exploiting poppler's parser detonates somewhere
with no network and no filesystem. And the office formats — DOCX,
ODT, XLSX, PPTX, EPUB, RTF — come along in the same registration.
The `--- Page N ---` markers the vector-DB chapter taught you to expect in PDF
output survive the swap; what you give up is lazy paging (the
container re-converts the whole document per `read` window) — the
trade-off table lives in the `Extractors::Documents` yardoc. One
extractor per format per wiring: registering both gems buys
nothing.

## Design note: the corpus, egress, and the librarian

This is the binary that re-opens the problem
[the vector-DB chapter](vectordb.md) dodged. There, the recall agent
(`pikuri-corpus`) had no internet tools at all, so reading your
private corpus was safe by construction — no outbound leg, no
trifecta. The assistant can't take that shortcut: browsing the web
and running MCP servers *is* the point, so it holds egress. Put
`vectordb_search` over your medical notes on that same agent and
you've assembled all three legs — private data, untrusted web
content, and a way to send bytes out — in one context.

The intended shape, therefore:

- **The boss does not hold `vectordb_search` directly.** Corpus
  recall is reachable only by delegating to the bundled
  `LIBRARIAN` sub-agent (the vector-DB chapter), which has `vectordb_search`
  as its *only* tool and no egress of its own. A poisoned chunk it
  retrieves has no hand to act with, and the boss sees a distilled
  paragraph rather than raw chunks.
- **Honest caveat, to be made in full here:** this *raises the
  bar*, it does not by itself *break* the trifecta. The librarian
  faithfully pipes corpus content up to a boss that still has
  egress, so a boss compromised by a poisoned web page could still
  be steered to exfiltrate what the librarian returned. The
  genuine break is a non-LLM decision point between the
  untrusted-input step and the egress step. A human-gated egress
  leg *is* built — it's what the OS assistant's approved research
  task and Thunderbird's compose window are — but it only softens
  the verdict, never silences it: see [the security
  chapter](security.md) and [Measuring the
  trifecta](trifecta-detector.md), which is also where the limits
  of a human in that seat are argued.

**Prerequisite, not yet built.** Wiring the boss *without*
`vectordb_search` while still handing it to the `LIBRARIAN`
sub-agent is impossible under today's persona mechanism: a
sub-agent's tools are a strict subset of the parent's
(`SubAgent::SubAgentTool` filters `parent.tools` by
`persona.tool_names`), so a persona can only narrow, never add. The
fix is **persona-owned tools** — letting a `Persona` carry its own
tool instances — tracked in `ideas/trifecta-detector.md`. Until it
lands, `pikuri-assistant` declares its `pikuri-vectordb` dependency
(the intent) but does not register the corpus tools; the chapter
stays a stub partly for this reason.

## Why this chapter is a stub

The honest reason: memories (the memories chapter) aren't shipped yet, and
the corpus-recall integration is blocked on the persona-owned-tools
prerequisite above — so writing the assistant chapter now would
either ship inventions or skip the parts that make
`pikuri-assistant` worth a chapter at all. (`pikuri-vectordb`
itself *is* shipped — the vector-DB chapter demos it as `pikuri-corpus` — it's
the *quarantined* wiring the assistant needs that waits.) The
[MCP](mcp.md) and [security](security.md) chapters before it
are real; the assistant chapter waits until the buildup is real
too.

What the full chapter will cover, once the gems land:

- The end-to-end tour: start `pikuri-assistant`, watch it index
  your notes, ask it something that exercises both vector recall
  and memory, see the output.
- The full wiring block — `Pikuri::Agent.new` with the four
  extensions assembled, side by side with `pikuri-code`'s denser
  block from the coding-agent chapter, calling out what's the same and what's
  different.
- The trifecta calculus for this binary: which agents in the
  graph hold which legs, where the kit (the security chapter) cuts, what
  the residual risks are.
- The hosted-provider opt-in path: setting `llm_api_key` (and
  `llm_server` / `llm_model`) in `~/.pikuri-examples-config.yaml`
  to point it at a cloud model, and what changes in the privacy
  posture when you do.
- The split between assistant-shape and code-shape harnesses,
  the choices that shape each, and when to reach for which.

## What's next

This is the last chapter as the guide stands — the coda the rest of
the book builds toward. The seams it leans on are all in place: the
file/shell/sandbox/confirmer kit from the OS-assistant and
coding-agent chapters, the trifecta
calculus from [the security chapter](security.md), corpus recall from
[the vector-DB chapter](vectordb.md), memories from
[the memories chapter](memories.md), and MCP from [the MCP chapter](mcp.md).
What's missing is the gem stability and the persona-owned-tools
prerequisite above; once they land, this stub becomes the end-to-end
walkthrough. A further chapter — the OS assistant *with* internet,
where the trifecta's third leg returns — waits on the same taint
machinery this chapter's quarantine needs.
