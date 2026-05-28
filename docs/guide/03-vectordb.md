# Chapter 3 — Agentic search and the vector DB (stub)

> **Stub chapter.** The `pikuri-vectordb` gem is mid-flight (the
> chunker, tokenizer protocol, and an in-memory backend have landed;
> the agent-facing search tool and the recipe for pointing it at
> your own corpus haven't). This chapter is a placeholder until the
> surface stabilises — a one-paragraph "what it is," and a TBD list
> of what the full chapter will cover. The chapters that build on
> it ([memories](04-memories.md), [assistant](07-assistant.md)) are
> stubs for the same reason.

The defaults — local llama, no tools that could send your data
out, verified MCPs — are designed to be safe even with real data;
[chapter 6](06-security.md) explains why. If you're uneasy until
then, point any of this at throwaway documents rather than your
actual notes.

## What it is, in one paragraph

`pikuri-vectordb` is the **semantic-search** counterpart to
`grep` — an agent-facing tool that retrieves chunks of text from a
local corpus by meaning rather than by literal substring match.
The gem ships three composable pieces: a **chunker** that splits
documents into overlapping windows (`Chunker::FixedWindow` today,
more shapes later), a **tokenizer** protocol that turns text into
vectors (`Tokenizer::CharHeuristic` for offline tests,
`Tokenizer::LlamaServer` for real embeddings via your local
`llama-server`), and a **backend** that stores chunks and answers
nearest-neighbour queries (`Backend::InMemory` today, persistent
backends later). With all three wired, an agent can ask
*"which paragraphs in my notes mention the off-grid solar
project?"* and get back relevant excerpts even if the word "solar"
never appears verbatim.

## Why this chapter is a stub

The honest reason: the gem isn't done. The chunker + tokenizer +
in-memory backend are in tree; the agent-facing search tool, the
host wiring (how a binary points it at a corpus), and the
worked-example recipe aren't. A chapter written today would have
to invent code that doesn't exist.

What the full chapter will cover, once the surface lands:

- The three-piece architecture: chunker, tokenizer, backend — what
  each owns, what swaps cleanly, what the seams look like.
- The privacy posture: how embedding via your local `llama-server`
  keeps every byte of indexed content on the box, and why that
  matters for "let me ask the agent about my journal."
- Indexing your own corpus: pointing it at a directory of
  Markdown / PDFs / text files, watching it chunk-and-embed,
  inspecting what came out.
- The `search` tool from the LLM's perspective: how a query
  reaches the backend, how results land in the observation, how
  the agent typically chains semantic search with `read` to pull
  the full surrounding text.
- Capacity and performance: what `Backend::InMemory` is realistic
  for vs. when you want a persistent backend, how chunk size and
  overlap trade off precision against recall.
- How it composes with [memories](04-memories.md) — the two pair
  naturally (recall *over* a corpus vs. recall *of* prior
  conversations) but each chapter introduces only its own piece.

## What's next

[Chapter 4 — Memories](04-memories.md) is the other half of the
build-up toward `pikuri-assistant`: while this chapter is about
*recall over a corpus you handed the agent*, the next is about
*recall of facts the agent learned over earlier conversations*.
Both are stubs today, both land together once the gems they
describe stabilise.
