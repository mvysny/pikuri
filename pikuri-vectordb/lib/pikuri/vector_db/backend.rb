# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Namespace for vector-store backends. Three ship:
    #
    # * {InMemory} — pure-Ruby cosine over +Array<Float>+,
    #   RAM-only. The educational default; everything reloads
    #   from sources on every boot. Audit-friendly (~50 lines
    #   end to end) and zero-dep. Pairs with {Server::InMemory}
    #   (the null supervisor).
    # * {Qdrant} — thin Faraday HTTP client against a self-hosted
    #   Qdrant server. The *recommended* persistent option —
    #   survives restarts so the user pays the indexing cost once;
    #   see +pikuri-vectordb/DESIGN.md+ for the engine survey
    #   behind the recommendation. Pairs with {Server::Qdrant}.
    # * {Chroma} — thin Faraday HTTP client against a self-hosted
    #   ChromaDB server. The alternative persistent option, for
    #   hosts that already run Chroma or prefer it. Pairs with
    #   {Server::Chroma}.
    #
    # == Backend protocol
    #
    # Duck-typed, like pikuri's other seams (+Confirmer+,
    # +Filesystem+, +Sandbox+) — no abstract base class. Every
    # backend implements these four methods so the {Indexer} and
    # {Tools::Search} tool consume them interchangeably:
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
    # * +#delete_by_source(source)+ — remove every chunk whose
    #   +source+ matches; the scoped counterpart to +#delete_all+.
    #   No-op when the source isn't present. Returns +nil+.
    # * +#replace_source(source:, chunks:, vectors:)+ —
    #   delete-by-source then upsert, as one operation; the
    #   incremental-reindex unit. +InMemory+ makes it atomic under a
    #   monitor, +Chroma+ does not (two HTTP calls — see its yardoc).
    #   Returns +nil+.
    # * +#sources_with_hashes+ — +Hash{String => String, nil}+ from
    #   each indexed +source+ to the content hash on its chunks; the
    #   boot-sweep reference {Indexer#reconcile_plan} diffs against
    #   disk. Empty when nothing is indexed. Inherently O(sources) —
    #   removal detection needs the *whole* indexed set — so it's a
    #   once-per-boot call, never a per-request one.
    # * +#source_indexed?(source)+ — +Boolean+: is there at least one
    #   chunk for +source+? The scoped counterpart to
    #   +#sources_with_hashes+ for the question "is this one source in
    #   the corpus?" ({VectorDb::Tools::Read}'s membership gate). Distinct so
    #   that a hot path never fetches the full manifest just to test
    #   one key.
    #
    # The +sources_with_hashes+ / +source_indexed?+ pair plus the two
    # before them exist for incremental reindex + auto-watch; the
    # nuke-and-reload path uses only the first four.
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
