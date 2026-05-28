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
