# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for tokenizers. Two ship: {CharHeuristic} (zero-dep default,
    # ~4 chars/token — slight overshoot is fine, embedders truncate gracefully)
    # and {LlamaServer} (exact via +/tokenize+, typically the embedder's own
    # server so chunk sizing matches its vocab).
    #
    # == Tokenizer protocol
    #
    # Duck-typed, single method (like pikuri's other seams): +#count(text) ->
    # Integer+, +0+ for empty, deterministic. Lifting it out of {Chunker} lets
    # the chunker test against a fake, lets a future +Tiktoken+ plug in
    # untouched, and makes the CharHeuristic/LlamaServer choice a host knob (the
    # +chunker:+ passed to {Extension}).
    module Tokenizer
    end
  end
end
