# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The host-facing API: wire local-corpus vector search + agentic RAG onto a
    # {Pikuri::Agent} via +c.add_extension+ in the +Agent.new+ block.
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::VectorDb::Extension.new(
    #       backend: Pikuri::VectorDb::Backend::InMemory.new,
    #       source: '~/notes',
    #     )
    #   end
    #
    # On +configure+ it registers three tools ({Tools::Search} +
    # {Tools::Read} + {Tools::Reindex}) and nothing else. It does *not* index:
    # when/whether to populate the corpus is host policy.
    #
    # == The host owns population
    #
    # The extension exposes its {Indexer} via {#indexer}; the host fills the
    # corpus however it likes — an explicit +indexer.index_if_empty!+ at boot, a
    # {Watcher} around it (whose boot sweep populates an empty backend then
    # tracks edits), or nothing (the agent calls +vectordb_reindex+ when asked;
    # {Tools::Search} returns no hits and says so until then). All equally valid;
    # the same host-owned shape as the {Watcher}, keeping wiring *and* timing
    # visible in the host rather than in a constructor knob.
    #
    # == Changed your embedder or chunker? Reindex fully.
    #
    # Neither a {Watcher} nor +index_if_empty!+ reacts to a config change (the
    # signal is the byte hash), so swapping the embedder model or chunker window
    # leaves every indexed chunk silently stale — new queries embed with the new
    # model but score against old-model vectors. Run a full +vectordb_reindex+.
    #
    # == No system-prompt snippet; LIBRARIAN not auto-registered
    #
    # Unlike {Pikuri::Tasks::Extension}, no +<vectordb_usage>+ block is appended:
    # the parent may call +vectordb_search+ directly *or* delegate to
    # {LIBRARIAN}, and a snippet favoring one would conflict with the
    # trifecta-defense argument in the mediated mode. The bundled {LIBRARIAN}
    # persona is opt-in (same precedent as +Pikuri::Code::GIT_REPO_RESEARCHER+) —
    # hosts wanting sub-agent recall add it via +SubAgent::Extension.new(personas:
    # [LIBRARIAN])+, keeping the +pikuri-subagents+ dependency registration-only.
    class Extension
      include Pikuri::Agent::Extension

      # @return [Indexer] the constructed {Indexer}, exposed so the host can
      #   drive population (see the class "host owns population" header).
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

      # Register {Tools::Search} + {Tools::Read} + {Tools::Reindex} onto +c+; does
      # not index. Raises if any of the three names is pre-registered — the
      # extension is their single owner, and a duplicate would point at a
      # different Indexer / Embedder / backend.
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
