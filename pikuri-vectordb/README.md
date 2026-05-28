# pikuri-vectordb

Local-corpus vector search + agentic RAG for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

> **Status:** skeleton — gem scaffolding only. The
> `Pikuri::VectorDb::Extension` and `vectordb_search` tool are
> being built in subsequent commits. See `IDEAS.md` §"Vector DB /
> RAG" for the design.

Will provide:

- `Pikuri::VectorDb::Extension` — wires a `vectordb_search` tool +
  a `vectordb_reindex` tool onto a `Pikuri::Agent` via
  `c.add_extension(...)` inside the `Agent.new` block.
- `Pikuri::VectorDb::Backend::InMemory` — pure-Ruby cosine over
  `Array<Float>`. The educational default; reads in ~40 lines.
  RAM-only; everything reloads from sources on every boot.
- `Pikuri::VectorDb::Backend::Chroma` — thin Faraday HTTP client
  against a self-hosted ChromaDB. The persistent option.
- `Pikuri::VectorDb::Embedder` — thin wrapper over `RubyLLM.embed`
  so tests can inject a fake without monkey-patching ruby_llm.
- `Pikuri::VectorDb::Reranker::LlamaServer` — optional quality
  knob. Speaks `/v1/rerank` against a cross-encoder model on a
  llama.cpp server. Passing `reranker: nil` to the extension
  skips reranking; retrieval falls back to vector-only top-k.
- `Pikuri::VectorDb::Chunker::FixedWindow` + `Tokenizer::*` —
  the chunking pipeline. Tokenizer is a duck-typed protocol
  (`count(text) -> Integer`) with two impls in v1:
  `Tokenizer::CharHeuristic` (default, ~4 chars/token rule) and
  `Tokenizer::LlamaServer` (POST `/tokenize` against the
  embedder's endpoint).
- `Pikuri::VectorDb::LIBRARIAN` — bundled
  `Pikuri::SubAgent::Persona` constant. Hosts wire it via
  `SubAgent::Extension.new(personas: [..., LIBRARIAN])` — same
  shape `pikuri-code` uses for `GIT_REPO_RESEARCHER`.

## Install

```ruby
# Gemfile
gem 'pikuri-vectordb'
```

## Usage (preview — not yet wired)

```ruby
require 'pikuri-core'
require 'pikuri-vectordb'

backend = Pikuri::VectorDb::Backend::InMemory.new
agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(
    Pikuri::VectorDb::Extension.new(
      backend:    backend,
      sources:    ['~/notes', '~/docs'],
      collection: 'my-docs',
    )
  )
end
```

For hosts that want recall behind a privilege-separated sub-agent
(the trifecta-defense pattern — see `SECURITY.md` and `IDEAS.md`
§"Vector DB / RAG"), additionally wire the `LIBRARIAN` persona
via `pikuri-subagents`:

```ruby
require 'pikuri-subagents'

c.add_extension(
  Pikuri::SubAgent::Extension.new(
    personas: [Pikuri::VectorDb::LIBRARIAN]
  )
)
```

## Three model endpoints

A full assistant setup wants three LLM endpoints: chat (via
`ruby_llm`), an embedder (via `RubyLLM.embed`), and an optional
reranker (HTTP `/v1/rerank`). Three serving options the user can
pick (pikuri stays agnostic — it just needs the URLs):

- **Three llama-server processes** on different ports. Simplest,
  parallel, needs the RAM/VRAM headroom.
- **[llama-swap](https://github.com/mostlygeek/llama-swap).** One
  port, lazy-loads on request. Sequential — first query after a
  chat turn pays the load latency — but fits on a small box.
- **Ollama / LM Studio.** Native multi-model with
  OpenAI-compatible endpoints. Works out of the box.

## Further reading

- **Design notes:** `IDEAS.md` §"Vector DB / RAG" at the repo
  root.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-vectordb> (once published),
  or run `bundle exec yard` in this directory for a local copy.
