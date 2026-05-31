# frozen_string_literal: true

require 'monitor'

module Pikuri
  module VectorDb
    module Backend
      # Pure-Ruby vector store. The educational default backend —
      # the "small enough to audit" first stop the demo + guide walk
      # through before promoting users to +Chroma+ for persistence.
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
      # * **No approximate-search index.** Exhaustive scan only.
      #
      # == Thread safety
      #
      # Every public method runs under a single reentrant
      # +Monitor+. The agent's main thread calls +#query+ while a
      # background {Watcher} thread calls +#replace_source+ /
      # +#delete_by_source+, so concurrent access is real once
      # auto-watch is wired. The lock's load-bearing job is
      # {#replace_source}: it holds the monitor across the
      # delete-then-upsert so a concurrent +#query+ never observes
      # the gap where a source has zero chunks. +Monitor+ (not a
      # bare +Mutex+) because +#replace_source+ re-enters the lock
      # via +#delete_by_source+ + +#upsert+, which a non-reentrant
      # +Mutex+ would deadlock on. +Chroma+ needs no client-side
      # lock — the server serializes — so this is the one backend
      # that locks.
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
          # Reentrant so +#replace_source+ can call +#delete_by_source+
          # + +#upsert+ while holding the lock — see the class yardoc's
          # "Thread safety" section.
          @lock = Monitor.new
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

          @lock.synchronize do
            expected = @dim || vectors.first.size
            vectors.each_with_index do |v, i|
              next if v.size == expected

              raise ArgumentError, "vector #{i} has dim #{v.size}, expected #{expected}"
            end
            @dim ||= expected

            chunks.zip(vectors).each { |chunk, vector| @entries[chunk.id] = [chunk, vector] }
          end
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

          @lock.synchronize do
            return [] if @entries.empty?

            if vector.size != @dim
              raise ArgumentError, "query vector dim #{vector.size}, stored dim #{@dim}"
            end

            scored = @entries.values.map do |chunk, stored|
              Result.new(chunk: chunk, score: cosine(vector, stored))
            end
            scored.sort_by { |r| -r.score }.first(top_k)
          end
        end

        # Drop every stored chunk. Used by the v1 nuke-and-reload
        # reindex flow; the embedder dim lock is also released so
        # a reindex with a different embedder model starts clean.
        #
        # @return [void]
        def delete_all
          @lock.synchronize do
            @entries.clear
            @dim = nil
          end
          nil
        end

        # @return [Integer] current chunk count.
        def count
          @lock.synchronize { @entries.size }
        end

        # Remove every chunk whose +source+ matches. The scoped
        # counterpart to {#delete_all} — drops one document's chunks
        # without touching the rest. No-op (and no error) when the
        # source isn't present. The dim lock is left intact: unlike
        # {#delete_all}, a per-source delete doesn't imply an
        # embedder change.
        #
        # @param source [String] the {Chunk#source} to purge, e.g.
        #   +"notes/cooking.md"+.
        # @return [void]
        def delete_by_source(source)
          @lock.synchronize do
            @entries.reject! { |_id, (chunk, _vector)| chunk.source == source }
          end
          nil
        end

        # Atomically replace all chunks for one +source+: delete the
        # old set, then upsert the new one, under a single hold of the
        # monitor. The incremental-reindex unit (see {Indexer#reindex_file!}).
        # Holding the lock across both halves is the point — a
        # concurrent {#query} sees either the old chunks or the new
        # ones, never the empty gap between.
        #
        # @param source [String] the {Chunk#source} being replaced.
        # @param chunks [Array<Chunk>] the new chunk set; every
        #   +chunk.source+ should equal +source+.
        # @param vectors [Array<Array<Float>>] parallel to +chunks+.
        # @return [void]
        # @raise [ArgumentError] on empty input, length mismatch, or
        #   vector-dim mismatch (from the inner {#upsert}).
        def replace_source(source:, chunks:, vectors:)
          @lock.synchronize do
            delete_by_source(source)
            upsert(chunks: chunks, vectors: vectors)
          end
          nil
        end

        # The boot-sweep reference: a map from each indexed +source+
        # to the content hash stored on its chunks. {Watcher} (via
        # {Indexer#reconcile_plan}) diffs this against the hashes of
        # the files currently on disk to decide what to reindex.
        # Built from chunk metadata; a chunk indexed before the
        # +hash+ metadata existed maps its source to +nil+, which the
        # diff treats as "changed" and reindexes — self-healing.
        #
        # @return [Hash{String => String, nil}] +source+ → content
        #   hash. Empty when nothing is indexed (the InMemory case at
        #   every boot, since RAM resets).
        def sources_with_hashes
          @lock.synchronize do
            result = {}
            @entries.each_value do |chunk, _vector|
              result[chunk.source] ||= chunk.metadata[:hash]
            end
            result
          end
        end

        # Is +source+ in the corpus? The scoped membership test
        # behind {VectorDb::Read}'s gate — a short-circuiting scan
        # rather than building the whole {#sources_with_hashes} map
        # just to read one key. See the Backend protocol yardoc.
        #
        # @param source [String] the {Chunk#source} to test.
        # @return [Boolean] true if at least one chunk has this source.
        def source_indexed?(source)
          @lock.synchronize do
            @entries.each_value.any? { |chunk, _vector| chunk.source == source }
          end
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
