# frozen_string_literal: true

module Pikuri
  module Os
    # The +fileindex_search+ tool — a fast, cheap keyword lookup over
    # GNOME's desktop file index ({LocalSearch}). Returns the matching
    # file paths, each with the *single* snippet the index provides.
    # A {Pikuri::Tool} in the {Pikuri::Workspace::Grep} shape (shells out
    # through {LocalSearch}, fails loud at construction if the binary is
    # missing).
    #
    # == Honest, not a window
    #
    # The index reports at most one match per file, so this tool does not
    # pretend to show a file's full story: it locates files and previews
    # one match each, and tells the LLM to {FileindexRead read the file}
    # for the complete content / any other matches. It also sees inside
    # PDFs and office documents (indexed at extract time), unlike a
    # plain-text search, and covers the user's home / XDG content folders
    # — not system paths like +/etc+ (use a text/regex search there).
    # Because it's just an index lookup it's cheap to run repeatedly.
    class FileindexSearch < Pikuri::Tool
      # @return [Integer] default / max matching files returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25

      # @return [Integer] hard byte cap on combined output (matches
      #   {Pikuri::Workspace::Grep::MAX_BYTES}).
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [String] opencode-shape description (summary + Usage).
      DESCRIPTION = <<~DESC
        Find files whose contents contain your words or phrase, using the desktop search index.

        Usage:
        - Searches inside PDFs, Word/ODT/spreadsheet documents and plain text — reach for this when the answer may live in a file's contents.
        - Covers your home and standard user folders (Documents, Downloads, …), NOT system paths like /etc or /var — search those with a text/regex tool instead.
        - Keyword match (and word stems); type the actual words that would appear in the file.
        - The index returns at most ONE match per file and may be slightly stale — this is a locator, not the full story. To read a file's full, current text, read it (see fileindex_read).
        - Cheap and fast: fine to run many times to narrow down.
        - Output is truncated to #{MAX_BYTES_LABEL}; narrow the query if it ends in a truncation marker.
      DESC

      # @raise [RuntimeError] if +localsearch+ isn't on +PATH+.
      # @return [FileindexSearch]
      def initialize
        LocalSearch.check_binaries!
        super(
          name: 'fileindex_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'Words or a phrase to find in file contents, ' \
                              'e.g. "tax return 2024".'
            p.optional_integer :limit,
                               "Max number of matching files to return " \
                               "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT|
            FileindexSearch.search(query: query, limit: limit)
          }
        )
      end

      # @param query [String]
      # @param limit [Integer]
      # @return [String] formatted hits + disclaimer, a no-match message,
      #   or +"Error: ..."+
      def self.search(query:, limit: DEFAULT_LIMIT)
        q = query.to_s.strip
        return 'Error: empty query.' if q.empty?

        limit = clamp(limit, 1, MAX_LIMIT)
        hits = LocalSearch.search(query: q, limit: limit)
        return no_match_message(q) if hits.empty?

        content, marker = head_truncate(hits.map { |hit| render_hit(hit) }.join("\n"))
        [content.chomp, '', disclaimer(hits.size) + marker].join("\n")
      rescue LocalSearch::CommandError => e
        "Error: localsearch: #{e.message}"
      end

      # @return [String] +"<path>"+ or +"<path>\n  <snippet>"+
      def self.render_hit(hit)
        hit[:snippet] && !hit[:snippet].empty? ? "#{hit[:path]}\n  #{hit[:snippet]}" : hit[:path]
      end
      private_class_method :render_hit

      # @return [String]
      def self.disclaimer(count)
        "Found #{count} #{count == 1 ? 'file' : 'files'} (one match shown per file; " \
          'the index may be slightly stale). Read a file to see its full text and any other matches.'
      end
      private_class_method :disclaimer

      # @return [String]
      def self.no_match_message(query)
        "No files found matching '#{query}'. (Searches your indexed home / user " \
          'folders, not system paths; the index may also be disabled or still building.)'
      end
      private_class_method :no_match_message

      # Head-truncate to {MAX_BYTES} at the last newline boundary.
      #
      # @return [Array(String, String)] +[content, marker]+ (marker empty
      #   when no truncation)
      def self.head_truncate(raw)
        total = raw.bytesize
        return [raw, ''] if total <= MAX_BYTES

        head = raw.byteslice(0, MAX_BYTES)
        last_nl = head.rindex("\n")
        head = head.byteslice(0, last_nl) if last_nl
        omitted = total - head.bytesize
        [head, "\n\n... [#{omitted} bytes omitted; total was #{total} bytes; narrow the query] ..."]
      end
      private_class_method :head_truncate

      # @return [Integer] +value+ clamped to +[lo, hi]+ (lo on bad input)
      def self.clamp(value, lo, hi)
        Integer(value).clamp(lo, hi)
      rescue ArgumentError, TypeError
        lo
      end
      private_class_method :clamp
    end
  end
end
