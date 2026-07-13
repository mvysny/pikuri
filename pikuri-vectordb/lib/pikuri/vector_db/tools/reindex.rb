# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The administrative +vectordb_reindex+ tool: nukes the backend and
      # re-indexes every source file from scratch. Since {Extension} indexes
      # nothing at boot, this is both the *initial* population path and the
      # refresh path — until a host populates some other way (an explicit
      # +indexer.index_if_empty!+, a {Watcher}), the index is empty, {Tools::Search}
      # returns no hits, and the agent calls this when the user asks to build it.
      #
      # "User-asked-only" framing (in the description): reindex is orders of
      # magnitude more expensive than search — walks every file, embeds every
      # chunk, replaces the whole backend, minutes against a local embedder with
      # the agent blocked. Without the warning a model inclined to "refresh just
      # in case" before each search would burn the user's patience on turn one.
      # For keeping a long-running index fresh *without* a full reload, a host
      # runs a {Watcher} (incremental) rather than this tool.
      #
      # A mid-run +RuntimeError+ (network, embedder 5xx, backend down) comes back
      # as an +"Error: ..."+ observation, not an exploded turn.
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
