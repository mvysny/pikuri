# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The LLM-facing piece: a {Pikuri::Tool} subclass exposed
    # as +vectordb_search+. Agentic search — the agent decides
    # when to retrieve. Composes {Embedder} + a {Backend} +
    # optionally a {Reranker} into one call:
    #
    # 1. Embed the query via {Embedder} into a vector.
    # 2. {Backend#query} for candidates. Window is {CANDIDATE_K}
    #    when a reranker is configured (we'll narrow back to
    #    {FINAL_K}), or {FINAL_K} directly when not (no point
    #    over-fetching candidates we'll just throw away).
    # 3. Optionally rerank: pass the candidate texts to the
    #    {Reranker}, reorder by {Reranker::Hit.index}, replace
    #    each result's score with the reranker's relevance score,
    #    then take the top {FINAL_K}.
    # 4. Format as a numbered list with +source+ + +score+ +
    #    text snippet, capped at {SNIPPET_LENGTH} chars per
    #    chunk.
    #
    # == Which score is shown
    #
    # The +score+ in the observation tracks whatever actually
    # determined the ordering, so the number never disagrees with
    # the rank:
    #
    # * *Vector-only* (no reranker, or reranker outage fallback) —
    #   the {Backend::Result} cosine similarity, range +[0, 1]+,
    #   directly comparable across results.
    # * *Reranked* — the {Reranker::Hit} relevance score that
    #   produced the order. This is a cross-encoder score on a
    #   model-dependent scale (can be negative / unbounded for raw
    #   logits — see {Reranker::Hit}'s +score+ yardoc), so it's a
    #   relative confidence gradient, *not* a 0–1 value to
    #   threshold on. The two modes therefore put different scales
    #   behind one +score=+ label by design: cosine and a rerank
    #   score are not comparable, and pikuri shows the one the
    #   ordering was actually built from rather than a misleading
    #   cosine next to a rerank-determined list.
    #
    # == Reranker outage falls back, not fails
    #
    # If the reranker's HTTP call raises (server down, timeout,
    # 5xx, malformed response — all surfaced by
    # {Reranker::LlamaServer} as +RuntimeError+), the tool
    # catches it, logs a WARN, and returns the vector-only top
    # {FINAL_K} from the same candidate set. Reranker is a
    # quality knob, not a correctness one — degraded results
    # beat a tool error the agent has to recover from.
    #
    # == Why a single-param tool surface
    #
    # +vectordb_search(query:)+ — no +top_k:+, no +reranker:+
    # toggle. Retrieval-depth and rerank choice are host
    # policy decisions baked into the {Extension}'s
    # configuration; the LLM doesn't need (or want) to be
    # tuning retrieval parameters mid-conversation. Same
    # reasoning the IDEAS.md design called out for keeping the
    # tool surface minimal.
    class Search < Pikuri::Tool
      LOGGER = Pikuri.logger_for('VectorDb::Search')

      # @return [Integer] number of results returned to the
      #   LLM. Five is the sweet spot most RAG implementations
      #   converge on: enough to cover related-but-different
      #   angles on a query, few enough to fit in a turn
      #   without budget pressure.
      FINAL_K = 5

      # @return [Integer] over-fetch size when a reranker is
      #   configured. Fifty matches the
      #   "retrieve-broad-then-narrow" pattern IDEAS.md §"Vector
      #   DB / RAG" calls out — the reranker's cross-encoder
      #   sees more candidates than vector search alone would
      #   surface and reorders by query-conditional relevance.
      CANDIDATE_K = 50

      # @return [Integer] per-result text cap in the observation.
      #   Keeps a five-result page under ~2.5 KB; the agent can
      #   re-query with a sharper question if a snippet looks
      #   like it cuts off mid-thought.
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
          }
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

      # Attempt the rerank; on any +RuntimeError+ from the
      # reranker (HTTP non-2xx, malformed body, network
      # failure), log a WARN and return the vector-only ordering
      # as the fallback.
      #
      # On success, each returned {Backend::Result} carries the
      # reranker's relevance score in its +score+ field (via
      # +Data#with+), replacing the backend's cosine score — so
      # the number {format_observation} prints matches the rerank
      # order. The fallback path leaves the cosine scores intact.
      # See the class-level "Which score is shown" section.
      #
      # @return [Array<Backend::Result>] reranked (score = rerank
      #   relevance) or fallback (score = cosine).
      def self.reranked_or_fallback(reranker:, query:, candidates:)
        documents = candidates.map { |c| c.chunk.text }
        hits = reranker.rerank(query: query, documents: documents)
        hits.map { |h| candidates[h.index]&.with(score: h.score) }.compact
      rescue RuntimeError => e
        LOGGER.warn("reranker outage; falling back to vector-only top-k: #{e.message}")
        candidates
      end
      private_class_method :reranked_or_fallback

      # Format the final result list as a header + numbered
      # blocks. Each block is +source (score=X.XX)+ on one line
      # followed by the snippet on the next; blocks separated
      # by a blank line. Snippets over {SNIPPET_LENGTH} chars
      # are truncated with a +...+ suffix. The +score+ printed is
      # whatever the caller stored in +result.score+ — cosine in
      # vector-only mode, the reranker's relevance score in
      # reranked mode (see the class-level "Which score is shown"
      # section); +%.2f+ handles both, including negative rerank
      # logits.
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
