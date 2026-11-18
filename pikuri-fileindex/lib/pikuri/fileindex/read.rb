# frozen_string_literal: true

require 'stringio'

module Pikuri
  module Fileindex
    # The +fileindex_read+ tool — read a file's full text *as stored in
    # the desktop index*, line-paged like pikuri-workspace's +read+. The
    # companion to {Search} (which locates + previews one match),
    # sharing its swappable +backend:+ ({LocalSearch} / {Recoll}).
    #
    # It reads the index, not the file: the index already holds every
    # indexed file's extracted plain text — PDFs/office docs included — so
    # this returns them in full with no extractor dependency. The cost is
    # that it's the *indexed snapshot* (can lag very recent edits, covers
    # only files the index knows); a file just written is read from disk,
    # with pikuri-workspace's +read+.
    #
    # +offset+ / +limit+ page exactly as in pikuri-workspace's +read+,
    # windowed through {Pikuri::Extractor.extract_paged} (a +StringIO+ over
    # the stored text) and rendered by {Pikuri::Tool::Result.page}, so the
    # +cat -n+ prefix, trailer and caps are +read+'s own.
    #
    # +pattern+ turns the read into a +grep -n+ over the same text: only the
    # matching lines, numbered as a read numbers them. The search hit names
    # no line, so without it the model's only way to an answer deep in a
    # long PDF is to page through all of it; with it, the model reads just
    # around the lines that match. A regex, not the index's stemmed words:
    # inside one file an exact match is what the model wants, and the
    # index's own match positions (+fts:offsets+) came back as +(null):17+
    # on LocalSearch 3.11, naming no property.
    #
    # A line longer than the page's per-line cap is broken at a space first
    # ({.wrap}): localsearch keeps a PDF's line breaks and gives HTML a line
    # per paragraph, but hands an office document over as one line, which
    # the cap would cut after 2,000 characters, with no offset reaching the
    # rest.
    #
    # Only a path inside the +roots:+, with nothing hidden below a root, is
    # read; the path is the model's, so it is checked here even though the
    # localsearch miner never indexes a hidden file (recoll does).
    #
    # Sharing: +P_stateless+ — the backend is a stateless module over a
    # read-only index, so one instance serves any number of agents.
    class Read < Pikuri::Tool
      # @return [Integer] default +limit+ (lines per call); the shared
      #   page default, so it matches +read+.
      DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

      # @return [Numeric] seconds one +pattern+ may spend matching, so a
      #   catastrophically backtracking regex fails instead of hanging the
      #   turn.
      PATTERN_TIMEOUT = 2

      # @return [String] opencode-shape description (summary + Usage).
      DESCRIPTION = <<~DESC
        Read a file's full text from the desktop search index, with line numbers.

        Usage:
        - The companion to fileindex_search: after it locates a file, read the file in full here.
        - Reads the indexed text, so PDFs and office documents come back as their extracted text — no special handling needed.
        - This is the indexed snapshot: it can lag very recent edits, and only the files fileindex_search can find are available. For a file just written, use the read tool instead.
        - Output is line-numbered `cat -n` style; use `offset` and `limit` to page. When the response ends in `Use offset=N to continue`, call again with that offset.
        - To find something in a long file without reading all of it, pass `pattern`: you get only the matching lines with their line numbers. Then read around a match with `offset` a few lines before it and a small `limit`.
      DESC

      # @param backend [Module] a ready file-index backend, from
      #   {Fileindex.pick}; this tool uses only its +read_text+.
      # @param roots [Roots] the folders whose files may be read; their
      #   declaration grades the tool's legs
      # @return [Read]
      def initialize(backend:, roots:)
        @backend = backend
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
                               "#{DEFAULT_LIMIT}, e.g. 500. With `pattern`, the most matching lines to return."
            p.optional_string :pattern,
                              'Case-insensitive regular expression; returns only the lines that match, ' \
                              'with their line numbers, searching from `offset` on, e.g. "total|amount due".'
          },
          execute: lambda { |path:, offset: 1, limit: DEFAULT_LIMIT, pattern: nil|
            Read.read(path: path, offset: offset, limit: limit, pattern: pattern, backend: backend, roots: roots)
          },
          trifecta_legs: roots.legs
        )
      end

      # @param path [String] absolute or +~+-relative, inside +roots+
      # @param backend [Module] the file-index backend to read from
      # @param roots [Roots] the folders whose files may be read
      # @param offset [Integer] 1-indexed start line
      # @param limit [Integer] max lines; with +pattern+, max matching lines
      # @param pattern [String, nil] case-insensitive regex; when given, only
      #   the matching lines from +offset+ on are returned (see {.grep})
      # @return [Pikuri::Tool::Result] the cat-n windowed text (+"Read 214
      #   lines"+), the matching lines (+"Found 6 lines"+), or
      #   {Pikuri::Tool::Result.error}
      def self.read(path:, backend:, roots:, offset: 1, limit: DEFAULT_LIMIT, pattern: nil)
        return Pikuri::Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
        return Pikuri::Tool::Result.error("limit must be >= 1, got #{limit}") if limit < 1

        pattern = pattern.to_s
        regex = nil
        unless pattern.empty?
          begin
            regex = Regexp.new(pattern, Regexp::IGNORECASE, timeout: PATTERN_TIMEOUT)
          rescue RegexpError => e
            return Pikuri::Tool::Result.error("bad pattern: #{e.message}")
          end
        end

        return Pikuri::Tool::Result.error("path must be absolute, got '#{path}'.") unless path.start_with?('/', '~')

        begin
          path = File.expand_path(path)
        rescue ArgumentError => e # "~nosuchuser"
          return Pikuri::Tool::Result.error("bad path '#{path}': #{e.message}")
        end
        real = roots.resolve(path)
        unless real
          return Pikuri::Tool::Result.error("#{path} is not inside the folders you can read " \
                                            "(#{roots.dirs.join(', ')}), or is hidden.")
        end
        path = real

        text = backend.read_text(path)
        if text.nil?
          return Pikuri::Tool::Result.error("#{path} is not in the index (PDFs and office docs are included). " \
                                            'For a file just written, use the read tool.')
        end

        text = wrap(text)
        return grep(text, regex, offset: offset, limit: limit) if regex

        page = Pikuri::Extractor.extract_paged(
          StringIO.new(text), content_type: 'text/plain', offset: offset, limit: limit
        )
        Pikuri::Tool::Result.page(page, empty_note: '(No indexed text for this file.)')
      end

      # The lines of +text+ from +offset+ on that match +regex+, +cat -n+
      # numbered as a plain read numbers them, stopping at +limit+ matches or
      # {Pikuri::Extractor::PAGE_MAX_BYTES}, whichever comes first; a stop
      # names the offset to continue from.
      #
      # @param text [String] the file's indexed text
      # @param regex [Regexp]
      # @param offset [Integer] 1-indexed first line searched
      # @param limit [Integer] max matching lines
      # @return [Pikuri::Tool::Result] the lines and a footer (+"Found 6
      #   lines"+), or {Pikuri::Tool::Result.error} when the pattern times out
      def self.grep(text, regex, offset:, limit:)
        rows = []
        bytes = 0
        stopped_at = nil
        total = 0
        text.each_line(chomp: true).with_index(1) do |line, number|
          total = number
          next if stopped_at || number < offset || !regex.match?(line)

          row = format("%6d\t%s", number, line)
          if rows.size == limit || bytes + row.bytesize > Pikuri::Extractor::PAGE_MAX_BYTES
            stopped_at = number
            next
          end
          rows << row
          bytes += row.bytesize + 1
        end
        grep_result(rows, regex, total: total, offset: offset, stopped_at: stopped_at)
      rescue Regexp::TimeoutError
        Pikuri::Tool::Result.error("pattern /#{regex.source}/ took over #{PATTERN_TIMEOUT}s on this file; " \
                                   'simplify it.')
      end
      private_class_method :grep

      # @return [Pikuri::Tool::Result]
      def self.grep_result(rows, regex, total:, offset:, stopped_at:)
        where = offset > 1 ? " from line #{offset} on" : ''
        if rows.empty?
          return Pikuri::Tool::Result.new(
            content: "No lines match /#{regex.source}/#{where} (the indexed text has " \
                     "#{Pikuri::Tool.pluralize(total, 'line')}).",
            summary: 'Found 0 lines'
          )
        end

        footer = "Found #{Pikuri::Tool.pluralize(rows.size, 'matching line')}#{where} " \
                 "(the indexed text has #{Pikuri::Tool.pluralize(total, 'line')}). " \
                 'To read around one, call again without `pattern`, `offset` a few lines before it.'
        if stopped_at
          footer += " More lines match: call again with the same `pattern` and offset=#{stopped_at} for the rest."
        end
        Pikuri::Tool::Result.new(content: [rows.join("\n"), '', footer].join("\n"),
                                 summary: "Found #{Pikuri::Tool.pluralize(rows.size, 'line')}")
      end
      private_class_method :grep_result

      # @param text [String] a file's indexed text
      # @return [String] +text+ with each line longer than
      #   {Pikuri::Extractor::PAGE_MAX_LINE_LENGTH} broken at its last
      #   whitespace within the cap, or at the cap when it has none; +text+
      #   itself when no line is that long
      def self.wrap(text)
        max = Pikuri::Extractor::PAGE_MAX_LINE_LENGTH
        return text if text.each_line.none? { |line| line.chomp.length > max }

        text.each_line(chomp: true).flat_map do |line|
          pieces = []
          while line.length > max
            cut = line.rindex(/\s/, max)
            cut = max if cut.nil? || cut.zero?
            pieces << line[0, cut]
            line = line[cut..].lstrip
          end
          pieces << line
        end.join("\n")
      end
      private_class_method :wrap
    end
  end
end
