# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for chunkers — the layer converting one document's text into the
    # +Array<String>+ the {Indexer} feeds to the embedder. One ships:
    # {FixedWindow} (sliding-window over whitespace-split words, sized by a
    # {Tokenizer}).
    #
    # == Chunker protocol
    #
    # Duck-typed: +#chunk(text)+ → +Array<String>+ (empty/whitespace-only →
    # +[]+), each element one chunk's verbatim text, no metadata — the {Indexer}
    # wraps each into a {Chunk} with +id+/+source+/+metadata+ at composition.
    #
    # FixedWindow is enough for v1: fancier chunkers (heading-aware, AST-aware,
    # contextual, parent-document) are real quality wins but separately scoped
    # (see +ideas/vectordb-deferrals.md+). The plain token-budgeted window works
    # on every format {Pikuri::FileType.read_as_text} flattens to prose, and the
    # bigger quality lever in practice is the embedder/reranker choice.
    module Chunker
    end
  end
end
