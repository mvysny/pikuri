# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tokenizer
      # Approximate tokenization via a fixed chars-per-token ratio — the zero-dep
      # default, no network round-trip. Overshoot is fine because embedders
      # truncate gracefully (a 10%-over chunk is capped, not rejected).
      #
      # English BPE tokenizers (GPT, llama, BGE, sentence-transformers) settle
      # around 3.5–4.5 chars/token on prose; code drops to ~3, CJK to ~1–2 (one
      # logograph per token). Default 4 is the English sweet spot — override
      # +chars_per_token:+ for other corpora, or use {LlamaServer} for exact
      # counts when the corpus is CJK/code-heavy or the embedder's window is
      # tight enough that overshoot clips content.
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
