# frozen_string_literal: true

module Pikuri
  module Rag
    # The host-facing API: wire hybrid retrieval over a local corpus onto a
    # {Pikuri::Agent} via +c.add_extension+ in the +Agent.new+ block.
    #
    #   ext = Pikuri::Rag::Extension.new(
    #     backend: Pikuri::VectorDb::Backend::InMemory.new,
    #     source:  '~/notes',
    #     private: true, trusted: true,   # what this corpus is; both default off
    #   )
    #   agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension ext
    #   end
    #   watcher = Pikuri::VectorDb::Watcher.new(indexer: ext.indexer).start
    #
    # It registers four tools — +rag_search+, +rag_find+, +rag_read+,
    # +rag_reindex+ — and nothing else. It does *not* index: as with
    # {Pikuri::VectorDb::Extension}, when and whether to populate the corpus is
    # host policy, driven through {#indexer} (an explicit +index_if_empty!+, a
    # {Pikuri::VectorDb::Watcher}, or nothing at all — the agent then calls
    # +rag_reindex+ when asked).
    #
    # The constructor takes {Pikuri::VectorDb::Extension}'s parameters and
    # passes them through, so a host swaps one line to move a corpus from the
    # vector primitive to hybrid retrieval. It pairs +backend:+ with a
    # {Backend::Fts5} in one {Backend::Hybrid} and builds the vectordb
    # {Pikuri::VectorDb::Indexer} over that, which is what fills both stores
    # from one walk.
    #
    # == Exclusive with Pikuri::VectorDb::Extension
    #
    # {#configure} raises on any pre-registered +rag_*+ *or* +vectordb_*+ tool,
    # and {Pikuri::VectorDb::Extension#configure} does the mirror image — so
    # wiring both on one agent fails loudly whichever goes second, instead of
    # handing the model two search tools with different promises.
    #
    # == Which store to pair with which backend
    #
    # +store:+ is the keyword index's SQLite path, +":memory:"+ by default.
    # Guidance, not inference:
    #
    # * {Pikuri::VectorDb::Backend::InMemory} → +":memory:"+. Both stores
    #   reload from the corpus every boot, which is the teaching shape.
    # * Qdrant / Chroma → a file under {Pikuri::Paths.cache}, keyed by the
    #   collection name, so the two persist together.
    #
    # A mismatch is *correct* rather than broken — {Backend::Hybrid}'s
    # both-stores rule makes the boot sweep repair whichever store is behind —
    # but a persistent vector store beside a fresh +":memory:"+ index pays a
    # full re-embed at every boot. That is why this is a paragraph and not a
    # check: nothing here can tell whether +backend:+ persists.
    #
    # == Stemming
    #
    # +stemmer:+ decides what a word is indexed and searched under. The
    # default, {Stemmer::Identity}, leaves it to FTS5's English +porter+. For
    # Finnish, add the +voikko+ gem to the host and pass
    #
    #   stemmer: Pikuri::Rag::Stemmer::Voikko.new(::Voikko.new(language: 'fi'))
    #
    # Changing the stemmer of a file-backed +store:+ empties the keyword index
    # at boot, and the next index run refills both stores, re-embedding the
    # whole corpus (see {Backend::Fts5}'s "Stemming").
    #
    # == Changed your embedder or chunker? Reindex fully.
    #
    # Same as {Pikuri::VectorDb::Extension}: the change signal is the file's
    # byte hash, so swapping the embedder model or chunker window leaves every
    # indexed chunk silently stale. Run +rag_reindex+.
    #
    # == No LIBRARIAN, and no system-prompt snippet
    #
    # {Pikuri::VectorDb::LIBRARIAN} names +vectordb_*+ tools, so it cannot be
    # reused over this family; a +rag_*+ persona would be a new persona in this
    # gem, and nothing has asked for one. No +<rag_usage>+ block is appended
    # either — the split between "relevance" and "completeness" is what each
    # tool's own description is for.
    class Extension
      include Pikuri::Agent::Extension

      # The four tool names this extension owns, in registration order.
      #
      # @return [Array<String>]
      TOOL_NAMES = %w[rag_search rag_find rag_read rag_reindex].freeze

      # @return [String] the tool-name prefix handed to
      #   {Pikuri::VectorDb::Tools::Read} / {Pikuri::VectorDb::Tools::Reindex},
      #   which is the whole of what +rag_read+ / +rag_reindex+ needed.
      FAMILY = 'rag'

      # @return [Pikuri::VectorDb::Indexer] the indexer, over {#backend} so a
      #   run fills both stores — exposed so the host can drive population.
      attr_reader :indexer

      # @return [Backend::Hybrid] the composed backend the four tools share,
      #   built here from +backend:+ and +store:+ so a host wires one corpus
      #   rather than two stores.
      attr_reader :backend

      # Whether this corpus may hold data worth exfiltrating.
      #
      # @return [Boolean] default +false+. What the declaration claims — and
      #   why the framework cannot answer it for you — is
      #   {Pikuri::VectorDb::Extension#private?}'s to say.
      def private? = @private

      # Whether every byte in this corpus is yours, reviewed in the form the
      # model will read it.
      #
      # @return [Boolean] default +false+. The three clauses you are signing
      #   are {Pikuri::VectorDb::Extension#trusted?}'s — read them before
      #   passing +true+; nothing about the hybrid index changes them.
      def trusted? = @trusted

      # @param backend [#upsert, #query, #delete_all, #count] the *vector*
      #   backend — pass the same value {Pikuri::VectorDb::Extension} would
      #   take. The keyword store beside it is built here.
      # @param source [String, Pathname] path to index. A file indexes
      #   directly; a directory is walked recursively. Single source only, as
      #   {Pikuri::VectorDb::Indexer}.
      # @param embedder [#embed, nil] +nil+ constructs
      #   {Pikuri::VectorDb::Embedder} with the default model.
      # @param reranker [#rerank, nil] optional cross-encoder reranker over
      #   the fused candidates; +nil+ returns the fused top-k directly.
      # @param chunker [#chunk, nil] +nil+ constructs
      #   {Pikuri::VectorDb::Chunker::FixedWindow} with +size: 512,
      #   overlap: 50+.
      # @param private [Boolean] see {#private?}.
      # @param trusted [Boolean] see {#trusted?}.
      # @param store [String, Pathname] SQLite path for the keyword index, or
      #   +":memory:"+ (the default). See "Which store to pair with which
      #   backend".
      # @param stemmer [#stems, #index_stems, #id] see "Stemming".
      # @param exclude [Array<String, Pathname>] folders under +source+ never
      #   indexed; see {Pikuri::VectorDb::Indexer#initialize}.
      # @return [Extension]
      def initialize(backend:, source:,
                     embedder: nil, reranker: nil, chunker: nil,
                     private: false, trusted: false,
                     store: Backend::Fts5::MEMORY_STORE, stemmer: Stemmer::Identity, exclude: [])
        @backend  = Backend::Hybrid.new(vectors: backend,
                                        keywords: Backend::Fts5.new(store: store, stemmer: stemmer))
        @embedder = embedder || Pikuri::VectorDb::Embedder.new
        @reranker = reranker
        @chunker  = chunker || Pikuri::VectorDb::Chunker::FixedWindow.new(size: 512, overlap: 50)
        @private  = private
        @trusted  = trusted
        @legs = Pikuri::VectorDb::CorpusLegs.derive(private: private, trusted: trusted)
        @indexer = Pikuri::VectorDb::Indexer.new(
          backend:  @backend,
          source:   source,
          embedder: @embedder,
          chunker:  @chunker,
          exclude:  exclude
        )
      end

      # Register the four tools onto +c+; does not index.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      # @raise [RuntimeError] if any +rag_*+ or +vectordb_*+ tool is already
      #   registered — see "Exclusive with Pikuri::VectorDb::Extension".
      def configure(c)
        c.tools.each do |tool|
          next unless tool.name.start_with?('rag_', 'vectordb_')

          raise "#{tool.name} cannot be pre-registered (in tools: or via c.add_tool / " \
                'Pikuri::VectorDb::Extension) when adding Pikuri::Rag::Extension — it ' \
                'auto-registers all four rag_* tools so they share one Indexer / ' \
                'Embedder / backend, and the vectordb_* tool set is the alternative to ' \
                'this one, not a companion.'
        end

        c.add_tool Tools::Search.new(embedder: @embedder, backend: @backend,
                                     reranker: @reranker, legs: @legs)
        c.add_tool Tools::Find.new(backend: @backend, root: @indexer.root, legs: @legs)
        c.add_tool Pikuri::VectorDb::Tools::Read.new(backend: @backend, root: @indexer.root,
                                                     legs: @legs, family: FAMILY)
        c.add_tool Pikuri::VectorDb::Tools::Reindex.new(indexer: @indexer, family: FAMILY)
        nil
      end
    end
  end
end
