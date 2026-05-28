# frozen_string_literal: true

require 'pathname'

module Pikuri
  module VectorDb
    # The composing piece of the vectordb pipeline. Walks the
    # configured +sources+, enumerates indexable files (filtering
    # out the {DENYLIST} and dot-files), extracts text via
    # {Pikuri::FileType.read_as_text}, chunks via the configured
    # {Chunker}, embeds via the configured {Embedder}, and
    # {Backend#upsert}s the result.
    #
    # == Three public entry points
    #
    # * +#index_all!+ — unconditionally index every source file.
    #   Caller is responsible for first nuking the backend if a
    #   full re-index is wanted.
    # * +#reindex!+ — convenience for "nuke and re-index":
    #   +backend.delete_all+ followed by +index_all!+. The
    #   v1 nuke-and-reload path; what
    #   {Pikuri::VectorDb::Extension} wires to the eventual
    #   +vectordb_reindex+ tool.
    # * +#index_if_empty!+ — only index if +backend.count.zero?+.
    #   The boot-time path: +Backend::InMemory+ always indexes
    #   (RAM-only, always empty); +Backend::Chroma+ only indexes
    #   on first boot or after a manual reindex.
    #
    # == Logging
    #
    # Each indexed file emits one INFO line through
    # {Pikuri::VectorDb::LOGGER}, prefixed with a
    # +[i/total]+ progress counter (e.g.
    # +[3/50] cooking/risotto.md: 7 chunks+). Indexing local
    # corpora against a local llama.cpp embedder takes minutes,
    # and the user is blocked on the agent boot, so progress
    # visibility is load-bearing here. Hosts with a richer
    # output channel (a future TUI, a web client) can mute or
    # reroute the +PIKURI_LOG_VECTORDB+ stream — see
    # {Pikuri.logger_for}.
    #
    # WARN lines surface skip reasons: image / binary file in
    # the corpus, source path doesn't exist, file produced no
    # text (scanned-image PDF, empty file).
    #
    # == Chunk identity
    #
    # +Chunk.id+ is +"source:index"+ — the relative source path
    # plus the chunk's ordinal within that file. Readable in
    # logs, deterministic, makes the "one source, many chunks"
    # rule visible. Hash-based IDs would be forward-compatible
    # with content-addressing for incremental re-index, but v1
    # nuke-and-reload doesn't need that and the readable form
    # is more useful day-to-day.
    #
    # +Chunk.source+ is the path *relative to the source root
    # the file was found under* — short, citation-friendly,
    # survives moving the corpus. Absolute paths would tie the
    # backend to a particular machine layout; relative travels.
    #
    # == Errors mid-indexing
    #
    # If the embedder fails mid-run (network blip, provider 5xx),
    # the exception propagates and indexing aborts. Per CLAUDE.md
    # "Errors are loud" — caller is internal pikuri code, not the
    # LLM. The backend is left in a partial state; the user's
    # recourse is +reindex!+ which nukes and starts over. The
    # +InMemory+ backend resets on process restart anyway; only
    # +Chroma+ persists partial state, and even then a fresh
    # +reindex!+ recovers cleanly.
    class Indexer
      LOGGER = Pikuri.logger_for('VectorDb::Indexer')

      # Basenames that are skipped during the walk. Targets the
      # cruft people accidentally have inside a notes folder
      # they've put under +sources:+ — a cloned repo, a Python
      # workspace, a build directory. Conservative; configurable
      # ignore rules are a follow-up (see IDEAS.md §"Vector DB /
      # RAG" → "Open questions").
      DENYLIST = %w[
        .git
        node_modules
        __pycache__
        venv
        target
        build
        dist
        out
        vendor
      ].freeze

      # @param backend [#upsert, #query, #delete_all, #count]
      #   any {Backend} implementation.
      # @param sources [Array<String, Pathname>] paths to index.
      #   Files index directly; directories are walked
      #   recursively. Tilde-expanded.
      # @param embedder [#embed] an {Embedder} or anything else
      #   responding to +embed(Array<String>) -> Array<Array<Float>>+.
      # @param chunker [#chunk] a {Chunker::FixedWindow} or
      #   anything else responding to +chunk(String) -> Array<String>+.
      # @return [Indexer]
      def initialize(backend:, sources:, embedder:, chunker:)
        @backend  = backend
        @sources  = sources.map { |s| Pathname.new(s).expand_path }
        @embedder = embedder
        @chunker  = chunker
      end

      # Walk every source, index every reachable non-denylisted
      # file. Returns the total chunk count emitted into the
      # backend across this invocation.
      #
      # @return [Integer]
      def index_all!
        files = enumerate_files
        if files.empty?
          LOGGER.warn("no indexable files found across #{@sources.length} source(s)")
          return 0
        end

        LOGGER.info("indexing #{files.length} file(s) from #{@sources.length} source(s)")
        started = Time.now
        total_chunks = 0
        files.each_with_index do |(root, path), i|
          total_chunks += index_file(root: root, path: path, i: i + 1, total: files.length)
        end
        LOGGER.info(format(
                      'done: %d file(s), %d chunks, %.1fs',
                      files.length, total_chunks, Time.now - started
                    ))
        total_chunks
      end

      # +backend.delete_all+ followed by {#index_all!}. The
      # v1 nuke-and-reload reindex path.
      #
      # @return [Integer] total chunks indexed.
      def reindex!
        LOGGER.info('reindex: clearing backend')
        @backend.delete_all
        index_all!
      end

      # Index only if the backend is currently empty. The boot-time
      # entry point — InMemory backends always re-index (RAM-only);
      # Chroma backends only re-index on first boot or after a
      # manual +reindex!+.
      #
      # @return [Integer] total chunks indexed (0 if backend was
      #   non-empty and the indexer was skipped).
      def index_if_empty!
        existing = @backend.count
        if existing.positive?
          LOGGER.info("backend already has #{existing} chunk(s); skipping boot index")
          return 0
        end
        index_all!
      end

      private

      # Walk every configured source, return a flat list of
      # +[root, file_path]+ pairs. +root+ is the source root the
      # file lives under, used later to compute the relative
      # +Chunk.source+. Sources that point at a single file land
      # as +[file.parent, file]+ — citation is just the basename.
      # Sources that don't exist on disk produce a WARN and are
      # skipped.
      def enumerate_files
        @sources.flat_map do |root|
          if root.file?
            [[root.parent, root]]
          elsif root.directory?
            list_files(root).map { |f| [root, f] }
          else
            LOGGER.warn("source path does not exist or is not a regular file/dir: #{root}")
            []
          end
        end
      end

      # Depth-first walk of +root+'s contents, applying
      # {DENYLIST} and the dotfile/dot-dir skip rule. Sorts
      # entries by basename so the indexing order is
      # deterministic across runs (useful for reading logs
      # against the same corpus).
      def list_files(root)
        files = []
        walk = lambda do |dir|
          entries = dir.each_child.to_a.sort_by { |e| e.basename.to_s }
          entries.each do |entry|
            name = entry.basename.to_s
            next if name.start_with?('.')
            next if DENYLIST.include?(name)

            if entry.directory?
              walk.call(entry)
            elsif entry.file?
              files << entry
            end
          end
        end
        walk.call(root)
        files
      end

      # Process one file end-to-end: extract → chunk → embed →
      # upsert. Catches the three "skip" cases ({FileType} refusal
      # for image / binary / unsupported, missing-after-enumeration
      # races, malformed PDF) and surfaces them as a single WARN
      # rather than aborting the whole index. Embedder / backend
      # failures still propagate.
      #
      # @return [Integer] number of chunks emitted for this file.
      def index_file(root:, path:, i:, total:)
        source = path.relative_path_from(root).to_s
        text = begin
          Pikuri::FileType.read_as_text(path)
        rescue ArgumentError, Errno::ENOENT, RuntimeError => e
          LOGGER.warn("[#{i}/#{total}] skipping #{source}: #{e.message}")
          return 0
        end

        chunk_texts = @chunker.chunk(text)
        if chunk_texts.empty?
          LOGGER.warn("[#{i}/#{total}] #{source}: no extractable text, skipping")
          return 0
        end

        vectors = @embedder.embed(chunk_texts)
        chunks = chunk_texts.each_with_index.map do |chunk_text, idx|
          Chunk.new(
            id: "#{source}:#{idx}",
            source: source,
            text: chunk_text,
            metadata: { offset: idx }
          )
        end

        @backend.upsert(chunks: chunks, vectors: vectors)
        LOGGER.info("[#{i}/#{total}] #{source}: #{chunks.length} chunk(s)")
        chunks.length
      end
    end
  end
end
