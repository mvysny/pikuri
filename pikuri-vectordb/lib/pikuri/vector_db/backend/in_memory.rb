# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Backend
      # Pure-Ruby vector store. The educational default backend;
      # IDEAS.md §"Vector DB / RAG" frames it as the "small enough
      # to audit" first stop the demo + guide walk through before
      # promoting users to +Chroma+ for persistence.
      #
      # == What it does
      #
      # Holds an in-memory Hash from chunk id to +[Chunk, vector]+;
      # +#query+ computes cosine similarity against every stored
      # vector, sorts descending, returns the top-k as
      # +Backend::Result+ instances. O(n) per query, where n is
      # the number of stored chunks. Fine for thousands of chunks
      # (a personal notes folder, a single product's docs); slow
      # for millions (a full corporate knowledge base — that's the
      # +Chroma+ use case).
      #
      # == What it deliberately doesn't do
      #
      # * **No persistence.** RAM-only, intentional — the user who
      #   wants persistence picks +Chroma+. Reloads from sources on
      #   every boot, which makes the in-memory backend the natural
      #   teaching shape: the same code path the demo binary walks
      #   on startup is the one the user inspects when they're
      #   learning what "indexing" actually means.
      # * **No approximate search.** Exhaustive scan. Approximate
      #   nearest neighbor (HNSW, IVF) adds complexity that doesn't
      #   teach anything additional once the cosine math is clear.
      # * **No thread safety.** {Indexer} runs single-threaded
      #   during a boot or reindex; {Search} calls +#query+ from
      #   the agent's main thread. No concurrent access today.
      #
      # == Cosine, not dot product
      #
      # Some embedders return pre-normalized vectors (text-embedding-3,
      # most sentence-transformers); others don't. Cosine normalizes
      # at compute time, so the backend works regardless of whether
      # the embedder did. The readable two-pass form below (compute
      # dot + magnitudes separately) is intentional over the
      # single-loop micro-optimization — this is the file the
      # newcomer reads to understand what's happening.
      class InMemory
        # @return [InMemory]
        def initialize
          # id (String) → [Chunk, vector (Array<Float>)]
          @entries = {}
          # Dimension of every stored vector. +nil+ before the first
          # +#upsert+; locked to the dim of the first vector seen and
          # enforced for every subsequent +#upsert+ + +#query+ — see
          # the Backend protocol's "Vector-dim contract" yardoc.
          @dim = nil
        end

        # Insert-or-replace by +chunk.id+. Parallel arrays of
        # equal length; raises on empty input or length mismatch.
        # Vector dimension is locked at first upsert; raises on
        # any subsequent vector of a different dim.
        #
        # @param chunks [Array<Chunk>]
        # @param vectors [Array<Array<Float>>]
        # @return [void]
        # @raise [ArgumentError] on empty input, length mismatch,
        #   or vector-dim mismatch.
        def upsert(chunks:, vectors:)
          raise ArgumentError, 'upsert called with empty chunks/vectors' if chunks.empty?
          if chunks.size != vectors.size
            raise ArgumentError, "size mismatch: #{chunks.size} chunks vs #{vectors.size} vectors"
          end

          expected = @dim || vectors.first.size
          vectors.each_with_index do |v, i|
            next if v.size == expected

            raise ArgumentError, "vector #{i} has dim #{v.size}, expected #{expected}"
          end
          @dim ||= expected

          chunks.zip(vectors).each { |chunk, vector| @entries[chunk.id] = [chunk, vector] }
          nil
        end

        # Cosine-similarity nearest neighbor search. Returns the
        # top-k {Backend::Result}s in descending score order;
        # empty array when the store has no entries.
        #
        # @param vector [Array<Float>] query vector; must match
        #   the stored vector dim.
        # @param top_k [Integer] number of results to return;
        #   must be positive.
        # @return [Array<Backend::Result>]
        # @raise [ArgumentError] on +top_k+ <= 0 or query-vector
        #   dim mismatch.
        def query(vector:, top_k:)
          raise ArgumentError, "top_k must be positive (got #{top_k})" if top_k <= 0
          return [] if @entries.empty?

          if vector.size != @dim
            raise ArgumentError, "query vector dim #{vector.size}, stored dim #{@dim}"
          end

          scored = @entries.values.map do |chunk, stored|
            Result.new(chunk: chunk, score: cosine(vector, stored))
          end
          scored.sort_by { |r| -r.score }.first(top_k)
        end

        # Drop every stored chunk. Used by the v1 nuke-and-reload
        # reindex flow; the embedder dim lock is also released so
        # a reindex with a different embedder model starts clean.
        #
        # @return [void]
        def delete_all
          @entries.clear
          @dim = nil
          nil
        end

        # @return [Integer] current chunk count.
        def count
          @entries.size
        end

        private

        # Cosine similarity. Two-pass form is the readable shape;
        # micro-optimizing into a single loop saves an array
        # traversal but obscures what's happening for the reader
        # who's here to learn how a vector store works.
        #
        # @param a [Array<Float>]
        # @param b [Array<Float>]
        # @return [Float] cosine in +[-1.0, 1.0]+, or +0.0+ if
        #   either vector is zero (degenerate but valid input).
        def cosine(a, b)
          dot = a.zip(b).sum { |x, y| x * y }
          mag_a = Math.sqrt(a.sum { |x| x * x })
          mag_b = Math.sqrt(b.sum { |x| x * x })
          return 0.0 if mag_a.zero? || mag_b.zero?

          dot / (mag_a * mag_b)
        end
      end
    end
  end
end
