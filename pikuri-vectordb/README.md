# pikuri-vectordb

Local-corpus vector search + agentic RAG for the
[pikuri](https://codeberg.org/mvysny/pikuri) AI-assistant toolkit.

> **Status:** skeleton — gem scaffolding only. The
> `Pikuri::VectorDb::Extension` and `vectordb_search` tool are
> being built in subsequent commits. See `IDEAS.md` §"Vector DB /
> RAG" for the design.

Will provide:

- `Pikuri::VectorDb::Extension` — wires a `vectordb_search` tool,
  a `vectordb_read` tool (read one indexed document in full by its
  `source` path — parent-document retrieval), and a
  `vectordb_reindex` tool onto a `Pikuri::Agent` via
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
- Text extraction reuses `Pikuri::FileType.read_as_text` from
  pikuri-core — plain text / Markdown / PDF. HTML extraction
  is a deferred follow-up; v1 corpora skew toward Markdown
  notes and PDF docs in practice.
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
# Or for persistent storage:
#   backend = Pikuri::VectorDb::Backend::Chroma.new(
#     host: 'localhost', port: 8000, collection: 'my-docs',
#   )
agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  c.add_extension(
    Pikuri::VectorDb::Extension.new(
      backend: backend,
      source: '~/notes',
    )
  )
end
```

Collection naming is Chroma-specific so it lives on
`Backend::Chroma.new(collection:)`, not on the Extension —
`Backend::InMemory` has no collection concept.

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
reranker (HTTP `/v1/rerank`). Recommended setup: **one
`llama-server` running in router mode** — started with no
`--model` flag, it serves every GGUF in `~/.cache/llama.cpp/`
from a single port and loads whichever model each request asks
for. Requires a recent enough `llama.cpp` build to include the
[model-management feature](https://huggingface.co/blog/ggml-org/model-management-in-llamacpp);
Ubuntu 26.04+ packages one. The guide's
[chapter 1](../docs/guide/01-chat.md) walks through the setup;
[chapter 3](../docs/guide/03-vectordb.md) adds the embedder and
reranker on top.

If you'd rather pin the reranker in its own process — to avoid
paying the router's unload/reload cost on rerank requests —
`Reranker::LlamaServer` takes its own `endpoint:` argument and
can point at a separate `llama-server`. Otherwise pikuri stays
agnostic: it just needs URLs.

Larger multi-model runtimes (Ollama, LM Studio, ...) expose
OpenAI-compatible endpoints and would also work, but pikuri's
"small enough to audit" ethos keeps the recommended path on
`llama.cpp` alone.

## Further reading

- **Design notes:** `IDEAS.md` §"Vector DB / RAG" at the repo
  root.
- **API reference:** browse the YARD docs at
  <https://rubydoc.info/gems/pikuri-vectordb> (once published),
  or run `bundle exec yard` in this directory for a local copy.
