# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for chunkers — the layer that converts a single
    # source document's text into the +Array<String>+ the
    # {Indexer} then feeds to the embedder. One ships in v1:
    #
    # * {FixedWindow} — sliding-window over whitespace-split
    #   words, sized by a {Tokenizer}. The simplest chunker that
    #   works; v1 default.
    #
    # == Chunker protocol
    #
    # Duck-typed, single method. The {Indexer} consumes any
    # object responding to:
    #
    # * +#chunk(text)+ — return the chunks for +text+ as
    #   +Array<String>+. Empty / whitespace-only input returns
    #   +[]+. Each element is the verbatim text of one chunk;
    #   the chunker carries no metadata. The {Indexer} wraps
    #   each string into a {Chunk} with the appropriate
    #   +id+ / +source+ / +metadata+ at composition time.
    #
    # == Chunker design space (and why FixedWindow is enough for v1)
    #
    # Sophisticated RAG chunkers in the wild include:
    #
    # * **Markdown-heading-aware** — break on +##+ boundaries
    #   so each chunk is a thematically coherent section.
    # * **AST-aware code chunkers** — keep functions / classes
    #   intact rather than mid-method splits.
    # * **Contextual chunking** — prepend a chunk-level summary
    #   ("This is a section about X") before embedding.
    # * **Parent-document retrieval** — index small chunks for
    #   precision but return larger parent regions for context.
    #
    # All real quality wins, all separately scoped features
    # (see IDEAS.md §"Vector DB / RAG" → "Deferred"). v1 ships
    # the simplest token-budgeted sliding window because it
    # works on every text format the {TextExtractor} produces
    # (txt, md, pdf, html — all flattened to plain text upstream)
    # and because the bigger quality lever in practice is the
    # embedder / reranker choice, not the chunker.
    module Chunker
    end
  end
end
