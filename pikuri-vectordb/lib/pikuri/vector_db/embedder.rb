# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  module VectorDb
    # Thin wrapper over +RubyLLM.embed+. Holds an optional
    # +model+ kwarg, exposes a single +#embed(texts)+ method that
    # always takes an +Array<String>+ and always returns an
    # +Array<Array<Float>>+ (parallel to the input).
    #
    # == Why a wrapper at all
    #
    # +RubyLLM.embed+'s shape isn't fixed: a single-String input
    # returns +vectors+ as a flat +Array<Float>+; an array input
    # returns +Array<Array<Float>>+. The {Indexer} (Phase 7) only
    # ever wants the second shape, and would otherwise have to
    # branch on input type at every call site. Pinning the
    # contract here once means downstream code (Indexer, Search
    # query path) stays simple.
    #
    # The other reason is testability: stubbing +RubyLLM.embed+
    # in every consumer's spec via +define_singleton_method+ is
    # repetitive and fragile (the stub leaks across examples if
    # +after+ blocks aren't disciplined). Routing through this
    # class lets each consumer inject a fake +#embed+ object via
    # dependency injection — much cheaper than monkey-patching
    # ruby_llm in dozens of tests.
    #
    # == Why no batching policy
    #
    # +RubyLLM.embed+ accepts the array verbatim and the provider
    # decides what to do with it (OpenAI batches up to 2048
    # inputs; local llama.cpp processes one at a time but in a
    # single HTTP call). Batching strategy is the {Indexer}'s
    # concern, not this wrapper's — the Indexer slices a large
    # corpus into batches and calls +#embed+ once per batch.
    #
    # == Errors are loud
    #
    # +RubyLLM+'s exceptions (Faraday network failures, provider
    # 4xx / 5xx, auth errors) propagate verbatim. This is internal
    # pikuri code, not an LLM-facing tool, so no
    # +"Error: ..."+ string return path.
    class Embedder
      # @return [String, nil] the embedding model name, or +nil+
      #   to use whichever default +RubyLLM.config.default_embedding_model+
      #   resolves to at call time.
      attr_reader :model

      # @param model [String, nil] embedding model name, e.g.
      #   +"nomic-embed-text-v1.5"+ for a local llama.cpp endpoint,
      #   +"text-embedding-3-small"+ for hosted OpenAI. +nil+
      #   defers to +RubyLLM.config.default_embedding_model+.
      # @return [Embedder]
      def initialize(model: nil)
        @model = model
      end

      # Embed +texts+ as a single call to the underlying provider.
      # Empty input short-circuits to +[]+ — no HTTP round-trip.
      #
      # @param texts [Array<String>] non-nil; every element must
      #   be a String.
      # @return [Array<Array<Float>>] parallel to +texts+. The
      #   i-th vector is the embedding of +texts[i]+.
      # @raise [ArgumentError] if +texts+ isn't an Array, or any
      #   element isn't a String.
      def embed(texts)
        unless texts.is_a?(Array)
          raise ArgumentError, "expected Array<String>, got #{texts.class}"
        end
        return [] if texts.empty?
        unless texts.all? { |t| t.is_a?(String) }
          bad = texts.reject { |t| t.is_a?(String) }.first
          raise ArgumentError, "all elements must be String, got #{bad.class}"
        end

        embedding = @model ? RubyLLM.embed(texts, model: @model) : RubyLLM.embed(texts)
        embedding.vectors
      end
    end
  end
end
