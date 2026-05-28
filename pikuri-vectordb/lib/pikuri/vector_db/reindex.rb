# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The administrative LLM-facing tool: +vectordb_reindex+.
    # Nukes the backend and re-indexes every source file from
    # scratch — the v1 nuke-and-reload pattern wired to a tool
    # the agent can call when (and only when) the user asks for
    # a refresh.
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
    # patience on the first turn.
    #
    # The description is firm on this — "only when the user
    # explicitly asks" + "not a general refresh" — and the v1
    # nuke-and-reload reindex is deliberately not incremental so
    # there's no temptation to use it for "what if I added one
    # file" cases either. Incremental reindex stays a deferred
    # follow-up (IDEAS.md §"Vector DB / RAG" → "Deferred").
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
        Re-index the document corpus from scratch.

        Usage:
        - Only call this when the user explicitly asks you to reindex — do not call as a "refresh just in case."
        - This is SLOW: walks every source file, embeds every chunk, replaces the entire index. Minutes against local embedders.
        - The corpus is already indexed at boot. Calling reindex mid-conversation only helps if the user has added or changed files on disk since the last index.
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
