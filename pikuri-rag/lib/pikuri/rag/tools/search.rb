# frozen_string_literal: true

module Pikuri
  module Rag
    module Tools
      # The LLM-facing +rag_search+ tool — hybrid top-k over the corpus. Two
      # legs run against the same chunks and are fused by reciprocal rank:
      #
      #   Found 5 matches.
      #
      #   [1] acme-2026-08-14.md (score=0.03)
      #   Agreed to hold list pricing through Q1 and revisit at renewal...
      #
      # * *Vector leg* — embed the query, {Pikuri::VectorDb::Backend#query} for
      #   {CANDIDATE_K} candidates. Answers "is this on the same topic?".
      # * *Keyword leg* — {Pikuri::Rag::Query.any}, stemmed by the backend's
      #   stemmer, then +#keyword_query+ for {CANDIDATE_K}. Answers "does this
      #   contain the words?", which is what
      #   rescues +invoice #4471+ and a customer's name from an embedder that
      #   ranks rare tokens badly.
      #
      # The keyword leg **ORs** its terms: a twelve-word natural-language
      # question ANDed matches nothing, and bm25's inverse-document-frequency
      # term already discounts the "what did we discuss" words. (+rag_find+
      # ANDs, because its promise is a set — see {Find}.)
      #
      # Fusion is reciprocal rank ({RRF_K}), then the optional
      # {Pikuri::VectorDb::Reranker} over the fused candidates, then
      # {FINAL_K}. The observation is {Pikuri::VectorDb::Tools::Search}'s
      # format, and the +score+ is whatever built the order — so the same
      # caveat applies as there, one +score=+ label over three scales (fused
      # rank, cross-encoder relevance, or cosine on the vector-only path).
      #
      # A single-param surface (+query:+ only): retrieval depth, fusion and
      # rerank choice are host policy baked into {Pikuri::Rag::Extension}, not
      # something the LLM should tune mid-conversation.
      #
      # == Why fuse by rank rather than by score
      #
      # Cosine similarity and +bm25()+ are different scales with no shared
      # zero — cosine sits in +[0, 1]+ while bm25 is an unbounded corpus
      # statistic — so any weighted sum of the two raw numbers is a knob with
      # no principled setting. Reciprocal rank throws the magnitudes away and
      # keeps only the ordering each leg is actually good at, which is why it
      # is the field's default answer and why {RRF_K} is a constant rather
      # than a parameter.
      #
      # Sharing: +P_shared_locked+, and sharing is what you want — an index is
      # expensive to build and is the same corpus for every agent.
      # {Pikuri::Rag::Backend::Fts5} locks, the vector store serializes
      # server-side, and the embedder and reranker are stateless HTTP.
      class Search < Pikuri::Tool
        # @return [Integer] results returned to the LLM. Aliases
        #   {Pikuri::VectorDb::Tools::Search::FINAL_K} — same corpus, same
        #   turn budget, and one number to measure before changing.
        FINAL_K = Pikuri::VectorDb::Tools::Search::FINAL_K

        # @return [Integer] per-leg over-fetch size *and* the cap on the fused
        #   list, aliasing {Pikuri::VectorDb::Tools::Search::CANDIDATE_K}.
        #   Both legs fetch this many *whether or not* a reranker is wired:
        #   fusion needs a deep list from each leg to have ranks to fuse, so
        #   the narrow-when-unreranked shortcut +vectordb_search+ takes does
        #   not apply. The union of two full legs is up to twice this, so the
        #   fused list is trimmed back to it before anything expensive runs.
        CANDIDATE_K = Pikuri::VectorDb::Tools::Search::CANDIDATE_K

        # @return [Integer] the reciprocal-rank-fusion damping constant: a
        #   chunk at rank +r+ in a leg contributes +1 / (RRF_K + r)+. 60 is
        #   the value the original TREC evaluation settled on and what every
        #   hybrid stack ships; it flattens the top of each list so a
        #   confident rank-1 hit in one leg does not out-vote agreement
        #   between both.
        RRF_K = 60

        # @return [String] static description shown to the LLM,
        #   opencode-shape (summary + +Usage:+ bullets).
        DESCRIPTION = <<~DESC
          Search the indexed document corpus for content relevant to a query, by meaning and by keyword at once.

          Usage:
          - Use when the user asks about facts, definitions, or topics that would live in their indexed documents (notes, docs, knowledge base).
          - Phrase the query as a complete question or topic statement; exact names, IDs and rare words in it are matched literally as well, so include them verbatim.
          - Returns up to #{FINAL_K} ranked results with `source` paths and text snippets; cite results back using the source path.
          - This is a ranked sample, not a complete list. When the user asks for *every* document about something, use rag_find instead.
          - If a query returns nothing useful, either the relevant doc isn't in the corpus, or the corpus hasn't been indexed yet — say which you suspect, and offer to run rag_reindex to build the index.
        DESC

        # @param embedder [#embed] anything implementing
        #   +embed(Array<String>) -> Array<Array<Float>>+.
        # @param backend [#query, #keyword_query, #stemmer] a
        #   {Pikuri::Rag::Backend::Hybrid}; the keyword leg stems the query
        #   with its +#stemmer+.
        # @param legs [Pikuri::Tool::TrifectaLegs] the corpus's declaration,
        #   derived by {Pikuri::Rag::Extension} via
        #   {Pikuri::VectorDb::CorpusLegs.derive}. Required — a default here
        #   would be a second copy of that derivation.
        # @param reranker [#rerank, nil] optional cross-encoder reranker;
        #   +nil+ returns the fused top-{FINAL_K} directly.
        # @return [Search]
        def initialize(embedder:, backend:, legs:, reranker: nil)
          super(
            name: 'rag_search',
            description: DESCRIPTION,
            parameters: Pikuri::Tool::Parameters.build { |p|
              p.required_string :query,
                                'Natural-language search query, e.g. ' \
                                '"what did we agree with Acme about pricing?" or ' \
                                '"invoice 4471".'
            },
            execute: lambda { |query:|
              Search.execute(
                embedder: embedder, backend: backend, reranker: reranker,
                query: query
              )
            },
            # As +vectordb_search+: corpus bytes into the context, nothing
            # outbound. Both legs run on this machine.
            trifecta_legs: legs
          )
        end

        # Run the hybrid pipeline and format the observation. Public so specs
        # can exercise it without constructing a Tool wrapper.
        #
        # @param embedder [#embed]
        # @param backend [#query, #keyword_query, #stemmer]
        # @param reranker [#rerank, nil]
        # @param query [String]
        # @return [Pikuri::Tool::Result] the formatted observation (+"Found 8
        #   matches"+), or {Pikuri::Tool::Result.error}.
        def self.execute(embedder:, backend:, reranker:, query:)
          return Pikuri::Tool::Result.error('query is empty') if query.nil? || query.strip.empty?

          vector_hits = backend.query(vector: embedder.embed([query]).first, top_k: CANDIDATE_K)
          match = Pikuri::Rag::Query.any(query, stemmer: backend.stemmer)
          keyword_hits = match ? backend.keyword_query(match: match, top_k: CANDIDATE_K) : []

          # Trimmed to CANDIDATE_K because the *union* of two 50-deep legs is
          # up to 100 documents, and the reranker is the one expensive step
          # here — an unbounded fused list would quietly cost twice what
          # vectordb_search pays for the same knob. The fused ranking decides
          # which 50 survive, which is what fusion is for.
          fused = fuse(vector_hits, keyword_hits).first(CANDIDATE_K)
          if fused.empty?
            return Pikuri::Tool::Result.new(content: 'No matches found in the indexed corpus.',
                                            summary: 'Found 0 matches')
          end

          final = if reranker
                    Pikuri::VectorDb::Tools::Search.reranked_or_fallback(
                      reranker: reranker, query: query, candidates: fused
                    )
                  else
                    fused
                  end.first(FINAL_K)

          Pikuri::VectorDb::Tools::Search.format_observation(final)
        end

        # Fuse two ranked lists by reciprocal rank: each chunk scores
        # +sum(1 / (RRF_K + rank))+ over the legs it appears in, 1-based rank.
        #
        #   fuse([a, b], [b, c])   # b appeared in both, so b outranks a and c
        #
        # Keyed on {Pikuri::VectorDb::Chunk#id}, which is stable across
        # reindexes and identical in both legs — the property that makes the
        # two stores fusable at all.
        #
        # @param legs [Array<Array<Pikuri::VectorDb::Backend::Result>>] one
        #   ranked list per leg, best first; an empty leg contributes nothing.
        # @return [Array<Pikuri::VectorDb::Backend::Result>] descending fused
        #   score, each result carrying that score in place of its leg's.
        def self.fuse(*legs)
          scores = {}
          winners = {}
          legs.each do |results|
            results.each_with_index do |result, i|
              id = result.chunk.id
              scores[id] = (scores[id] || 0.0) + (1.0 / (RRF_K + i + 1))
              winners[id] ||= result
            end
          end
          scores.sort_by { |_id, score| -score }
                .map { |id, score| winners[id].with(score: score) }
        end
      end
    end
  end
end
