# frozen_string_literal: true

require 'json'

module Pikuri
  module Os
    # The +search_files+ tool — keyword content search over the
    # user's files (including PDFs and office documents) via GNOME's
    # desktop index, returning a window of context around each match.
    # A +Pikuri::Tool+ in the same shape as {Pikuri::Workspace::Grep}:
    # shells out through {Pikuri::Subprocess}, fails loud at construction
    # if the binary is missing, splits failures into +"Error: ..."+
    # observations vs. raised bugs.
    #
    # == Why this exists (and how it differs from grep)
    #
    # +grep+ does regex over plain-text files the agent can already read.
    # This tool reaches the two things grep can't: it is fast over a large
    # home directory (the index is prebuilt) and it sees *inside* PDFs and
    # office documents (LocalSearch extracted their text at index time).
    # It is the content half of a "spotlight" for the OS helper. See
    # +ideas/os-assistant.md+ §"File search".
    #
    # == Mechanism: a two-call split, collapsed into one tool
    #
    # +localsearch search -d+ is *discovery* — it returns matching file
    # paths plus a tiny (3-4 word) snippet, too small to reason on but
    # with the *matched word* ANSI-highlighted. So for each hit this tool
    # makes a second call, +localsearch info -c -o json-ld <path>+, which
    # returns the file's full extracted text (+nie:plainTextContent+,
    # already extracted at index time — PDFs and office docs included, no
    # re-parsing), then slices a ~+window_words+ window centred on the
    # match. That mirrors the +vectordb_search+ → +vectordb_read+ shape,
    # free from the pre-installed index. The window is deliberately modest
    # (~100 words): enough to judge relevance and often answer, cheap
    # enough to return several hits — read the file in full if a window
    # isn't enough.
    #
    # == Scope and freshness (surfaced in the description)
    #
    # LocalSearch indexes the user's home + XDG content dirs, NOT system
    # paths (+/etc+, +/var+) — those want a text search instead. Matching
    # is keyword + stemmed, not semantic. The index can lag very recent
    # writes, and some users disable it; a healthy, populated index is
    # assumed (+localsearch status+ reports its state).
    #
    # == Locating the match (window around the matched *word*, stemmed)
    #
    # LocalSearch's full-text search is stemmed: querying +"mouse"+ can
    # match the document word +"mice"+, +"environment"+ matches
    # +"environmental"+. So the *query* often isn't in the stored text
    # verbatim — windowing around the query directly would miss. Instead
    # we window around the word the index actually matched: +search -d+
    # ANSI-highlights that surface form in its snippet
    # (+\\e[..m<word>\\e[0m+), {.parse_search_hits} extracts it per file,
    # and {.window_around} centres on the first occurrence of *that* word
    # in the full text. This handles every stem divergence, not just
    # suffixes.
    #
    # Layered fallback, so a hit is never dropped: matched surface form →
    # (if no highlight was parseable) the query terms as substrings →
    # (if neither is found in the text) the document head.
    class LocalSearch < Pikuri::Tool
      # @return [String] the indexer/search CLI (GNOME LocalSearch, the
      #   2024 rename of tracker3 / tracker-miners).
      BINARY = 'localsearch'

      # @return [Integer] default / max number of matching files returned.
      DEFAULT_LIMIT = 10
      MAX_LIMIT     = 25

      # @return [Integer] default / min / max words of context per match.
      DEFAULT_WINDOW = 100
      MIN_WINDOW     = 20
      MAX_WINDOW     = 400

      # @return [Integer] hard byte cap on combined output (matches
      #   {Pikuri::Workspace::Grep::MAX_BYTES}).
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES}.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # Description shown to the LLM. opencode-shape (summary + +Usage:+
      # bullets); per-argument constraints live in the parameter
      # descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Search the contents of your files — including PDFs and office documents — for words or a phrase, using the desktop search index.

        Usage:
        - Finds files whose text contains your query and returns a window of context around each match, so you can judge relevance or answer without opening the whole file.
        - Sees inside PDFs, Word/ODT/spreadsheet documents, and plain text — reach for this instead of a plain-text search when the answer may live in a document.
        - Covers your home and standard user folders (Documents, Downloads, …), NOT system paths like /etc or /var — search those with a text/regex tool instead.
        - Keyword match (and word stems), not meaning-based: type the actual words that would appear in the file.
        - If a returned window isn't enough, open the file at the reported path to read it in full.
        - Relies on the system index being present and populated; if results seem empty or stale, the index may be disabled or still building.
        - Output is truncated to #{MAX_BYTES_LABEL}; narrow the query if it ends in a truncation marker.
      DESC

      # @raise [RuntimeError] if +localsearch+ isn't on +PATH+; fail-loud
      #   at construction rather than the first tool call.
      # @return [LocalSearch]
      def initialize
        LocalSearch.send(:check_binaries!)
        super(
          name: 'search_files',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'Words or a phrase to find in your files\' ' \
                              'contents, e.g. "tax return 2024".'
            p.optional_integer :limit,
                               "Max number of matching files to return " \
                               "(default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}), e.g. 10."
            p.optional_integer :window_words,
                               "Approx words of context around each match " \
                               "(default #{DEFAULT_WINDOW}, capped at #{MAX_WINDOW}), e.g. 100."
          },
          execute: lambda { |query:, limit: DEFAULT_LIMIT, window_words: DEFAULT_WINDOW|
            LocalSearch.search_files(query: query, limit: limit, window_words: window_words)
          }
        )
      end

      # Validate inputs, run +localsearch search+, pull + window each hit,
      # and render the observation.
      #
      # @param query [String]
      # @param limit [Integer]
      # @param window_words [Integer]
      # @return [String] formatted windows, a "no documents" message, or
      #   +"Error: ..."+.
      def self.search_files(query:, limit: DEFAULT_LIMIT, window_words: DEFAULT_WINDOW)
        q = query.to_s.strip
        return 'Error: empty query.' if q.empty?

        limit = clamp(limit, 1, MAX_LIMIT)
        window_words = clamp(window_words, MIN_WINDOW, MAX_WINDOW)

        # -d adds the URN (ignored) and, crucially, the ANSI-highlighted
        # matched word in the snippet — see {.parse_search_hits}.
        result = Pikuri::Subprocess.spawn(BINARY, 'search', '-d', '--limit', limit.to_s, q,
                                          chdir: '/').wait
        unless result.status.success?
          stderr = result.output.strip
          stderr = "exited #{result.status.exitstatus}" if stderr.empty?
          return "Error: localsearch: #{stderr}"
        end

        hits = parse_search_hits(result.output)
        return no_match_message(q) if hits.empty?

        blocks = hits.filter_map { |hit| build_block(hit: hit, query: q, window_words: window_words) }
        return no_match_message(q) if blocks.empty?

        format_output(blocks, query: q)
      end

      # Parse +localsearch search -d+ output into hits. Each result is a
      # +file://<uri> (urn:...)+ line followed by an indented snippet line
      # in which the *matched* word is ANSI-highlighted; a hit pairs the
      # decoded path with the highlighted surface form(s) from its snippet
      # (the actual document words the index matched — possibly stems of
      # the query). De-duplicated by path.
      #
      # @param raw [String]
      # @return [Array<Hash>] +[{ path: String, terms: Array<String> }, ...]+
      def self.parse_search_hits(raw)
        hits = []
        current = nil
        raw.each_line do |line|
          encoded = line[%r{\Afile://(\S+)}, 1]
          if encoded
            current = { path: decode_file_uri(encoded), terms: [] }
            hits << current
          elsif current
            current[:terms].concat(highlighted_terms(line))
          end
        end
        hits.uniq { |hit| hit[:path] }
      end

      # @return [Regexp] one ANSI-highlighted run: +\e[..m<text>\e[0m+.
      ANSI_HIGHLIGHT = /\e\[[0-9;]*m([^\e]+?)\e\[0m/

      # Pull the ANSI-highlighted (matched) words out of a snippet line.
      #
      # @param line [String]
      # @return [Array<String>] highlighted surface forms, trimmed
      def self.highlighted_terms(line)
        line.scan(ANSI_HIGHLIGHT).flatten.map(&:strip).reject(&:empty?)
      end
      private_class_method :highlighted_terms

      # Percent-decode a +file://+ URI tail to a filesystem path. Decodes
      # +%XX+ only (NOT +++ → space — that's form-encoding, wrong for file
      # paths) and tags the bytes UTF-8.
      #
      # @param encoded [String]
      # @return [String]
      def self.decode_file_uri(encoded)
        encoded.gsub(/%([0-9A-Fa-f]{2})/) { ::Regexp.last_match(1).hex.chr }
               .force_encoding('UTF-8')
      end
      private_class_method :decode_file_uri

      # One result block: +"<path>\n<window>"+, or +nil+ to skip (path is
      # not a regular file, has no stored text, or vanished since
      # indexing). Windows around the index's matched word(s)
      # (+hit[:terms]+); falls back to the query terms when the snippet
      # had no parseable highlight.
      #
      # @param hit [Hash] +{ path:, terms: }+ from {.parse_search_hits}
      # @param query [String]
      # @param window_words [Integer]
      # @return [String, nil]
      def self.build_block(hit:, query:, window_words:)
        path = hit[:path]
        return nil unless File.file?(path)

        content = plain_text_for(path)
        return nil if content.nil? || content.strip.empty?

        terms = hit[:terms].map(&:downcase)
        terms = query.downcase.split if terms.empty?

        window = window_around(content, terms, window_words)
        return nil if window.empty?

        "#{path}\n#{window}"
      end
      private_class_method :build_block

      # Pull a file's stored plain text via +localsearch info -c -o
      # json-ld+. Returns +nil+ on any failure (the file is simply
      # skipped) — a single unreadable hit must not abort the search.
      #
      # @param path [String]
      # @return [String, nil]
      def self.plain_text_for(path)
        result = Pikuri::Subprocess.spawn(BINARY, 'info', '-c', '-o', 'json-ld', path,
                                          chdir: '/').wait
        return nil unless result.status.success?

        extract_plain_text(result.output)
      end
      private_class_method :plain_text_for

      # Find +nie:plainTextContent+ anywhere in the json-ld document. The
      # property nests under +@graph+ (a named graph), so we walk rather
      # than index a fixed path. Lenient: if the raw bytes don't parse as
      # JSON (e.g. a stray diagnostic prefix), retry from the first +{+.
      #
      # @param raw [String] json-ld text from +localsearch info -c+
      # @return [String, nil]
      def self.extract_plain_text(raw)
        data = parse_json_lenient(raw)
        data && find_plain_text(data)
      end

      # @return [Object, nil]
      def self.parse_json_lenient(raw)
        JSON.parse(raw)
      rescue JSON::ParserError
        brace = raw.index('{')
        return nil unless brace

        begin
          JSON.parse(raw[brace..])
        rescue JSON::ParserError
          nil
        end
      end
      private_class_method :parse_json_lenient

      # @param node [Object]
      # @return [String, nil] first String value under a
      #   +nie:plainTextContent+ key, depth-first
      def self.find_plain_text(node)
        case node
        when Hash
          node.each do |key, value|
            return value if key == 'nie:plainTextContent' && value.is_a?(String)

            found = find_plain_text(value)
            return found if found
          end
          nil
        when Array
          node.each do |element|
            found = find_plain_text(element)
            return found if found
          end
          nil
        end
      end
      private_class_method :find_plain_text

      # Slice a ~+window_words+ window of +text+ centred on the first word
      # containing any of +terms+ (the index's matched surface forms, or
      # the query terms as a fallback). Falls back to the document head
      # when none is found. Adds leading/trailing ellipses when the window
      # is interior.
      #
      # @param text [String]
      # @param terms [Array<String>] lowercased words to locate
      # @param window_words [Integer]
      # @return [String]
      def self.window_around(text, terms, window_words)
        words = text.split
        return '' if words.empty?

        half = [window_words / 2, 1].max
        idx = match_index(words, terms)
        if idx.nil?
          selected = words.first(window_words)
          lead = false
          trail = words.length > selected.length
        else
          lo = [idx - half, 0].max
          hi = [idx + half, words.length - 1].min
          selected = words[lo..hi]
          lead  = lo.positive?
          trail = hi < words.length - 1
        end

        out = selected.join(' ')
        out = "… #{out}" if lead
        out = "#{out} …" if trail
        out
      end

      # @param words [Array<String>] document words
      # @param terms [Array<String>] target words (matched surface forms
      #   or query terms)
      # @return [Integer, nil] index of the first word containing any
      #   term (case-insensitive), or +nil+
      def self.match_index(words, terms)
        cleaned = terms.map(&:downcase).reject(&:empty?)
        return nil if cleaned.empty?

        words.find_index do |word|
          downcased = word.downcase
          cleaned.any? { |term| downcased.include?(term) }
        end
      end
      private_class_method :match_index

      # Join blocks, head-truncate to {MAX_BYTES}, append a one-line
      # footer. Head bias matches {Pikuri::Workspace::Grep}.
      #
      # @return [String]
      def self.format_output(blocks, query:)
        content, marker = head_truncate(blocks.join("\n\n"))
        footer = "Found #{pluralize(blocks.size, 'file', 'files')} matching '#{query}'."
        [content.chomp, '', footer + marker].join("\n")
      end
      private_class_method :format_output

      # Head-truncate to {MAX_BYTES} at the last newline boundary. Returns
      # +[content, marker]+ (marker empty when no truncation).
      #
      # @return [Array(String, String)]
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

      # @return [String]
      def self.no_match_message(query)
        "No files found matching '#{query}'. (Searches your indexed home / " \
          'user folders, not system paths; the index may also be disabled or still building.)'
      end
      private_class_method :no_match_message

      # @return [Integer] +value+ clamped to +[lo, hi]+
      def self.clamp(value, lo, hi)
        Integer(value).clamp(lo, hi)
      rescue ArgumentError, TypeError
        lo
      end
      private_class_method :clamp

      # @return [String] +"1 document"+ / +"2 documents"+
      def self.pluralize(count, singular, plural)
        "#{count} #{count == 1 ? singular : plural}"
      end
      private_class_method :pluralize

      # Verify +localsearch+ is reachable. Routed through
      # {Pikuri::Subprocess.spawn} per the subprocess seam.
      #
      # @raise [RuntimeError] if the binary is missing
      def self.check_binaries!
        result = Pikuri::Subprocess.spawn(BINARY, '--version', chdir: '/').wait
        return if result.status.success?

        raise install_hint
      rescue Errno::ENOENT
        raise install_hint
      end
      private_class_method :check_binaries!

      # @return [String]
      def self.install_hint
        "search_files requires '#{BINARY}' on PATH — GNOME's desktop file " \
          "indexer (package 'localsearch', formerly 'tracker-miners'), which ships " \
          'with the GNOME desktop on Ubuntu 26.04+. Install it, or wire this tool ' \
          'only on hosts that have it.'
      end
      private_class_method :install_hint
    end
  end
end
