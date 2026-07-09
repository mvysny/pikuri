# frozen_string_literal: true

module Pikuri
  module Os
    # The +fileindex_search+ tool — a fast, cheap keyword lookup over a
    # desktop file index. Returns the matching file paths, each with the
    # *single* snippet the index provides. A {Pikuri::Tool} in the
    # {Pikuri::Workspace::Grep} shape (shells out through the backend, fails
    # loud at construction if the binary is missing).
    #
    # == Swappable backend
    #
    # The +backend:+ is a stateless module satisfying the file-index duck
    # type — {LocalSearch} (GNOME) or {Recoll} (DE-independent); {Extension}
    # picks whichever is usable. The tool needs only +#search+,
    # +#read_text+ (its companion), +#check_binaries!+, +#limitations+,
    # +#label+, and a +CommandError+ constant. Backend-specific text — the
    # blind-spot note and the error label — is read from the backend, so a
    # new index arm ships its own without touching the tool.
    #
    # == Honest, not a window
    #
    # The index reports at most one match per file, so this tool does not
    # pretend to show a file's full story: it locates files and previews
    # one match each, and tells the LLM to {FileindexRead read the file}
    # for the complete content / any other matches. It also sees inside
    # PDFs and office documents (indexed at extract time), unlike a
    # plain-text search. Because it's just an index lookup it's cheap to
    # run repeatedly.
    class FileindexSearch < Pikuri::Tool
      # @return [Integer] default / max matching files returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25

      # @return [Integer] hard byte cap on combined output (matches
      #   {Pikuri::Workspace::Grep::MAX_BYTES}).
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [String] opencode-shape description (summary + Usage),
      #   backend-neutral; the backend's blind-spot note is appended at
      #   construction (see {#initialize}).
      DESCRIPTION = <<~DESC
        Find files whose contents contain your words or phrase, using the desktop search index.

        Usage:
        - Searches inside PDFs, Word/ODT/spreadsheet documents and plain text — reach for this when the answer may live in a file's contents.
        - Keyword match (and word stems); type the actual words that would appear in the file.
        - The index returns at most ONE match per file and may be slightly stale — this is a locator, not the full story. To read a file's full, current text, read it (see fileindex_read).
        - Cheap and fast: fine to run many times to narrow down.
        - Only indexed folders are covered; system paths like /etc or /var are not — search those with a text/regex tool instead.
        - Output is truncated to #{MAX_BYTES_LABEL}; narrow the query if it ends in a truncation marker.
      DESC

      # @param backend [Module] a file-index backend ({LocalSearch} /
      #   {Recoll}) — must respond to +#search+, +#read_text+,
      #   +#check_binaries!+, +#limitations+, +#label+ and define a
      #   +CommandError+.
      # @raise [RuntimeError] if the backend's binary isn't on +PATH+.
      # @return [FileindexSearch]
      def initialize(backend:)
        @backend = backend
        backend.check_binaries!
        super(
          name: 'fileindex_search',
          description: "#{DESCRIPTION}\n#{backend.limitations}",
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'Words or a phrase to find in file contents, ' \
                              'e.g. "tax return 2024".'
            p.optional_integer :limit,
                               "Max number of matching files to return " \
                               "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT|
            FileindexSearch.search(query: query, limit: limit, backend: backend)
          }
        )
      end

      # @param query [String]
      # @param limit [Integer]
      # @param backend [Module] the file-index backend to query
      # @return [String] formatted hits + disclaimer, a no-match message,
      #   or +"Error: ..."+
      def self.search(query:, backend:, limit: DEFAULT_LIMIT)
        q = query.to_s.strip
        return 'Error: empty query.' if q.empty?

        limit = clamp(limit, 1, MAX_LIMIT)
        hits = backend.search(query: q, limit: limit)
        return no_match_message(q) if hits.empty?

        content, marker = head_truncate(hits.map { |hit| render_hit(hit) }.join("\n"))
        [content.chomp, '', disclaimer(hits.size) + marker].join("\n")
      rescue backend::CommandError => e
        # Cap the error too: the backend's stderr is normally short (it's a
        # daemon/index query, not a filesystem walk), but a raw subprocess
        # error returned verbatim is the shape that overflows the model's
        # context — share the success path's ceiling. See
        # {Pikuri::Workspace::Grep}.
        content, marker = head_truncate(e.message)
        "Error: #{backend.label}: #{content}#{marker}"
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
        "No files found matching '#{query}'. (Searches your indexed folders, " \
          'not system paths; the index may also be disabled or still building.)'
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
