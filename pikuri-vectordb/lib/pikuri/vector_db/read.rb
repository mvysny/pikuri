# frozen_string_literal: true

module Pikuri
  module VectorDb
    # The LLM-facing "read a whole indexed document" tool, exposed
    # as +vectordb_read+. The companion to {Search}: where
    # +vectordb_search+ returns ranked *chunks* (lossy fragments
    # capped at {Search::SNIPPET_LENGTH}), +vectordb_read+ pulls one
    # full document into context by the +source+ path that search
    # already printed. The intended loop is
    # *search to locate → read the one or two clean hits in full →
    # distil* — so the agent stops re-querying with ever-more-elaborate
    # phrasings just to reconstruct a document it already found.
    #
    # == Why this does not widen the trifecta
    #
    # Reading is *inbound only*. The lethal trifecta needs three legs
    # — private data, untrusted content, and an outbound channel — and
    # the load-bearing one is egress. +vectordb_read+ pours more
    # (already-private, already-possibly-poisoned) corpus content into
    # context but adds no new way to send anything out, so it is safe
    # by construction in both wirings: the egress-free
    # +bin/pikuri-corpus+ agent stays egress-free, and the {LIBRARIAN}
    # sub-agent's privilege-separation argument survives intact — a
    # poisoned full document still has no hand to act with. See
    # {LIBRARIAN} and IDEAS.md §"Vector DB / RAG".
    #
    # == The read domain is exactly the search domain
    #
    # The +source+ argument must be a key the {Indexer} actually
    # produced — verified against {Backend#sources_with_hashes} before
    # any disk access. So the only legal inputs are the citations
    # +vectordb_search+ handed the model; a poisoned chunk that says
    # "read ../../.ssh/id_rsa" fails the membership gate (that string
    # is not an indexed source). This is what keeps the tool from being
    # a general-purpose file reader smuggled in under a friendly name.
    # A lexical containment check (resolved path must sit under the
    # corpus {Indexer#root}) backs the gate as defense-in-depth for any
    # future non-filesystem source type.
    #
    # == Bounding / pagination
    #
    # A full document can be far larger than the {Search} snippet — the
    # {Chunker} exists precisely because documents are big. So reads are
    # line-windowed with the same caps and continuation-trailer
    # convention as {Pikuri::Workspace::Read}: {DEFAULT_LIMIT} lines or
    # {MAX_BYTES} bytes per call, whichever fires first, and a
    # +Use offset=N to continue+ hint when more remains. Unlike
    # +Workspace::Read+ there is no +cat -n+ line-number prefix: nothing
    # downstream edits these documents (the citation unit is the
    # +source+ path, not a line), and dropping the prefix saves tokens
    # on exactly the operation whose point is to spend context wisely.
    #
    # == Errors the LLM can react to
    #
    # Extraction reuses {Pikuri::FileType.read_as_text} — the same
    # extractor the {Indexer} chunked from, so what you read matches
    # what was indexed (modulo edits to the file since). PDFs extract to
    # text automatically; images / binaries / a vanished file / a
    # malformed PDF all come back as +"Error: ..."+ observations rather
    # than raising, per CLAUDE.md "Errors are loud" (these are failures
    # the agent reacts to, not pikuri bugs).
    class Read < Pikuri::Tool
      # @return [Integer] default value of the +limit+ parameter
      #   (number of lines returned per call). Matches
      #   {Pikuri::Workspace::Read::DEFAULT_LIMIT}.
      DEFAULT_LIMIT = 2000

      # @return [Integer] per-line character cap; longer lines are
      #   truncated with {LINE_TRUNCATION_MARKER}.
      MAX_LINE_LENGTH = 2000

      # @return [String] suffix appended to lines truncated by
      #   {MAX_LINE_LENGTH}.
      LINE_TRUNCATION_MARKER = "... (line truncated to #{MAX_LINE_LENGTH} chars)"

      # @return [Integer] hard byte cap on content collected per call;
      #   bypassable by paging via +offset+.
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [String] static description shown to the LLM,
      #   opencode-shape (summary + +Usage:+ bullets).
      DESCRIPTION = <<~DESC
        Read a full indexed document by its `source` path (the citation from vectordb_search).

        Usage:
        - Use after vectordb_search surfaces a clean hit you want in full, instead of re-querying for more fragments of the same document.
        - `source` must be a path a vectordb_search result returned; you cannot read arbitrary files, only indexed documents.
        - Large documents are paged: when the output ends in `Use offset=N to continue`, call again with that offset.
        - Reading a whole document spends context — read the one or two best hits in full, not every result.
      DESC

      # @param backend [#sources_with_hashes] any {Backend}
      #   implementation; consulted for the membership gate.
      # @param root [Pathname] the corpus root — {Indexer#root}.
      #   Relative +source+ paths resolve against it.
      # @return [Read]
      def initialize(backend:, root:)
        super(
          name: 'vectordb_read',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :source,
                              'Source path from a vectordb_search result, ' \
                              'e.g. "notes/cooking.md".'
            p.optional_integer :offset,
                               'Line to start reading from (1-indexed). ' \
                               'Defaults to 1, e.g. 200.'
            p.optional_integer :limit,
                               'Maximum number of lines to read. Defaults to ' \
                               "#{DEFAULT_LIMIT}, e.g. 500."
          },
          execute: lambda { |source:, offset: 1, limit: DEFAULT_LIMIT|
            Read.read(backend: backend, root: root, source: source, offset: offset, limit: limit)
          }
        )
      end

      # Resolve +source+ against the corpus root, enforce the
      # membership gate + containment, extract text, and window it.
      # Public so specs can exercise the read path without a Tool
      # wrapper.
      #
      # @param backend [#sources_with_hashes]
      # @param root [Pathname]
      # @param source [String] the source path as supplied by the LLM
      # @param offset [Integer] 1-indexed line to start at
      # @param limit [Integer] maximum lines to return
      # @return [String] tool observation — the windowed text or an
      #   +"Error: ..."+ string.
      def self.read(backend:, root:, source:, offset:, limit:)
        return "Error: offset must be >= 1, got #{offset}" if offset < 1
        return "Error: limit must be >= 1, got #{limit}"   if limit < 1

        unless backend.sources_with_hashes.key?(source)
          return "Error: \"#{source}\" is not in the indexed corpus. " \
                 'Use vectordb_search to find a source path, then read that.'
        end

        resolved = root.join(source).expand_path
        unless contained?(resolved, root)
          return "Error: \"#{source}\" resolves outside the corpus root."
        end

        window(Pikuri::FileType.read_as_text(resolved), source: source, offset: offset, limit: limit)
      rescue Errno::ENOENT
        "Error: indexed document \"#{source}\" is no longer on disk; the index may be stale " \
          '(run vectordb_reindex to refresh).'
      rescue ArgumentError => e
        # read_as_text refusing an image / binary / directory.
        "Error: cannot read \"#{source}\" as text: #{e.message}"
      rescue RuntimeError => e
        # read_as_text on a malformed / unsupported PDF.
        "Error: #{e.message}"
      end

      # Lexical containment: +resolved+ (already +expand_path+'d) must
      # be the root itself or sit beneath it. Lexical, not +realpath+,
      # on purpose — the membership gate already restricts +source+ to
      # indexer-produced keys, and resolving symlinks here would
      # wrongly reject a symlinked document the {Indexer} itself chose
      # to index. This check only catches a +..+ / absolute escape that
      # somehow passed the gate.
      #
      # @param resolved [Pathname]
      # @param root [Pathname]
      # @return [Boolean]
      def self.contained?(resolved, root)
        base = root.expand_path.to_s
        resolved.to_s == base || resolved.to_s.start_with?(base + File::SEPARATOR)
      end
      private_class_method :contained?

      # Slice +text+ to at most +limit+ lines from +offset+, stopping
      # early at {MAX_BYTES}. Over-long lines are truncated with
      # {LINE_TRUNCATION_MARKER}. The trailer reports the window and a
      # next-offset hint when more remains, mirroring
      # {Pikuri::Workspace::Read}.
      #
      # @param text [String] full extracted document text
      # @param source [String] for the empty / end-of-document messages
      # @param offset [Integer] 1-indexed start line
      # @param limit [Integer] maximum lines
      # @return [String]
      def self.window(text, source:, offset:, limit:)
        return "(#{source} is empty)" if text.empty?

        lines = text.lines(chomp: true)
        total = lines.length
        start_index = offset - 1
        if start_index >= total
          return "Error: offset #{offset} is beyond end of document (#{total} lines total)."
        end

        collected    = []
        bytes        = 0
        byte_cap_hit = false
        lines[start_index, limit].each do |raw|
          line = raw.length > MAX_LINE_LENGTH ? raw[0, MAX_LINE_LENGTH] + LINE_TRUNCATION_MARKER : raw
          size = line.bytesize + 1 # +1 for the joining newline
          if bytes + size > MAX_BYTES
            byte_cap_hit = true
            break
          end
          collected << line
          bytes += size
        end

        last = offset + collected.length - 1
        body = collected.join("\n")
        trailer =
          if byte_cap_hit
            "(Output capped at #{MAX_BYTES_LABEL}. Showing lines #{offset}-#{last} of #{total}. " \
              "Use offset=#{last + 1} to continue.)"
          elsif last < total
            "(Showing lines #{offset}-#{last} of #{total}. Use offset=#{last + 1} to continue.)"
          else
            "(End of #{source} — #{total} lines.)"
          end

        "#{body}\n\n#{trailer}"
      end
      private_class_method :window
    end
  end
end
