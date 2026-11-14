# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Reranker
      # Cross-encoder reranker via HTTP POST +/v1/rerank+ against a llama.cpp
      # server, in the same wire format Cohere's hosted reranker speaks — so a
      # +Reranker::Cohere+ later is little more than a base-URL swap on this client:
      #
      #   POST <endpoint>/v1/rerank   { "model"?, "query", "documents": [...] }
      #   → 200 { "results": [ { "index": 0, "relevance_score": 0.92 }, ... ] }
      #
      # {#rerank} extracts +results+, re-sorts descending by +relevance_score+
      # (defensively — servers usually pre-sort), and maps each to a {Hit}.
      # +endpoint:+ is the base URL (+/v1/rerank+ appended); most setups point it
      # at the same router-mode +llama-server+ as chat/embedder. +model:+ is
      # optional (llama.cpp infers the loaded model; Cohere requires it — set it
      # forward-compatibly). +api_key:+ is sent as +Authorization: Bearer+ — the
      # header a +llama-server --api-key+ checks, the same key RubyLLM sends for
      # chat and embeddings — so a reranker on a keyed server isn't rejected
      # with a 401 that {Tools::Search} would quietly degrade into "no reranker".
      #
      # Errors are loud: non-2xx,
      # missing +results+, malformed body, +Faraday::Error+ all raise. The
      # {Tools::Search} caller catches and falls back to vector-only top-k —
      # outages degrade at the *tool* level, not by the client lying about scores.
      class LlamaServer
        # @param endpoint [String] base URL of the rerank
        #   server, e.g. +'http://localhost:8082'+.
        # @param model [String, nil] model name to send in the
        #   request body. +nil+ omits the +model+ field;
        #   llama.cpp uses whatever's loaded.
        # @param api_key [String, nil] sent as +Authorization:
        #   Bearer+ on every request; +nil+ sends no header (a
        #   server without +--api-key+ needs none).
        # @param connection [Faraday::Connection, nil] optional
        #   dependency injection for tests.
        # @return [LlamaServer]
        # @raise [ArgumentError] on empty endpoint.
        def initialize(endpoint:, model: nil, api_key: nil, connection: nil)
          raise ArgumentError, 'endpoint must be non-empty' if endpoint.nil? || endpoint.empty?

          @endpoint = endpoint
          @model = model
          @api_key = api_key
          @connection = connection || Faraday.new(url: endpoint) do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Score every document against +query+ via the
        # cross-encoder. Returns an +Array<Hit>+ sorted
        # descending by score; one entry per input document.
        # Empty +documents+ short-circuits to +[]+.
        #
        # @param query [String]
        # @param documents [Array<String>] the candidates to
        #   score; positions become +Hit.index+ values in the
        #   response.
        # @return [Array<Hit>]
        # @raise [RuntimeError] on HTTP non-2xx, missing
        #   +results+ key, malformed entry, or any
        #   +Faraday::Error+ (network failure, timeout).
        def rerank(query:, documents:)
          return [] if documents.empty?

          body = { query: query, documents: documents }
          body[:model] = @model if @model

          response = @connection.post('/v1/rerank') do |req|
            req.headers['Content-Type'] = 'application/json'
            req.headers['Authorization'] = "Bearer #{@api_key}" if @api_key
            req.body = body
          end

          unless response.status == 200
            raise "Reranker::LlamaServer: POST #{@endpoint}/v1/rerank returned " \
                  "HTTP #{response.status}: #{response.body.inspect}"
          end

          results = response.body.is_a?(Hash) ? response.body['results'] : nil
          unless results.is_a?(Array)
            raise "Reranker::LlamaServer: response missing 'results' array " \
                  "(got #{response.body.inspect})"
          end

          hits = results.map do |entry|
            idx = entry.is_a?(Hash) ? entry['index'] : nil
            score = entry.is_a?(Hash) ? entry['relevance_score'] : nil
            unless idx.is_a?(Integer) && score.is_a?(Numeric)
              raise "Reranker::LlamaServer: malformed result entry " \
                    "(expected {index:Integer, relevance_score:Float}, got #{entry.inspect})"
            end

            Hit.new(index: idx, score: score.to_f)
          end
          hits.sort_by { |h| -h.score }
        rescue Faraday::Error => e
          raise "Reranker::LlamaServer: #{e.class.name.split('::').last} " \
                "calling #{@endpoint}/v1/rerank: #{e.message}"
        end
      end
    end
  end
end
