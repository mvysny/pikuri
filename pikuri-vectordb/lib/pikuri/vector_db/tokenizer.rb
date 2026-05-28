# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for tokenizers. Two ship in v1:
    #
    # * {CharHeuristic} — zero-dep, default. Approximates as
    #   ~4 chars/token (configurable). Slight overshoot is fine
    #   because embedders truncate gracefully.
    # * {LlamaServer} — exact via HTTP POST +/tokenize+ against
    #   a llama.cpp server (typically the same endpoint hosting
    #   the embedder model, so chunk sizing matches the
    #   embedder's actual vocab).
    #
    # == Tokenizer protocol
    #
    # Duck-typed, single method. The {Chunker::FixedWindow}
    # consumes any object responding to:
    #
    # * +#count(text)+ — return token count for +text+ as
    #   +Integer+. Empty string returns +0+. Implementations
    #   should be deterministic — same text in returns same
    #   count.
    #
    # No abstract base class. The {Chunker} doesn't care which
    # implementation it gets, only that +#count+ exists; matches
    # pikuri's other duck-typed seams ({Backend}, +Confirmer+,
    # +Filesystem+).
    #
    # == Why a separate protocol rather than baking heuristics
    # into the Chunker
    #
    # The chunker's job is "pack text into +size+-token windows";
    # how the count is derived is orthogonal. Lifting tokenization
    # out as its own seam means:
    #
    # * The Chunker is testable against a deterministic fake
    #   tokenizer that returns whatever the test wants.
    # * A future +Tokenizer::Tiktoken+ (or +llama_cpp+ gem-based
    #   tokenizer) plugs in without touching the Chunker.
    # * The CharHeuristic /LlamaServer choice is a host-level
    #   configuration knob — the host wires whichever fits their
    #   stack into the +chunker:+ passed to {Extension}, no other
    #   change required.
    #
    # == Where this lives
    #
    # +Pikuri::VectorDb::Tokenizer::*+ for v1. Promotes to
    # +Pikuri::Tokenizer::*+ in pikuri-core when a second
    # consumer arrives (a token-aware bash-output cap, a
    # token-aware +Read+ truncation) — the protocol shape stays
    # the same; only the namespace and dependency direction
    # change.
    module Tokenizer
    end
  end
end
