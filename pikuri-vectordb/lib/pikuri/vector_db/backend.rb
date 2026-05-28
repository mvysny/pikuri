# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for vector-store backends. Two ship in v1:
    #
    # * {InMemory} — pure-Ruby cosine over +Array<Float>+,
    #   RAM-only. The educational default; everything reloads
    #   from sources on every boot. Audit-friendly (~50 lines
    #   end to end) and zero-dep.
    # * +Chroma+ — thin Faraday HTTP client against a self-hosted
    #   ChromaDB server. The persistent option; survives restarts
    #   so the user pays the indexing cost once. (Not yet
    #   landed — currently being scaffolded.)
    #
    # == Backend protocol
    #
    # Duck-typed, like pikuri's other seams (+Confirmer+,
    # +Filesystem+, +Sandbox+) — no abstract base class. Every
    # backend implements these four methods so the {Indexer} and
    # {Search} tool consume them interchangeably:
    #
    # * +#upsert(chunks:, vectors:)+ — insert-or-replace by
    #   +chunk.id+. +chunks+ and +vectors+ are parallel arrays of
    #   equal length; raises +ArgumentError+ on empty input or
    #   length mismatch. Returns +nil+.
    # * +#query(vector:, top_k:)+ — return the top-k nearest
    #   chunks by cosine similarity, descending by score. Result
    #   is an +Array<Result>+; empty array when the store has no
    #   entries. Raises +ArgumentError+ on +top_k+ <= 0.
    # * +#delete_all+ — empty the store. Used by the v1
    #   nuke-and-reload reindex flow. Returns +nil+.
    # * +#count+ — current number of stored chunks, as +Integer+.
    #
    # == Vector-dim contract
    #
    # The first +#upsert+ call establishes the vector dimension
    # the backend will accept for the rest of its lifetime;
    # subsequent +#upsert+ calls and +#query+ calls must match
    # that dim or raise +ArgumentError+. Loud-failure shape: an
    # embedder swap mid-session would otherwise silently corrupt
    # the index, and the user's recourse is "reindex anyway"
    # either way.
    module Backend
    end
  end
end
