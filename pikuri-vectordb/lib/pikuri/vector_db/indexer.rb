# frozen_string_literal: true

require 'pathname'
require 'digest'

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
    # == Incremental entry points (auto-watch)
    #
    # The {Watcher} daemon drives three further methods that touch
    # one file at a time instead of the whole corpus — see
    # +ideas/vectordb-incremental-reindex.md+:
    #
    # * +#reindex_file!(path)+ — extract → chunk → embed → atomic
    #   {Backend#replace_source}. The unit of incremental work.
    # * +#remove_file!(path)+ — {Backend#delete_by_source} for a
    #   file that was deleted or became unindexable.
    # * +#reconcile_plan+ — the boot sweep: diff the files on disk
    #   (by content hash) against {Backend#sources_with_hashes} and
    #   return the +{reindex:, remove:}+ work list, without
    #   executing it (the {Watcher} feeds it through its queue).
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
    # rule visible, and stable across reindexes of the same file.
    # Incremental reindex replaces a document by +source+ (via
    # {Backend#replace_source}), not by content-addressed id, so
    # the file's content hash lives in +Chunk.metadata[:hash]+
    # instead — the same value on every chunk of one file, which
    # is what lets {#reconcile_plan} read one chunk per source and
    # still know whether the file changed.
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
      # @param source [String, Pathname] path to index. A file
      #   indexes directly; a directory is walked recursively.
      #   Tilde-expanded.
      # @param embedder [#embed] an {Embedder} or anything else
      #   responding to +embed(Array<String>) -> Array<Array<Float>>+.
      # @param chunker [#chunk] a {Chunker::FixedWindow} or
      #   anything else responding to +chunk(String) -> Array<String>+.
      # @return [Indexer]
      #
      # == Why a single source (not an array)
      #
      # v0 of this API took +sources: ['~/notes', '~/docs']+
      # and used +path.relative_path_from(root)+ to derive
      # {Chunk.source}. Two files named +cooking.md+ across
      # different roots would produce identical +source+
      # values, hence identical +"#{source}:#{offset}"+ IDs;
      # {Backend#upsert}'s replace-by-id semantics would
      # silently let the second file's chunks overwrite the
      # first's. Single source eliminates the clash entirely.
      # Multiple-roots support is deferred — see IDEAS.md
      # §"Vector DB / RAG" → "Deferred".
      def initialize(backend:, source:, embedder:, chunker:)
        @backend  = backend
        @source   = Pathname.new(source).expand_path
        @embedder = embedder
        @chunker  = chunker
      end

      # @return [Pathname] the configured source, tilde-expanded.
      #   A single file or a directory tree. The {Watcher} reads
      #   this to decide what to watch and how to filter events.
      attr_reader :source

      # The directory whose tree is indexed — the anchor for every
      # relative {Chunk#source}. A directory source is its own
      # root; a single-file source roots at its parent (so the
      # citation is just the basename). The {Watcher} watches this
      # directory.
      #
      # @return [Pathname]
      def root
        @source.directory? ? @source : @source.parent
      end

      # Walk every source, index every reachable non-denylisted
      # file. Returns the total chunk count emitted into the
      # backend across this invocation.
      #
      # @return [Integer]
      def index_all!
        files = enumerate_files
        if files.empty?
          LOGGER.warn("no indexable files found under source: #{@source}")
          return 0
        end

        LOGGER.info("indexing #{files.length} file(s) from #{@source}")
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

      # Re-index a single file in place: extract → chunk → embed →
      # {Backend#replace_source}. The atomic unit of incremental
      # work the {Watcher} drives on a modify/add event.
      #
      # The embed happens *before* the backend write, so an embedder
      # outage raises here and leaves the previously-indexed chunks
      # untouched — see {Backend::Chroma#replace_source} for why the
      # ordering matters. A file that no longer yields text (emptied,
      # replaced by a binary, deleted under us) is treated as a
      # removal: its stale chunks are dropped and nothing is written,
      # so the index never retains orphans for it.
      #
      # @param path [String, Pathname] the file to reindex; need not
      #   exist (a vanished file resolves to a removal).
      # @return [Integer] number of chunks now stored for the file
      #   (0 if it was removed).
      # @raise [RuntimeError] if the embedder or backend fails — the
      #   {Watcher} logs it and moves on (loud, per CLAUDE.md).
      def reindex_file!(path)
        path   = Pathname.new(path).expand_path
        source = relative_source(path)

        texts = begin
          chunk_texts_for(path)
        rescue ArgumentError, Errno::ENOENT, RuntimeError => e
          LOGGER.info("reindex #{source}: unindexable (#{e.message}); removing from index")
          @backend.delete_by_source(source)
          return 0
        end

        if texts.empty?
          LOGGER.info("reindex #{source}: no indexable text; removing from index")
          @backend.delete_by_source(source)
          return 0
        end

        # embed_and_build is *outside* the rescue: an embedder outage
        # raises straight out, before replace_source touches the
        # backend, so the prior chunks survive (embed-before-delete).
        chunks, vectors = embed_and_build(source: source, path: path, chunk_texts: texts)
        @backend.replace_source(source: source, chunks: chunks, vectors: vectors)
        LOGGER.info("reindex #{source}: #{chunks.length} chunk(s)")
        chunks.length
      end

      # Drop a file's chunks from the index — the {Watcher}'s
      # response to a delete (or move-away) event. Idempotent:
      # removing a source that isn't indexed is a no-op.
      #
      # @param path [String, Pathname] the (now-absent) file.
      # @return [void]
      def remove_file!(path)
        source = relative_source(Pathname.new(path).expand_path)
        @backend.delete_by_source(source)
        LOGGER.info("removed #{source} from index")
        nil
      end

      # The boot reconciliation sweep, as a *plan* rather than an
      # action: walk the source tree, hash every file, diff against
      # {Backend#sources_with_hashes}, and return the work list. The
      # {Watcher} feeds this through its single work queue so the
      # sweep and live events share one last-intent-wins path (and so
      # teardown can interrupt between files) — see
      # +ideas/vectordb-incremental-reindex.md+.
      #
      # Uniform across backends with no +is_a?+ branch: +InMemory+
      # reports an empty manifest at boot (RAM reset) so every file
      # reads as new; +Chroma+ reports its persisted manifest so only
      # genuinely-changed files come back. The sweep also closes the
      # downtime gap — changes made while no {Watcher} was running are
      # invisible to the filesystem events but caught by the hash diff.
      #
      # @return [Hash{Symbol => Array<Pathname>}] +{reindex:, remove:}+
      #   — files to (re)index because they are new or changed, and
      #   files (as +root+/source paths) whose chunks should be
      #   dropped because they are gone from disk.
      def reconcile_plan
        on_disk = {} # source (String) => Pathname
        enumerate_files.each { |_root, p| on_disk[relative_source(p)] = p }
        indexed = @backend.sources_with_hashes

        reindex = on_disk.select { |source, path| indexed[source] != file_hash(path) }.values
        remove  = (indexed.keys - on_disk.keys).map { |source| root.join(source) }
        { reindex: reindex, remove: remove }
      end

      private

      # Walk the configured source, return an array of
      # +[root, file_path]+ pairs. +root+ is the source root
      # used later to compute the relative +Chunk.source+. A
      # source that points at a single file lands as
      # +[file.parent, file]+ — citation is just the basename.
      # A source that doesn't exist on disk produces a WARN and
      # an empty array.
      def enumerate_files
        if @source.file?
          [[@source.parent, @source]]
        elsif @source.directory?
          list_files(@source).map { |f| [@source, f] }
        else
          LOGGER.warn("source path does not exist or is not a regular file/dir: #{@source}")
          []
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
        source = relative_source(path)
        texts = begin
          chunk_texts_for(path)
        rescue ArgumentError, Errno::ENOENT, RuntimeError => e
          LOGGER.warn("[#{i}/#{total}] skipping #{source}: #{e.message}")
          return 0
        end

        if texts.empty?
          LOGGER.warn("[#{i}/#{total}] #{source}: no extractable text, skipping")
          return 0
        end

        # embed_and_build is outside the rescue so an embedder failure
        # propagates and aborts the run (see "Errors mid-indexing").
        chunks, vectors = embed_and_build(source: source, path: path, chunk_texts: texts)
        @backend.upsert(chunks: chunks, vectors: vectors)
        LOGGER.info("[#{i}/#{total}] #{source}: #{chunks.length} chunk(s)")
        chunks.length
      end

      # The relative path used as {Chunk#source} — the file's path
      # from {#root}. Single definition so the boot walk, the
      # incremental reindex, and the reconcile sweep all derive the
      # identical citation (and hence identical chunk ids) for a file.
      #
      # @param path [Pathname] an absolute path under {#root}.
      # @return [String]
      def relative_source(path)
        path.relative_path_from(root).to_s
      end

      # Read + chunk one file. Raised exceptions
      # ({Pikuri::FileType.read_as_text} refusing an image / binary /
      # unsupported type, an after-enumeration race, a malformed PDF)
      # are left for the caller to interpret — a boot skip vs. an
      # incremental removal.
      #
      # @param path [Pathname]
      # @return [Array<String>] chunk texts; empty when the file has
      #   no extractable text.
      def chunk_texts_for(path)
        @chunker.chunk(Pikuri::FileType.read_as_text(path))
      end

      # Embed the chunk texts and assemble {Chunk}s with stable ids
      # (+"source:offset"+) and +offset+/+hash+ metadata. Shared by
      # {#index_file} and {#reindex_file!} so the boot index and an
      # incremental reindex produce byte-identical chunks for a file.
      # The embed is the one network call here; keep it out of any
      # rescue that would swallow an outage.
      #
      # @param source [String]
      # @param path [Pathname] hashed for the +hash+ metadata.
      # @param chunk_texts [Array<String>] non-empty.
      # @return [Array(Array<Chunk>, Array<Array<Float>>)]
      def embed_and_build(source:, path:, chunk_texts:)
        hash    = file_hash(path)
        vectors = @embedder.embed(chunk_texts)
        chunks  = chunk_texts.each_with_index.map do |chunk_text, idx|
          Chunk.new(
            id: "#{source}:#{idx}",
            source: source,
            text: chunk_text,
            metadata: { offset: idx, hash: hash }
          )
        end
        [chunks, vectors]
      end

      # SHA-256 of the file's raw bytes — the change signal the
      # reconcile sweep diffs against {Backend#sources_with_hashes}.
      # Bytes, deliberately not extracted text: a chunker/embedder
      # config change does *not* alter the hash, so the sweep won't
      # react to it. Changing those settings needs a full
      # +vectordb_reindex+ — documented loudly on {Extension}.
      #
      # @param path [Pathname]
      # @return [String] hex digest.
      def file_hash(path)
        Digest::SHA256.hexdigest(File.binread(path))
      end
    end
  end
end
