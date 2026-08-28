# frozen_string_literal: true

require 'stringio'

module Pikuri
  module Os
    # The +fileindex_read+ tool — read a file's full text *as stored in
    # the desktop index*, line-paged like {Pikuri::Workspace::Read}. The
    # companion to {FileindexSearch} (which locates + previews one match),
    # sharing its swappable +backend:+ ({LocalSearch} / {Recoll}).
    #
    # It reads the index, not the file: the index already holds every
    # indexed file's extracted plain text — PDFs/office docs included — so
    # this returns them in full with no extractor dependency. The cost is
    # that it's the *indexed snapshot* (can lag very recent edits, covers
    # only files the index knows); for a live or system text file
    # (+/etc+, +/var/log+, a just-written file), read it directly instead.
    #
    # +offset+ / +limit+ page exactly as in {Pikuri::Workspace::Read},
    # windowed through {Pikuri::Extractor.extract_paged} (a +StringIO+ over
    # the stored text) with the same +cat -n+ + trailer, caps, and markers.
    #
    # Sharing: +P_stateless+ — the backend is a stateless module over a
    # read-only index, so one instance serves any number of agents.
    class FileindexRead < Pikuri::Tool
      # @return [Integer] default +limit+ (lines per call); the shared
      #   page default, so it matches +read+.
      DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

      # @return [String] human-readable byte cap for the trailer.
      MAX_BYTES_LABEL = "#{Pikuri::Extractor::PAGE_MAX_BYTES / 1024} KB"

      # @return [String] opencode-shape description (summary + Usage).
      DESCRIPTION = <<~DESC
        Read a file's full text from the desktop search index, with line numbers.

        Usage:
        - The companion to fileindex_search: after it locates a file, read the file in full here.
        - Reads the indexed text, so PDFs and office documents come back as their extracted text — no special handling needed.
        - This is the indexed snapshot: it can lag very recent edits, and only files the index knows are available. For a live or system text file (/etc, /var/log, a just-written file), use the read tool instead.
        - Output is line-numbered `cat -n` style; use `offset` and `limit` to page. When the response ends in `Use offset=N to continue`, call again with that offset.
      DESC

      # @param backend [Module] a file-index backend ({LocalSearch} /
      #   {Recoll}); only +#read_text+ and +#check_binaries!+ are used here.
      # @raise [RuntimeError] if the backend's binary isn't on +PATH+.
      # @return [FileindexRead]
      def initialize(backend:)
        @backend = backend
        backend.check_binaries!
        super(
          name: 'fileindex_read',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :path,
                              'Absolute path to the file (as returned by ' \
                              'fileindex_search), e.g. "/home/u/Documents/report.pdf".'
            p.optional_integer :offset,
                               'Line number to start reading from (1-indexed). ' \
                               'Defaults to 1, e.g. 200.'
            p.optional_integer :limit,
                               'Maximum number of lines to read. Defaults to ' \
                               "#{DEFAULT_LIMIT}, e.g. 500."
          },
          execute: lambda { |path:, offset: 1, limit: DEFAULT_LIMIT|
            FileindexRead.read(path: path, offset: offset, limit: limit, backend: backend)
          },
          # As {FileindexSearch}: whole-machine reach, so both inbound legs are fixed.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: true, untrusted: :hard, egress_payload_review: :no_egress)
        )
      end

      # @param path [String]
      # @param backend [Module] the file-index backend to read from
      # @param offset [Integer] 1-indexed start line
      # @param limit [Integer] max lines
      # @return [String] the cat-n windowed text, or +"Error: ..."+
      def self.read(path:, backend:, offset: 1, limit: DEFAULT_LIMIT)
        return "Error: offset must be >= 1, got #{offset}" if offset < 1
        return "Error: limit must be >= 1, got #{limit}"   if limit < 1

        text = backend.read_text(path)
        if text.nil?
          return "Error: #{path} is not in the index (only indexed folders are " \
                 'available; PDFs and office docs are included). For a live or ' \
                 'system text file, use the read tool.'
        end

        page = Pikuri::Extractor.extract_paged(
          StringIO.new(text), content_type: 'text/plain', offset: offset, limit: limit
        )
        render_page(page)
      end

      # Render a {Pikuri::Extractor::Page} as +cat -n+ + a paging trailer,
      # mirroring {Pikuri::Workspace::Read}'s formatting.
      #
      # @param page [Pikuri::Extractor::Page]
      # @return [String]
      def self.render_page(page)
        return '(No indexed text for this file.)' if page.total_lines.zero?

        if page.lines.empty?
          return "Error: offset #{page.start_line} is beyond end of file " \
                 "(#{page.total_lines} lines total)"
        end

        last = page.start_line + page.lines.length - 1
        body = page.lines.each_with_index
                   .map { |line, i| format("%6d\t%s", i + page.start_line, line) }
                   .join("\n")

        trailer =
          if page.byte_capped
            "(Output capped at #{MAX_BYTES_LABEL}. Showing lines #{page.start_line}-#{last}. " \
              "Use offset=#{last + 1} to continue.)"
          elsif page.more
            total = page.total_lines ? " of #{page.total_lines}" : ''
            "(Showing lines #{page.start_line}-#{last}#{total}. Use offset=#{last + 1} to continue.)"
          else
            "(End of file - total #{page.total_lines} lines)"
          end

        "#{body}\n\n#{trailer}"
      end
      private_class_method :render_page
    end
  end
end
