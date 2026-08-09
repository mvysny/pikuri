# frozen_string_literal: true

module Pikuri
  module VectorDb
    module Tools
      # The LLM-facing +vectordb_read+ tool — companion to {Tools::Search}:
      # where search returns ranked *chunks* (lossy, capped at
      # {Search::SNIPPET_LENGTH}), read pulls one full document into context by
      # the +source+ path search printed. The loop is *search to locate → read
      # the one or two clean hits in full → distil*, so the agent stops
      # re-querying to reconstruct a document it already found.
      #
      # == Does not widen the trifecta
      #
      # Reading is *inbound only*. The lethal trifecta's load-bearing leg is
      # egress; this pours more (already-private, already-possibly-poisoned)
      # corpus content in but adds no way out, so both wirings stay safe — the
      # egress-free +bin/pikuri-corpus+ agent stays egress-free, and the
      # {LIBRARIAN} privilege-separation argument survives (a poisoned document
      # still has no hand to act with). See {LIBRARIAN}.
      #
      # == The read domain is exactly the search domain
      #
      # +source+ must be a key the {Indexer} actually produced — checked against
      # {Backend#source_indexed?} before any disk access — so the only legal
      # inputs are the citations search handed the model, and a poisoned chunk
      # saying "read ../../.ssh/id_rsa" fails the membership gate (not an indexed
      # source). That's what keeps this from being a general file reader under a
      # friendly name. A lexical containment check (resolved path under the
      # corpus {Indexer#root}) backs the gate as defense-in-depth.
      #
      # Reads are line-windowed by {Pikuri::FileType.read_as_text_paged} — the
      # same windower and caps as {Pikuri::Workspace::Read}, returning a
      # {Pikuri::Extractor::Page}, but with no +cat -n+ prefix (nothing edits
      # these; the citation unit is the +source+, and dropping the prefix saves
      # tokens). Extraction routes through the same {Pikuri::Extractor} registry
      # the {Indexer} uses, so a read matches what was indexed exactly (modulo
      # later edits), +"--- Page N ---"+ markers included. Images / binaries /
      # vanished file / malformed PDF come back as +"Error: ..."+, not raises.
      class Read < Pikuri::Tool
        # @return [Integer] default value of the +limit+ parameter
        #   (number of lines returned per call). Aliases the shared
        #   {Pikuri::Extractor::PAGE_DEFAULT_LIMIT}.
        DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

        # @return [String] human-readable form of the shared byte cap
        #   ({Pikuri::Extractor::PAGE_MAX_BYTES}) for the continuation
        #   marker.
        MAX_BYTES_LABEL = "#{Pikuri::Extractor::PAGE_MAX_BYTES / 1024} KB"

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

        # @param backend [#source_indexed?] any {Backend}
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
            },
            # As {Search}: corpus bytes into the context, nothing outbound.
            trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: :hard, egress: :none)
          )
        end

        # Resolve +source+ against the corpus root, enforce the
        # membership gate + containment, extract text, and window it.
        # Public so specs can exercise the read path without a Tool
        # wrapper.
        #
        # @param backend [#source_indexed?]
        # @param root [Pathname]
        # @param source [String] the source path as supplied by the LLM
        # @param offset [Integer] 1-indexed line to start at
        # @param limit [Integer] maximum lines to return
        # @return [String] tool observation — the windowed text or an
        #   +"Error: ..."+ string.
        def self.read(backend:, root:, source:, offset:, limit:)
          return "Error: offset must be >= 1, got #{offset}" if offset < 1
          return "Error: limit must be >= 1, got #{limit}"   if limit < 1

          unless backend.source_indexed?(source)
            return "Error: \"#{source}\" is not in the indexed corpus. " \
                   'Use vectordb_search to find a source path, then read that.'
          end

          resolved = root.join(source).expand_path
          unless contained?(resolved, root)
            return "Error: \"#{source}\" resolves outside the corpus root."
          end

          render(Pikuri::FileType.read_as_text_paged(resolved, offset: offset, limit: limit), source: source)
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

        # Lexical containment: +resolved+ must be the root or sit beneath it.
        # Lexical, not +realpath+, on purpose — the membership gate already
        # restricts +source+ to indexer keys, and resolving symlinks here would
        # wrongly reject a symlinked document the {Indexer} chose to index. Only
        # catches a +..+ / absolute escape that somehow passed the gate.
        #
        # @param resolved [Pathname]
        # @param root [Pathname]
        # @return [Boolean]
        def self.contained?(resolved, root)
          base = root.expand_path.to_s
          resolved.to_s == base || resolved.to_s.start_with?(base + File::SEPARATOR)
        end
        private_class_method :contained?

        # Format a {Pikuri::Extractor::Page} as the observation: the lines
        # joined plain (no +cat -n+ prefix), followed by a trailer keyed
        # on the citation +source+ that tells the model whether to page
        # on. PDF pages already carry their +"--- Page N ---"+ markers
        # from the extractor.
        #
        # @param page [Pikuri::Extractor::Page]
        # @param source [String] the citation, used in the empty /
        #   end-of-document messages.
        # @return [String]
        def self.render(page, source:)
          if page.lines.empty?
            return "(#{source} is empty)" if page.total_lines.zero?

            return "Error: offset #{page.start_line} is beyond end of document " \
                   "(#{page.total_lines} lines total)."
          end

          last = page.start_line + page.lines.length - 1
          body = page.lines.join("\n")
          trailer =
            if page.byte_capped
              "(Output capped at #{MAX_BYTES_LABEL}. Showing lines #{page.start_line}-#{last}. " \
                "Use offset=#{last + 1} to continue.)"
            elsif page.more
              total = page.total_lines ? " of #{page.total_lines}" : ''
              "(Showing lines #{page.start_line}-#{last}#{total}. Use offset=#{last + 1} to continue.)"
            else
              "(End of #{source} — #{page.total_lines} lines.)"
            end

          "#{body}\n\n#{trailer}"
        end
        private_class_method :render
      end
    end
  end
end
