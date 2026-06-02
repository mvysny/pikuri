# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The administrative LLM-facing tool: +vectordb_reindex+.
      # Nukes the backend and re-indexes every source file from
      # scratch — the nuke-and-reload pattern wired to a tool the
      # agent can call when (and only when) the user asks to index
      # or refresh.
      #
      # == The corpus is not indexed automatically
      #
      # The {Extension} registers this tool but indexes nothing at
      # boot (population is host policy — see {Extension}). So this is
      # both the *initial* population path and the refresh path: until
      # a host indexes the corpus some other way (an explicit
      # +indexer.index_if_empty!+, a {Watcher}), the index is empty and
      # {Tools::Search} returns no hits, and the agent calls +vectordb_reindex+
      # when the user asks it to build the index.
      #
      # == Why the "user-asked-only" framing
      #
      # Reindex is orders of magnitude more expensive than
      # +vectordb_search+: it walks every source file, calls the
      # embedder once per chunk, and replaces the entire backend
      # contents. Against a local llama.cpp embedder on a personal
      # notes corpus this is minutes-not-seconds, and the agent is
      # blocked for the duration. Without the warning, a model
      # inclined toward "make sure the index is fresh just in
      # case" before each search would burn through the user's
      # patience on the first turn — hence "build/refresh when asked,
      # not a reflexive refresh." For keeping a long-running index
      # fresh *without* a full reload, a host runs a {Watcher}
      # (incremental, per-file) rather than leaning on this tool.
      #
      # == Error path
      #
      # If the indexer raises a +RuntimeError+ mid-run (Faraday
      # network failure, embedder 5xx, Chroma backend
      # unavailable), the tool catches it and returns +"Error: ..."+
      # as the observation. Same convention as the other tools
      # whose failures the LLM can react to — the agent tells the
      # user "the reindex failed because <reason>" rather than
      # exploding the turn.
      class Reindex < Pikuri::Tool
        # @return [String] static description shown to the LLM,
        #   opencode-shape (summary + +Usage:+ bullets).
        DESCRIPTION = <<~DESC
          Build or rebuild the document index from the corpus on disk, from scratch.

          Usage:
          - The corpus is NOT indexed automatically. If `vectordb_search` returns nothing, the index may be empty — call this to build it.
          - Call it when the user asks to index, reindex, or refresh the corpus (e.g. after they've added or changed files). Do not call it as a reflexive "refresh just in case" before every search.
          - This is SLOW: walks every source file, embeds every chunk, replaces the entire index. Minutes against local embedders.
          - Takes no arguments. Returns a one-line summary when indexing completes; the agent is blocked for the duration.
        DESC

        # @param indexer [Indexer] the indexer to call +#reindex!+
        #   on. Captured by the +execute+ closure so the tool can
        #   be registered against the same instance the
        #   {Extension} built at boot.
        # @return [Reindex]
        def initialize(indexer:)
          super(
            name: 'vectordb_reindex',
            description: DESCRIPTION,
            parameters: Pikuri::Tool::Parameters.build { |_p| }, # zero params
            execute: lambda {
              Reindex.execute(indexer: indexer)
            }
          )
        end

        # Public so specs can drive the tool without constructing
        # a Pikuri::Tool wrapper.
        #
        # @param indexer [Indexer]
        # @return [String] observation; either a success summary
        #   or an +"Error: ..."+ string.
        def self.execute(indexer:)
          total = indexer.reindex!
          if total.zero?
            'Reindexed: 0 chunks. No indexable files were found across the configured sources.'
          else
            "Reindexed: #{total} chunk(s) now in the index."
          end
        rescue RuntimeError => e
          "Error: reindex failed: #{e.message}"
        end
      end
    end
  end
end
