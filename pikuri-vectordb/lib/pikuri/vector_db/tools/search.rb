# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The LLM-facing +vectordb_search+ tool — agentic search, the agent
      # decides when to retrieve. Composes {Embedder} + {Backend} + optional
      # {Reranker}: embed the query, {Backend#query} for candidates
      # ({CANDIDATE_K} with a reranker to narrow back to {FINAL_K}, else
      # {FINAL_K} directly), optionally rerank (reorder by {Reranker::Hit.index},
      # take top {FINAL_K}), then format as a numbered +source+ + +score+ +
      # snippet list capped at {SNIPPET_LENGTH} chars.
      #
      # == Which score is shown
      #
      # The +score+ tracks whatever determined the ordering, so it never
      # disagrees with the rank — but the two modes put *different scales* behind
      # one +score=+ label:
      #
      # * *Vector-only* (no reranker, or outage fallback) — cosine similarity
      #   +[0, 1]+, comparable across results.
      # * *Reranked* — the {Reranker::Hit} relevance score, a cross-encoder value
      #   on a model-dependent scale (can be negative/unbounded for raw logits —
      #   see {Reranker::Hit}), a relative gradient *not* a 0–1 threshold. pikuri
      #   shows the one the order was built from rather than a misleading cosine.
      #
      # A reranker outage falls back, doesn't fail: its {Reranker::LlamaServer}
      # +RuntimeError+ is caught, WARN-logged, and the vector-only top {FINAL_K}
      # returned — reranker is a quality knob, degraded results beat a tool error.
      #
      # Single-param surface (+query:+ only, no +top_k:+/+reranker:+ toggle):
      # retrieval depth and rerank choice are host policy baked into {Extension},
      # not something the LLM should tune mid-conversation.
      #
      # Sharing: +P_shared_locked+, and sharing is what you want — an index is
      # expensive to build and is the same corpus for every agent, so ten
      # agents over one {Backend} is the intended shape. {Backend::InMemory}
      # locks; the server backends serialize on their own side; the embedder
      # and reranker are stateless HTTP.
      class Search < Pikuri::Tool
        LOGGER = Pikuri.logger_for('VectorDb::Tools::Search')

        # @return [Integer] results returned to the LLM — the RAG sweet spot:
        #   enough for related-but-different angles, few enough to fit a turn.
        FINAL_K = 5

        # @return [Integer] over-fetch size with a reranker (retrieve-broad-then-
        #   narrow — the cross-encoder sees more candidates than vector search
        #   surfaces and reorders by query-conditional relevance).
        CANDIDATE_K = 50

        # @return [Integer] per-result text cap in the observation (~2.5 KB for a
        #   five-result page; the agent can re-query if a snippet cuts off).
        SNIPPET_LENGTH = 500

        # @return [String] static description shown to the LLM,
        #   opencode-shape (summary + +Usage:+ bullets).
        DESCRIPTION = <<~DESC
          Search the indexed document corpus for content relevant to a query.

          Usage:
          - Use when the user asks about facts, definitions, or topics that would live in their indexed documents (notes, docs, knowledge base).
          - Phrase the query as a complete question or topic statement — the embedder reads natural language, not keyword bags.
          - Returns up to #{FINAL_K} results with `source` paths and text snippets; cite results back using the source path.
          - If a query returns nothing useful, either the relevant doc isn't in the corpus, or the corpus hasn't been indexed yet — say which you suspect, and offer to run `vectordb_reindex` to build the index.
        DESC

        # @param embedder [#embed] anything implementing
        #   +embed(Array<String>) -> Array<Array<Float>>+.
        #   Typically {Pikuri::VectorDb::Embedder}.
        # @param backend [#query, #upsert, #delete_all, #count]
        #   any {Backend} implementation.
        # @param reranker [#rerank, nil] optional. +nil+ skips
        #   reranking and retrieves {FINAL_K} from the backend
        #   directly.
        # @return [Search]
        def initialize(embedder:, backend:, reranker: nil)
          super(
            name: 'vectordb_search',
            description: DESCRIPTION,
            parameters: Pikuri::Tool::Parameters.build { |p|
              p.required_string :query,
                                'Natural-language search query, e.g. ' \
                                '"how does the deployment pipeline handle migrations?" or ' \
                                '"recipe with mushrooms and risotto rice".'
            },
            execute: lambda { |query:|
              Search.execute(
                embedder: embedder, backend: backend, reranker: reranker,
                query: query
              )
            },
            # Hard untrusted: a corpus is a pile of documents pikuri did not
            # write, and web-sourced corpora are the common case. No egress —
            # the query never leaves the machine, which is the whole point of
            # local retrieval.
            #
            # No private leg: there is no per-corpus declaration yet, so this
            # stays the quiet default rather than guessing. A private corpus is
            # under-warned; see +private:+ on {Pikuri::Workspace::Filesystem}
            # for the shape it would take.
            trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: :hard, egress_payload_review: :no_egress)
          )
        end

        # Public so specs can exercise the search pipeline without
        # constructing a Tool wrapper.
        #
        # @param embedder [#embed]
        # @param backend [#query]
        # @param reranker [#rerank, nil]
        # @param query [String]
        # @return [String] formatted observation.
        def self.execute(embedder:, backend:, reranker:, query:)
          return 'Error: query is empty' if query.nil? || query.strip.empty?

          candidate_k = reranker ? CANDIDATE_K : FINAL_K
          query_vector = embedder.embed([query]).first
          candidates = backend.query(vector: query_vector, top_k: candidate_k)
          return 'No matches found in the indexed corpus.' if candidates.empty?

          final = if reranker
                    reranked_or_fallback(reranker: reranker, query: query, candidates: candidates)
                  else
                    candidates
                  end.first(FINAL_K)

          format_observation(final)
        end

        # Attempt the rerank; on any reranker +RuntimeError+, WARN and return the
        # vector-only ordering. On success each {Backend::Result} carries the
        # reranker's relevance score (via +Data#with+, replacing cosine) so the
        # printed number matches the rerank order; the fallback keeps cosine. See
        # "Which score is shown".
        #
        # @return [Array<Backend::Result>] reranked (score = rerank relevance) or
        #   fallback (score = cosine).
        def self.reranked_or_fallback(reranker:, query:, candidates:)
          documents = candidates.map { |c| c.chunk.text }
          hits = reranker.rerank(query: query, documents: documents)
          hits.map { |h| candidates[h.index]&.with(score: h.score) }.compact
        rescue RuntimeError => e
          LOGGER.warn("reranker outage; falling back to vector-only top-k: #{e.message}")
          candidates
        end
        private_class_method :reranked_or_fallback

        # Format the results as a header + numbered +source (score=X.XX)+ blocks
        # with the snippet below, truncated at {SNIPPET_LENGTH} with +...+. The
        # +score+ is whatever the caller stored (see "Which score is shown");
        # +%.2f+ handles both scales, including negative rerank logits.
        #
        # @param results [Array<Backend::Result>]
        # @return [String]
        def self.format_observation(results)
          header = "Found #{results.length} match#{'es' unless results.length == 1}.\n\n"
          body = results.each_with_index.map do |result, i|
            snippet = result.chunk.text
            snippet = snippet[0, SNIPPET_LENGTH] + '...' if snippet.length > SNIPPET_LENGTH
            score = format('%.2f', result.score)
            "[#{i + 1}] #{result.chunk.source} (score=#{score})\n#{snippet}"
          end.join("\n\n")
          header + body
        end
        private_class_method :format_observation
      end
    end
  end
end
