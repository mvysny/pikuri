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
    # On +configure+ the extension registers three tools onto the
    # parent agent — {Tools::Search} as +vectordb_search+, {Tools::Read} as
    # +vectordb_read+, and {Tools::Reindex} as +vectordb_reindex+ — and
    # nothing else. It does *not* index anything: when and whether to
    # populate the corpus is host policy, not the extension's job.
    #
    # == The host owns population
    #
    # The extension exposes the constructed {Indexer} via {#indexer};
    # the host decides how the corpus gets filled:
    #
    # * Call +extension.indexer.index_all!+ / +#index_if_empty!+ from
    #   the host (e.g. a CLI flag, a boot step) for an explicit,
    #   synchronous index.
    # * Run a {Watcher} around +extension.indexer+ to keep the index
    #   live as files change — its boot reconcile sweep
    #   ({Indexer#reconcile_plan}) populates an empty backend and then
    #   tracks edits.
    # * Index nothing at boot and let the user drive it: the agent
    #   calls +vectordb_reindex+ when asked. The corpus is simply
    #   empty until then — {Tools::Search} returns no hits and says so.
    #
    # All three are equally valid; the extension stays agnostic. This
    # is the same host-owned shape as the {Watcher} (whose lifetime is
    # the process, not any one agent), and it keeps the wiring — and
    # the timing — visible in the host rather than hidden in a
    # constructor knob.
    #
    # == Changed your embedder or chunker? Reindex fully.
    #
    # Neither a {Watcher} nor +index_if_empty!+ reacts to a config
    # change: the change signal is the file's byte hash, so swapping
    # the embedder model or the chunker window leaves every
    # already-indexed chunk in place — silently stale (new queries
    # embed with the new model but score against old-model vectors).
    # After changing any indexing setting, run a full
    # +vectordb_reindex+ to rebuild from scratch.
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

      # @return [Indexer] the constructed {Indexer} instance.
      #   Exposed so the host can drive population however it
      #   chooses — +ext.indexer.index_if_empty!+ at boot, a
      #   {Watcher} around it, or leaving it empty until the LLM
      #   calls +vectordb_reindex+. See the class "host owns
      #   population" header.
      attr_reader :indexer

      # @param backend [#upsert, #query, #delete_all, #count]
      #   any {Backend} implementation. {InMemory} is the
      #   educational default; {Backend::Qdrant} the recommended
      #   persistent backend ({Backend::Chroma} the supported
      #   alternative — see +DESIGN.md+).
      # @param source [String, Pathname] path to index. A file
      #   indexes directly; a directory is walked recursively
      #   (see {Indexer::DENYLIST}). Single source only in v1
      #   — multi-source is deferred (see
      #   +ideas/vectordb-deferrals.md+ §"Multi-source indexing").
      # @param embedder [#embed, nil] anything implementing
      #   +embed(Array<String>) -> Array<Array<Float>>+; +nil+
      #   constructs {Embedder} with the default model.
      # @param reranker [#rerank, nil] optional cross-encoder
      #   reranker. +nil+ skips reranking — {Tools::Search} retrieves
      #   the final top-k from the backend directly.
      # @param chunker [#chunk, nil] anything implementing
      #   +chunk(String) -> Array<String>+; +nil+ constructs
      #   {Chunker::FixedWindow} with +size: 512, overlap: 50+
      #   and the default {Tokenizer::CharHeuristic}.
      # @return [Extension]
      def initialize(backend:, source:,
                     embedder: nil, reranker: nil, chunker: nil)
        @backend  = backend
        @embedder = embedder || Embedder.new
        @reranker = reranker
        @chunker  = chunker  || Chunker::FixedWindow.new(size: 512, overlap: 50)
        @indexer = Indexer.new(
          backend:  @backend,
          source:   source,
          embedder: @embedder,
          chunker:  @chunker
        )
      end

      # Register {Tools::Search} + {Tools::Read} + {Tools::Reindex} onto +c+. Does not
      # index — population is the host's call (see the class header).
      # Raises if any of the three tool names has been pre-registered:
      # the extension is the single owner of all three, and a duplicate
      # registration would point to a different Indexer / Embedder /
      # backend.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        %w[vectordb_search vectordb_read vectordb_reindex].each do |name|
          next unless c.tools.any? { |t| t.name == name }

          raise "#{name} cannot be pre-registered (in tools: or via c.add_tool) " \
                'when adding Pikuri::VectorDb::Extension — the extension auto-registers ' \
                'all three tools so they share the same Indexer / Embedder / backend.'
        end

        c.add_tool Tools::Search.new(embedder: @embedder, backend: @backend, reranker: @reranker)
        c.add_tool Tools::Read.new(backend: @backend, root: @indexer.root)
        c.add_tool Tools::Reindex.new(indexer: @indexer)
        nil
      end
    end
  end
end
