# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tokenizer
      # Approximate tokenization via a fixed chars-per-token
      # ratio. The zero-dep default; ships at construction
      # without a network round-trip. Slight overshoot
      # (under-counting tokens) is fine because embedders
      # truncate gracefully — a chunk that overshoots by 10%
      # is silently capped, not rejected.
      #
      # == The 4-chars-per-token rule
      #
      # English BPE tokenizers — GPT, llama, BGE, the family
      # of sentence-transformer models pikuri-vectordb users
      # actually run — settle around 3.5–4.5 chars per token
      # on natural-language text. Code drops to ~3 (punctuation
      # density). Mandarin / Japanese drop to ~1–2 (one logograph
      # per token). Default 4 sits in the English-prose
      # sweet spot; override +chars_per_token:+ for other
      # corpora.
      #
      # == When to choose this vs LlamaServer
      #
      # * **CharHeuristic** — you want zero network dependency,
      #   you trust the embedder's truncation, you're indexing
      #   English / Western-European prose. The
      #   educational / out-of-the-box default.
      # * **LlamaServer** — you want exact counts, your corpus
      #   is non-English or code-heavy, or your embedder has a
      #   tight context window where overshoot matters (e.g.,
      #   bge-small-en-v1.5 at 512 tokens — 10% slop is 50
      #   tokens of clipped content).
      class CharHeuristic
        # @param chars_per_token [Numeric] characters per token
        #   the approximation assumes. Default +4.0+ — English
        #   prose against a BPE tokenizer. Pass a smaller number
        #   for denser scripts (Mandarin ≈ 2; Japanese ≈ 1.5).
        # @return [CharHeuristic]
        def initialize(chars_per_token: 4.0)
          raise ArgumentError, 'chars_per_token must be positive' if chars_per_token <= 0

          @chars_per_token = chars_per_token.to_f
        end

        # Approximate token count. Empty string returns 0;
        # short strings round up to at least 1 token.
        #
        # @param text [String]
        # @return [Integer] approximate token count, +>= 0+.
        def count(text)
          return 0 if text.empty?

          (text.length / @chars_per_token).ceil
        end
      end
    end
  end
end
