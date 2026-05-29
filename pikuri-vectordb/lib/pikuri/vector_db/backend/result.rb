# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Backend
      # A single query hit: the {Chunk} that matched + its cosine
      # similarity score. Returned in descending-score order from
      # any backend's +#query+ method.
      #
      # == Fields
      #
      # * +chunk+ — the stored {Chunk} (id, text, metadata).
      # * +score+ — cosine similarity as +Float+, range
      #   +[-1.0, 1.0]+. For typical sentence-embedder vectors
      #   (all-positive component dimensions after the softmax /
      #   normalization most models bake in) scores stay in
      #   +[0.0, 1.0]+ in practice. 1.0 is exact match; 0.0 is
      #   orthogonal.
      #
      # == Citation
      #
      # {Search} formats hits for the LLM as
      # +result.chunk.source+ (the citation — relative path, URL,
      # or doc ID — see {Chunk}'s +source+ field) +
      # +result.chunk.text+ (the snippet) + the score. The +id+
      # field is opaque and never surfaced; the +metadata+ Hash
      # carries optional extras like offset / page / anchor for
      # callers that want to deep-link.
      #
      # The +score+ is cosine *as returned by a backend's
      # +#query+*. {Search} substitutes the reranker's relevance
      # score here (via +Data#with+) before formatting when a
      # reranker reorders the candidates, so a surfaced score is
      # cosine only in vector-only mode — see {Search}'s
      # "Which score is shown" section.
      #
      # == Why a Data.define
      #
      # Same convention as {Chunk}. A tuple +[chunk, score]+ or
      # a +{chunk:, score:}+ Hash would work at runtime but
      # +result.chunk+ / +result.score+ reads cleaner at call
      # sites, and value-equality is occasionally useful in specs.
      Result = Data.define(:chunk, :score)
    end
  end
end
