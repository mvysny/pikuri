# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The host-facing API: wire topical retrieval over a local corpus onto a
    # {Pikuri::Agent} via +c.add_extension+ in the +Agent.new+ block.
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::VectorDb::Extension.new(
    #       backend: Pikuri::VectorDb::Backend::InMemory.new,
    #       source: '~/notes',
    #       private: true, trusted: true,   # what this corpus is; both default off
    #     )
    #   end
    #
    # The two flags are the corpus's trifecta declaration — {#private?} and
    # {#trusted?} own what each one claims, and {Tools::Search} /
    # {Tools::Read} derive their legs from them. Nothing about them is a
    # defense: they decide what the boot map *prints*.
    #
    # On +configure+ it registers three tools ({Tools::Search} +
    # {Tools::Read} + {Tools::Reindex}) and nothing else. It does *not* index:
    # when/whether to populate the corpus is host policy.
    #
    # == This is the primitive, not a retrieval system
    #
    # What ships here is *topical* retrieval: pure geometry over meaning
    # vectors, which answers "what is this document about?" and structurally
    # cannot answer completeness ("every note mentioning Acme" — top-k is a
    # sample, and cosine has no calibrated zero to cut at) or exactness
    # ("invoice #4471" — rare tokens are what embedders rank worst). Those
    # need a keyword index beside the vectors, which is +pikuri-rag+: it
    # decorates whatever +backend:+ you pass here and ships +rag_search+ /
    # +rag_find+ over the same corpus. The two extensions are **mutually
    # exclusive on one agent** — {#configure} refuses a pre-registered
    # +rag_*+ tool, and {Pikuri::Rag::Extension} refuses +vectordb_*+.
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

      # Whether this corpus may hold data worth exfiltrating — the lethal
      # trifecta's private leg, which {Tools::Search} and {Tools::Read} inherit
      # from here.
      #
      # The framework cannot answer this for you: sensitivity is a property of
      # the *data*, not of the tool, and +~/notes+ and +~/case-files+ are
      # indistinguishable from the outside. Same declaration
      # {Pikuri::Workspace::Filesystem#private?} makes for the file tools, on
      # the second object that owns a reachable set of documents.
      #
      # @return [Boolean] default +false+
      def private? = @private

      # Whether every byte in this corpus is yours — the opt-out from the two
      # reading tools' default +:hard+ untrusted leg. Three clauses, all of
      # them load-bearing:
      #
      # 1. *Every source under +source+ was reviewed by you in the form the
      #    model will read it.* For plain text that is the file. For anything
      #    the {Pikuri::Extractor} registry converts it is the *extraction*,
      #    and the gap is enormous: white-on-white text, hidden-text
      #    attributes, off-page glyphs, comments, tracked changes, form fields
      #    and metadata are invisible to a reader of the rendered document and
      #    fully present after extraction. Reading a rendered PDF approves a
      #    *proxy*, not the payload — the ingest mirror of why +curl+'s egress
      #    grades +:unreviewed+. So either keep such files out of a trusted
      #    corpus, or convert first (+Pikuri::Extractor.extract+), read the
      #    conversion, and index that text with the original left outside.
      # 2. *Nobody else writes into that folder.* Trust is a claim about who
      #    can write, not about today's content — with a {Watcher} a file that
      #    lands later is indexed within seconds. A shared Nextcloud folder, a
      #    team Drive, a scanner's output directory and a mail client's
      #    attachment folder all falsify the flag the moment someone else drops
      #    a file in.
      # 3. *The backend collection holds only what this folder filled it with.*
      #    A persistent backend keeps whatever it was given: point a reused
      #    collection at a new +source+ and yesterday's documents still answer
      #    queries under today's declaration. Give each corpus root its own
      #    collection name.
      #
      # Says nothing about *parser* exposure: a hostile PDF exploiting poppler
      # is a code-exec/DoS vector against the extractor, not an injection
      # vector against the model, and the extractor gem owns it — never read
      # this flag as "safe to parse".
      #
      # @return [Boolean] default +false+
      def trusted? = @trusted

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
      # @param private [Boolean] this corpus may hold sensitive
      #   data; see {#private?}.
      # @param trusted [Boolean] every source in this corpus is
      #   yours, reviewed as the model reads it; see {#trusted?}
      #   for the three clauses you are signing.
      # @return [Extension]
      def initialize(backend:, source:,
                     embedder: nil, reranker: nil, chunker: nil,
                     private: false, trusted: false)
        @backend  = backend
        @embedder = embedder || Embedder.new
        @reranker = reranker
        @chunker  = chunker  || Chunker::FixedWindow.new(size: 512, overlap: 50)
        @private  = private
        @trusted  = trusted
        @legs = CorpusLegs.derive(private: private, trusted: trusted)
        @indexer = Indexer.new(
          backend:  @backend,
          source:   source,
          embedder: @embedder,
          chunker:  @chunker
        )
      end

      # Register {Tools::Search} + {Tools::Read} + {Tools::Reindex} onto +c+; does
      # not index.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      # @raise [RuntimeError] if any of the three names is pre-registered — the
      #   extension is their single owner, and a duplicate would point at a
      #   different Indexer / Embedder / backend — or if any +rag_*+ tool is,
      #   since +pikuri-rag+ is the alternative to this extension rather than a
      #   companion (see "This is the primitive").
      def configure(c)
        c.tools.each do |tool|
          next unless tool.name.start_with?('rag_')

          raise "#{tool.name} cannot be pre-registered when adding " \
                'Pikuri::VectorDb::Extension — the rag_* tool set (Pikuri::Rag::Extension) ' \
                'replaces this one over the same corpus; wire one or the other.'
        end

        %w[vectordb_search vectordb_read vectordb_reindex].each do |name|
          next unless c.tools.any? { |t| t.name == name }

          raise "#{name} cannot be pre-registered (in tools: or via c.add_tool) " \
                'when adding Pikuri::VectorDb::Extension — the extension auto-registers ' \
                'all three tools so they share the same Indexer / Embedder / backend.'
        end

        c.add_tool Tools::Search.new(embedder: @embedder, backend: @backend, reranker: @reranker, legs: @legs)
        c.add_tool Tools::Read.new(backend: @backend, root: @indexer.root, legs: @legs)
        c.add_tool Tools::Reindex.new(indexer: @indexer)
        nil
      end
    end
  end
end
