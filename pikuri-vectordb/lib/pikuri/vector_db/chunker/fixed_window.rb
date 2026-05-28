# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Chunker
      # Sliding-window chunker. Splits text on whitespace into
      # words, then walks forward emitting chunks of approximately
      # +size+ tokens with +overlap+ tokens of repeated tail from
      # the previous chunk.
      #
      # == Why whitespace-split rather than a richer tokenization
      #
      # Whitespace gives word boundaries for English / Western-
      # European languages, which is good enough for v1 against
      # any text the {TextExtractor} produces (Markdown, PDF, HTML
      # are all flattened to whitespace-separated prose). CJK
      # languages (no whitespace) degrade to one-huge-unit chunks
      # — documented limitation, picked up if a real CJK use case
      # arrives.
      #
      # == How overlap works
      #
      # Each chunk after the first re-includes the tail of the
      # previous chunk, sized to +overlap+ tokens. This gives the
      # embedder context across chunk boundaries: an answer that
      # straddles two sliding-window positions stays intact in at
      # least one chunk. Standard RAG practice; LangChain /
      # LlamaIndex / opencode all do the same.
      #
      # == Per-chunk tokenizer cost
      #
      # The greedy "add one word, check token count, repeat"
      # algorithm calls +tokenizer.count+ once per word per
      # candidate chunk — O(n_words * chunks_in_text) calls.
      # For {Tokenizer::CharHeuristic} this is negligible. For
      # {Tokenizer::LlamaServer} this is one HTTP round-trip per
      # call; indexing a large corpus takes minutes-not-seconds.
      # One-time cost paid at boot or explicit reindex;
      # acceptable for v1. A doubling-search + binary-refine
      # variant is the obvious optimization if it bites; the
      # protocol stays the same.
      #
      # == Forward-progress guard
      #
      # The constructor rejects +overlap >= size+ to keep the
      # sliding window actually moving forward. Even with valid
      # inputs, the inner loop always advances by at least one
      # word — guarantees termination even if a pathological
      # tokenizer were to report misleading counts.
      class FixedWindow
        # @return [Integer] target token count per chunk.
        attr_reader :size

        # @return [Integer] tokens of overlap between adjacent
        #   chunks.
        attr_reader :overlap

        # @param size [Integer] target token count per chunk.
        #   Must be positive. Common values: 256, 512, 1024 —
        #   pick to match the embedder's context (e.g. 512 for
        #   bge-small-en-v1.5).
        # @param overlap [Integer] tokens of overlap between
        #   adjacent chunks. Must be +>= 0+ and strictly less
        #   than +size+. Common values: ~10% of size.
        # @param tokenizer [#count] a {Tokenizer}; anything
        #   responding to +count(text) -> Integer+. Defaults to
        #   {Tokenizer::CharHeuristic} (zero-dep,
        #   ~4-chars-per-token approximation).
        # @return [FixedWindow]
        # @raise [ArgumentError] on invalid +size+ or +overlap+.
        def initialize(size:, overlap: 0, tokenizer: Tokenizer::CharHeuristic.new)
          raise ArgumentError, "size must be positive (got #{size})" if size <= 0
          raise ArgumentError, "overlap must be >= 0 (got #{overlap})" if overlap.negative?
          if overlap >= size
            raise ArgumentError,
                  "overlap (#{overlap}) must be strictly less than size (#{size}) " \
                  "— the sliding window would not advance"
          end

          @size = size
          @overlap = overlap
          @tokenizer = tokenizer
        end

        # Chunk +text+ into approximately +size+-token windows
        # with +overlap+-token tail repeats. Empty /
        # whitespace-only input returns +[]+.
        #
        # @param text [String]
        # @return [Array<String>] non-empty chunks, in source
        #   order. May be empty.
        def chunk(text)
          words = text.split
          return [] if words.empty?

          chunks = []
          start = 0
          while start < words.length
            finish = find_chunk_end(words, start)
            chunks << words[start...finish].join(' ')

            break if finish >= words.length

            start = find_next_start(words, start, finish)
          end

          chunks
        end

        private

        # Walk forward from +start+ adding one word at a time
        # until +tokenizer.count+ exceeds +@size+, returning the
        # exclusive end index. Always advances at least one word
        # so a single oversized word still becomes a chunk (the
        # embedder truncates rather than the chunker silently
        # dropping the word).
        def find_chunk_end(words, start)
          finish = start + 1
          while finish < words.length
            candidate = words[start...(finish + 1)].join(' ')
            break if @tokenizer.count(candidate) > @size

            finish += 1
          end
          finish
        end

        # Find the index where the next chunk should start so
        # that words[next_start...finish] is approximately
        # +@overlap+ tokens. Walks backward from +finish+ until
        # the back-window crosses the overlap budget. Always
        # advances at least one word past +start+ to guarantee
        # forward progress.
        def find_next_start(words, start, finish)
          return finish if @overlap.zero?

          next_start = finish
          while next_start > start + 1
            window = words[(next_start - 1)...finish].join(' ')
            break if @tokenizer.count(window) > @overlap

            next_start -= 1
          end
          [next_start, start + 1].max
        end
      end
    end
  end
end
