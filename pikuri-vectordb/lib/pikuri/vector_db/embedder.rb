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

      # @return [Symbol, nil] the explicit provider symbol (e.g.
      #   +:openai+), or +nil+ to let RubyLLM infer from the model
      #   name. Required by RubyLLM when +assume_model_exists+ is
      #   +true+.
      attr_reader :provider

      # @return [Boolean] whether to bypass RubyLLM's local model
      #   registry. +true+ when pointing at a local llama.cpp
      #   endpoint whose model identifiers (router aliases, HF
      #   repo paths like +"nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0"+)
      #   are not in RubyLLM's built-in catalog.
      attr_reader :assume_model_exists

      # @param model [String, nil] embedding model name, e.g.
      #   +"nomic-ai/nomic-embed-text-v1.5-GGUF:Q8_0"+ for a
      #   local llama-server router, +"text-embedding-3-small"+
      #   for hosted OpenAI. +nil+ defers to
      #   +RubyLLM.config.default_embedding_model+.
      # @param provider [Symbol, nil] explicit provider symbol
      #   (e.g. +:openai+). Required when +assume_model_exists+
      #   is +true+. +nil+ lets RubyLLM infer from the model id.
      # @param assume_model_exists [Boolean] mirrors the chat-side
      #   {Pikuri::Agent::ChatTransport#assume_model_exists} flag.
      #   Set to +true+ for local llama-server endpoints whose
      #   model identifiers are not in RubyLLM's catalog;
      #   otherwise +RubyLLM.embed+ raises +ModelNotFoundError+
      #   before any HTTP call is made.
      # @return [Embedder]
      # @raise [ArgumentError] if +assume_model_exists+ is +true+
      #   but +provider+ is +nil+ (RubyLLM requires the pair).
      def initialize(model: nil, provider: nil, assume_model_exists: false)
        if assume_model_exists && provider.nil?
          raise ArgumentError, 'provider: must be specified when assume_model_exists is true'
        end

        @model               = model
        @provider            = provider
        @assume_model_exists = assume_model_exists
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

        kwargs = {}
        kwargs[:model]               = @model if @model
        kwargs[:provider]            = @provider if @provider
        kwargs[:assume_model_exists] = true if @assume_model_exists

        embedding = kwargs.empty? ? RubyLLM.embed(texts) : RubyLLM.embed(texts, **kwargs)
        embedding.vectors
      end
    end
  end
end
