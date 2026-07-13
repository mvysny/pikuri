# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Tokenizer
      # Exact tokenization via HTTP POST +/tokenize+ against a llama.cpp server
      # (its own endpoint, not OpenAI-spec):
      #
      #   POST <endpoint>/tokenize   { "content": "hello world" }
      #   → 200 { "tokens": [123, 456, 789] }
      #
      # {#count} returns +tokens.length+. Point +endpoint:+ at the *embedder's*
      # server, not the chat one: chunking is sized to the embedder's context
      # (bge-small-en-v1.5 = 512, text-embedding-3-large = 8192), and a different
      # model's tokenizer gives the wrong number.
      #
      # Per-string round-trip cost: a 10 MB corpus at 512 tokens ≈ 20k tokenize
      # calls, a few ms each on localhost — ~minutes over {CharHeuristic}, a
      # one-time boot/reindex cost. Errors are loud (non-2xx, parse failure,
      # missing +tokens+, network failure all raise — internal caller, bug
      # territory).
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
