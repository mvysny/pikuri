# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  module VectorDb
    module Reranker
      # Cross-encoder reranker via HTTP POST +/v1/rerank+
      # against a llama.cpp server. Same wire format Cohere's
      # hosted reranker speaks (Cohere is the de facto standard
      # here; llama.cpp's REST surface mirrors it for the
      # reranker model), so a +Reranker::Cohere+ later is a
      # base-URL + auth-header swap on top of this same client.
      #
      # == Wire format
      #
      #   POST <endpoint>/v1/rerank
      #   Content-Type: application/json
      #   {
      #     "model": "<model name, if configured>",
      #     "query": "<query text>",
      #     "documents": ["<doc 1>", "<doc 2>", ...]
      #   }
      #   →
      #   200 OK
      #   {
      #     "results": [
      #       { "index": 0, "relevance_score": 0.92 },
      #       { "index": 2, "relevance_score": 0.18 },
      #       ...
      #     ]
      #   }
      #
      # +#rerank+ extracts +results+, re-sorts descending by
      # +relevance_score+ (servers typically return sorted, but
      # we sort defensively so callers can rely on the
      # contract), and maps each entry to a {Hit}.
      #
      # == Configuration
      #
      # +endpoint:+ is the base URL (e.g.
      # +'http://localhost:8080'+). +/v1/rerank+ is appended
      # internally. Most setups point this at the same
      # router-mode +llama-server+ as chat and embedder — one
      # process, one port. Pass a separate URL only if you want
      # the reranker resident in its own +llama-server+ while
      # the router swaps chat and embedder.
      #
      # +model:+ is optional. llama.cpp typically infers the
      # loaded model and doesn't require it in the request;
      # Cohere requires it. Setting it forward-compatibly means
      # the same configuration works against either when we add
      # the Cohere adapter.
      #
      # +connection:+ is dependency injection for tests — pass
      # a +Faraday::Connection+ pre-wired with
      # +Faraday::Adapter::Test+ stubs and the request/response
      # JSON middleware. Production callers leave it +nil+; a
      # fresh connection is built against +endpoint+.
      #
      # == Errors are loud
      #
      # Same posture as {Tokenizer::LlamaServer}: HTTP non-2xx,
      # missing +results+ key, malformed body, +Faraday::Error+
      # all raise rather than swallow + return a fudge value.
      # Caller is the {Search} tool, which catches and falls
      # back to vector-only top-k while logging the failure
      # loudly — reranker outages degrade gracefully at the
      # *tool* level, not by the client lying about scores.
      class LlamaServer
        # @param endpoint [String] base URL of the rerank
        #   server, e.g. +'http://localhost:8082'+.
        # @param model [String, nil] model name to send in the
        #   request body. +nil+ omits the +model+ field;
        #   llama.cpp uses whatever's loaded.
        # @param connection [Faraday::Connection, nil] optional
        #   dependency injection for tests.
        # @return [LlamaServer]
        # @raise [ArgumentError] on empty endpoint.
        def initialize(endpoint:, model: nil, connection: nil)
          raise ArgumentError, 'endpoint must be non-empty' if endpoint.nil? || endpoint.empty?

          @endpoint = endpoint
          @model = model
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
