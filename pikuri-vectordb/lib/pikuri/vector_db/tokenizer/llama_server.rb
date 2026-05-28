# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Tokenizer
      # Exact tokenization via HTTP POST +/tokenize+ against a
      # llama.cpp server. Faraday wire format:
      #
      #   POST <endpoint>/tokenize
      #   Content-Type: application/json
      #   { "content": "hello world" }
      #   →
      #   200 OK
      #   { "tokens": [123, 456, 789] }
      #
      # +#count+ returns +body['tokens'].length+. Matches the
      # native llama.cpp REST shape — no OpenAI-compat layer
      # needed; the +/tokenize+ endpoint isn't part of the
      # OpenAI spec anyway, so this is llama.cpp's own.
      #
      # == Point this at the embedder, not the chat server
      #
      # Chunking is sized to fit the *embedder's* context (e.g.,
      # bge-small-en-v1.5 has a 512-token limit;
      # text-embedding-3-large has 8192). The chat model's
      # tokenizer would give the wrong number when they're
      # different models. So +endpoint:+ should be the URL of
      # the server hosting the embedder, not the chat model.
      #
      # == Per-string round-trip cost
      #
      # Indexing a 10 MB corpus chunked at 512 tokens ≈ 20k
      # tokenize calls. Each is a few ms on localhost. So
      # indexing pays ~minutes of extra wall time over
      # {CharHeuristic} — one-time cost, paid at boot or
      # explicit reindex. Acceptable; not worth optimizing.
      #
      # == Errors are loud
      #
      # Per CLAUDE.md "Errors are loud": HTTP non-2xx, JSON
      # parse failure, missing +tokens+ key, network failure
      # all raise rather than swallow + return a fudge value.
      # The caller (Chunker) is internal pikuri code, not the
      # LLM; this is bug territory, not "tell the model and
      # let it retry."
      class LlamaServer
        # @param endpoint [String] base URL of the llama.cpp
        #   server, e.g. +'http://localhost:8081'+. The +/tokenize+
        #   path is appended internally.
        # @param connection [Faraday::Connection, nil] optional
        #   dependency-inject for tests. When +nil+, a fresh
        #   Faraday connection is built against +endpoint+ with
        #   the JSON middleware applied.
        # @return [LlamaServer]
        # @raise [ArgumentError] on empty endpoint.
        def initialize(endpoint:, connection: nil)
          raise ArgumentError, 'endpoint must be non-empty' if endpoint.nil? || endpoint.empty?

          @endpoint = endpoint
          @connection = connection || Faraday.new(url: endpoint) do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Exact token count via the llama.cpp server.
        #
        # @param text [String]
        # @return [Integer] token count, +>= 0+.
        # @raise [RuntimeError] on HTTP non-2xx, JSON parse
        #   failure, missing +tokens+ key, or any
        #   +Faraday::Error+ (network failure, timeout).
        def count(text)
          return 0 if text.empty?

          response = @connection.post('/tokenize') do |req|
            req.headers['Content-Type'] = 'application/json'
            req.body = { content: text }
          end

          unless response.status == 200
            raise "Tokenizer::LlamaServer: POST #{@endpoint}/tokenize returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          tokens = response.body.is_a?(Hash) ? response.body['tokens'] : nil
          unless tokens.is_a?(Array)
            raise "Tokenizer::LlamaServer: response missing 'tokens' array " \
                  "(got #{response.body.inspect})"
          end

          tokens.length
        rescue Faraday::Error => e
          raise "Tokenizer::LlamaServer: #{e.class.name.split('::').last} " \
                "calling #{@endpoint}/tokenize: #{e.message}"
        end
      end
    end
  end
end
