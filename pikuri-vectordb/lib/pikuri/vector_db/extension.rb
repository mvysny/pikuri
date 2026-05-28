# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The host-facing API: wire up local-corpus vector search +
    # agentic RAG on a {Pikuri::Agent} via +c.add_extension+
    # inside the +Agent.new+ block.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::VectorDb::Extension.new(
    #       backend: Pikuri::VectorDb::Backend::InMemory.new,
    #       source: '~/notes',
    #     )
    #   end
    #
    # On +configure+ the extension registers two tools onto the
    # parent agent — {Search} as +vectordb_search+ and {Reindex}
    # as +vectordb_reindex+ — and then triggers a boot-time
    # index per the +index_on_boot:+ knob:
    #
    # * +:if_empty+ (default) — only index if +backend.count+
    #   is zero. {Backend::InMemory} always re-indexes (RAM
    #   resets on every boot); {Backend::Chroma} indexes once
    #   on first boot and skips thereafter.
    # * +:always+ — nuke and re-index on every boot.
    # * +:never+ — the host drives indexing themselves via
    #   +extension.indexer+.
    #
    # The boot index runs synchronously inside +configure+; the
    # host's +Agent.new+ doesn't return until indexing is done.
    # That's intentional — the agent isn't useful until the
    # index exists, and the {Indexer}'s INFO logging gives the
    # user progress visibility. Hosts that want async startup
    # can wrap +Agent.new+ in a thread.
    #
    # == No system-prompt snippet
    #
    # Unlike {Pikuri::Tasks::Extension}, this extension does
    # *not* append a +<vectordb_usage>+ block to the agent's
    # system prompt. Two use modes coexist: the parent agent
    # may call +vectordb_search+ directly *or* delegate to
    # {LIBRARIAN} (registered separately via
    # +Pikuri::SubAgent::Extension+). A snippet recommending
    # one over the other would conflict with the trifecta-
    # defense argument in the LIBRARIAN-mediated mode. Tool
    # descriptions speak for themselves; hosts pick a preferred
    # mode in their own system prompt if they want.
    #
    # == LIBRARIAN is not auto-registered
    #
    # The bundled {LIBRARIAN} persona is opt-in — same
    # precedent as +Pikuri::Code::GIT_REPO_RESEARCHER+. Hosts
    # that want sub-agent recall add it explicitly:
    #
    #   c.add_extension Pikuri::SubAgent::Extension.new(
    #     personas: [Pikuri::VectorDb::LIBRARIAN]
    #   )
    #
    # That keeps the dependency on +pikuri-subagents+
    # registration-time-only — hosts using direct search (no
    # sub-agent mediation) don't need to wire it.
    class Extension
      include Pikuri::Agent::Extension

      # Boot-time index trigger options accepted by +index_on_boot:+.
      INDEX_ON_BOOT_MODES = %i[if_empty always never].freeze

      # @return [Indexer] the constructed {Indexer} instance.
      #   Exposed so hosts can drive +#index_all!+ /
      #   +#reindex!+ manually from a CLI flag or a future
      #   slash command (e.g. +index_on_boot: :never+ + a host
      #   thread that calls +ext.indexer.reindex!+ on schedule).
      attr_reader :indexer

      # @param backend [#upsert, #query, #delete_all, #count]
      #   any {Backend} implementation. {InMemory} is the
      #   educational default; {Backend::Chroma} the persistent
      #   option.
      # @param source [String, Pathname] path to index. A file
      #   indexes directly; a directory is walked recursively
      #   (see {Indexer::DENYLIST}). Single source only in v1
      #   — multi-source is deferred (see IDEAS.md §"Vector DB
      #   / RAG" → "Deferred").
      # @param embedder [#embed, nil] anything implementing
      #   +embed(Array<String>) -> Array<Array<Float>>+; +nil+
      #   constructs {Embedder} with the default model.
      # @param reranker [#rerank, nil] optional cross-encoder
      #   reranker. +nil+ skips reranking — {Search} retrieves
      #   the final top-k from the backend directly.
      # @param chunker [#chunk, nil] anything implementing
      #   +chunk(String) -> Array<String>+; +nil+ constructs
      #   {Chunker::FixedWindow} with +size: 512, overlap: 50+
      #   and the default {Tokenizer::CharHeuristic}.
      # @param index_on_boot [Symbol] one of {INDEX_ON_BOOT_MODES}.
      # @return [Extension]
      # @raise [ArgumentError] on an unknown +index_on_boot:+.
      def initialize(backend:, source:,
                     embedder: nil, reranker: nil, chunker: nil,
                     index_on_boot: :if_empty)
        unless INDEX_ON_BOOT_MODES.include?(index_on_boot)
          raise ArgumentError,
                "index_on_boot must be one of #{INDEX_ON_BOOT_MODES.inspect}, " \
                "got #{index_on_boot.inspect}"
        end

        @backend       = backend
        @embedder      = embedder || Embedder.new
        @reranker      = reranker
        @chunker       = chunker  || Chunker::FixedWindow.new(size: 512, overlap: 50)
        @index_on_boot = index_on_boot
        @indexer = Indexer.new(
          backend:  @backend,
          source:   source,
          embedder: @embedder,
          chunker:  @chunker
        )
      end

      # Register {Search} + {Reindex} onto +c+, then run the
      # configured boot-time index. Raises if either tool name
      # has been pre-registered — the extension is meant to be
      # the single owner of both, and a duplicate registration
      # would point to a different Indexer / Embedder /
      # backend.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        %w[vectordb_search vectordb_reindex].each do |name|
          next unless c.tools.any? { |t| t.name == name }

          raise "#{name} cannot be pre-registered (in tools: or via c.add_tool) " \
                'when adding Pikuri::VectorDb::Extension — the extension auto-registers ' \
                'both tools so they share the same Indexer / Embedder / backend.'
        end

        c.add_tool Search.new(embedder: @embedder, backend: @backend, reranker: @reranker)
        c.add_tool Reindex.new(indexer: @indexer)

        case @index_on_boot
        when :if_empty then @indexer.index_if_empty!
        when :always   then @indexer.reindex!
        when :never    then nil
        end
        nil
      end
    end
  end
end
