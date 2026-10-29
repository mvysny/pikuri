# frozen_string_literal: true

module Pikuri
  # The format→text extraction seam: one ordered registry of extractors
  # turning an +IO+ of a recognised format (HTML + plain text in core;
  # PDF / office formats via the pikuri-pdf / pikuri-extractors gems) into
  # Markdown-flavoured UTF-8, behind two front doors:
  #
  # * {.extract} — the whole document as one String (no windowing).
  # * {.extract_paged} — the same, windowed to a line range with a byte
  #   cap, as a {Page} the caller renders.
  #
  # +Tool::Scraper+ (dispatching on the HTTP +Content-Type+) and {FileType}
  # (resolving local paths) both route through this registry, so "support a
  # new format" is a registry entry, not a new dispatcher arm.
  #
  # == The extractor duck type
  #
  # Each {.registry} entry implements:
  #
  # * +matches?(sample:, content_type:)+ → +Boolean+ — claim the content.
  #   +sample+ is the leading {FileType::SAMPLE_BYTES} (magic-byte sniff);
  #   +content_type+ is the normalized HTTP/{FileType.detect_mime} type, or
  #   +nil+ ("no metadata — sniff if you can").
  # * +extract(io)+ → +String+ — whole document as Markdown-flavoured UTF-8.
  #   Raises {Error} on content it claimed but can't parse.
  # * +kind+ → +Symbol+ — a short tag (+:text+ / +:pdf+ / +:html+) carried
  #   on {Page#kind} so callers word format-specific trailers without
  #   re-sniffing.
  #
  # plus one *optional* method:
  #
  # * +extract_lines(io)+ → +Enumerator<String>+ — the same content as a
  #   lazy stream of +chomp+ed lines, numbered exactly as +extract+'s (see
  #   == Lines). {.extract_paged} prefers it and stops
  #   the moment the window fills, so the document's tail is never parsed
  #   (pikuri-pdf parses pages on access). Must be consumed while +io+ is
  #   open; may raise {Error} mid-iteration. Extractors needing the whole
  #   document ({HTML}, any subprocess-based one) omit it, and
  #   {.extract_paged} extracts in full then windows.
  #
  # Windowing (offset / limit / byte cap / truncation) is presentation and
  # lives once in {.extract_paged}, never per extractor — +extract_lines+ is
  # line *production*, the only format-specific half of paging.
  #
  # == Lines
  #
  # The one definition of "line N" for everything that pages, cites or
  # indexes extracted text — a reader's +offset:+, a search hit's line range,
  # a host program counting lines itself:
  #
  #   "a\r\nb\rc\n\nd\n"   # 4 lines: "a", "b\rc", "", "d"
  #
  # * 1-based; a range is inclusive at both ends.
  # * LF is the only terminator: CRLF numbers like LF, a lone CR is *not* a
  #   break, a final LF opens no extra line. Line N is the text after the
  #   (N-1)th +"\n"+.
  # * Lines of the *extracted* text. For {Passthrough} formats (plain text,
  #   Markdown, source) they are the file's own lines; for PDF / office /
  #   HTML they number the extractor's output, +"--- Page N ---"+ markers
  #   included — reproducible only by running the same extractor.
  #
  # Every reader paging through {.extract_paged} numbers lines this way, so
  # a search hit's +lines a-b+ from +rag_search+ / +rag_find+ /
  # +vectordb_search+ is a valid +offset:+ for +rag_read+, +vectordb_read+
  # and the workspace +read+ over the same file.
  #
  # A host counting a file's lines must split on LF alone. +grep -n+, +sed+,
  # +awk+ and Ruby's +each_line+ agree; Python's +str.splitlines()+ and
  # text-mode +open()+ and Java's +BufferedReader.readLine()+ /
  # +Files.readAllLines()+ also break on a lone CR (+splitlines+ on +\v+,
  # +\f+, U+2028 and more too), and every number after one is silently off.
  #
  # == Errors
  #
  # Both modes are failures the caller's LLM can react to, under one
  # rescuable root:
  #
  # * {Unsupported} — nothing in {.registry} claimed the content.
  # * {Error} (the root) — an extractor claimed it but the parse failed.
  module Extractor
    module_function

    # Raised when an extractor claims content but fails to parse it
    # (e.g. a malformed PDF). Message is LLM-presentable.
    Error = Class.new(StandardError)

    # Raised by {.extract} / {.extract_paged} when no registry entry
    # claims the content. Subclass of {Error} so callers that don't
    # care about the distinction rescue one class.
    Unsupported = Class.new(Error)

    # @return [Integer] default line-window size for {.extract_paged}
    #   when the caller omits +limit+.
    PAGE_DEFAULT_LIMIT = 2000

    # @return [Integer] default hard byte cap on the content collected
    #   by a single {.extract_paged} call. Bypassable by paging via
    #   +offset+. The rendered output is slightly larger (line
    #   numbering, trailer) — that's the caller's concern.
    PAGE_MAX_BYTES = 50 * 1024

    # @return [Integer] default per-line character cap;
    #   {.extract_paged} truncates longer lines and appends
    #   {PAGE_LINE_TRUNCATION_MARKER}.
    PAGE_MAX_LINE_LENGTH = 2000

    # @return [String] suffix appended to a line truncated at
    #   {PAGE_MAX_LINE_LENGTH}.
    PAGE_LINE_TRUNCATION_MARKER = "... (line truncated to #{PAGE_MAX_LINE_LENGTH} chars)"

    # One windowed slice of a document, returned by {.extract_paged},
    # carrying everything a trailer needs without re-reading the document.
    #
    # * +lines+ — +Array<String>+, the collected window; already per-line
    #   truncated (with {PAGE_LINE_TRUNCATION_MARKER}), *not* line-numbered
    #   (numbering is the caller's presentation). Includes any +"--- Page N
    #   ---"+ marker lines, which count toward +limit+/the byte cap.
    # * +start_line+ — line number of +lines.first+ (the requested +offset+),
    #   per {Extractor}'s == Lines.
    # * +total_lines+ — +Integer+ document line count when known, else +nil+.
    #   Known at EOF, when extracted in full (HTML), or on a cheap-to-count
    #   stream (text); +nil+ when a lazy stream stopped early (byte cap, or a
    #   PDF window filled before the last page — counting the rest would
    #   parse every page).
    # * +more+ — +true+ if content remains past this window.
    # * +byte_capped+ — +true+ if the byte cap (not the line limit) stopped it.
    # * +kind+ — the matched extractor's +kind+ tag.
    #
    # Empty document → +lines: []+, +total_lines: 0+; +offset+ past EOF →
    # +lines: []+ with +total_lines+ at the real count — the caller
    # distinguishes the two.
    Page = Data.define(:lines, :start_line, :total_lines, :more, :byte_capped, :kind)

    # The extractor registry, consulted in order — first match wins. Core
    # ships {HTML} (content-type) then the terminal {Passthrough} plain-text
    # arm. A gem picks its insertion point by claim strength: a magic-byte
    # sniff that never misfires on text goes at the *front* to beat {HTML}
    # under a lying header (+registry.unshift(X)+ — pikuri-pdf); a
    # content-type/weaker claimer inserts before the terminal entry
    # (+registry.insert(-2, X)+ — pikuri-extractors).
    #
    # @return [Array<#matches?>] mutable, deliberately — the plug-in seam.
    def registry
      @registry ||= [HTML, Passthrough]
    end

    # Extract the whole document behind +io+ as one Markdown-flavoured UTF-8
    # String. May be empty (empty text file, scanned-image PDF).
    #
    # @param io [IO, StringIO] seekable IO at the content start; reads a
    #   leading sample for the sniff and rewinds before extracting.
    # @param content_type [String, nil] normalized content-type when the
    #   transport supplies one; +nil+ when unknown (extractors sniff).
    # @return [String]
    # @raise [Unsupported] when no registry entry claims the content.
    # @raise [Error] when the matched extractor cannot parse it.
    def extract(io, content_type: nil)
      extractor_for(io, content_type).extract(io)
    end

    # Extract +io+ into a windowed {Page}: lines from +offset+ (1-indexed) up
    # to +limit+, stopping early at +max_bytes+, over-long lines truncated at
    # +max_line_length+.
    #
    # Lazy where the format allows: +extract_lines+ extractors (text,
    # pikuri-pdf) are consumed only until the window fills — a 500-page PDF's
    # first window parses a handful of pages. Extractors without it (HTML) are
    # extracted in full then windowed, which is why their +total_lines+ is
    # always exact.
    #
    # @param io [IO, StringIO] seekable IO at the start.
    # @param content_type [String, nil] as for {.extract}.
    # @param offset [Integer] 1-indexed first line; caller validates +>= 1+.
    # @param limit [Integer] max lines to collect; caller validates +>= 1+.
    # @param max_bytes [Integer] hard byte cap on collected content.
    # @param max_line_length [Integer] per-line truncation threshold.
    # @return [Page]
    # @raise [Unsupported] when no registry entry claims the content.
    # @raise [Error] when the matched extractor cannot parse it.
    def extract_paged(io, content_type: nil, offset: 1, limit: PAGE_DEFAULT_LIMIT,
                      max_bytes: PAGE_MAX_BYTES, max_line_length: PAGE_MAX_LINE_LENGTH)
      extractor = extractor_for(io, content_type)
      if extractor.respond_to?(:extract_lines)
        # count_tail is a per-format economics call: once the window fills,
        # counting the rest of a text stream is a cheap sequential read (so
        # the trailer says "of N"), but for a PDF it would parse every
        # remaining page — what extract_lines exists to avoid. Plugged-in
        # extractors get the conservative default (stop early, total unknown).
        window(extractor.extract_lines(io),
               offset: offset, limit: limit, max_bytes: max_bytes,
               max_line_length: max_line_length, kind: extractor.kind,
               known_total: nil, count_tail: extractor.equal?(Passthrough))
      else
        lines = extractor.extract(io).split("\n")
        window(lines, offset: offset, limit: limit, max_bytes: max_bytes,
                      max_line_length: max_line_length, kind: extractor.kind,
                      known_total: lines.length)
      end
    end

    # First registry entry claiming +io+'s content: read the leading
    # {FileType::SAMPLE_BYTES} for the sniff, rewind, ask each in order.
    #
    # @param io [IO, StringIO] seekable IO at the start.
    # @param content_type [String, nil]
    # @return [#extract] the matched extractor.
    # @raise [Unsupported] when nothing matches.
    def extractor_for(io, content_type)
      sample = io.read(FileType::SAMPLE_BYTES) || +''
      io.rewind
      registry.find { |ex| ex.matches?(sample: sample, content_type: content_type) } ||
        raise(Unsupported, 'no extractor for this content' \
                           "#{content_type && !content_type.empty? ? " (content-type #{content_type.inspect})" : ''}")
    end
    private_class_method :extractor_for

    # Collect a {Page} window from +lines+ (Array or lazy Enumerator of
    # +chomp+ed lines). +known_total+ is the full count when extracted up
    # front (Array), +nil+ for a lazy stream — then +total_lines+ is exact
    # only if iteration reached EOF: +count_tail+ keeps counting past the
    # limit when the tail is cheap, else the loop breaks and the total stays
    # unknown. The byte cap always aborts the count.
    #
    # @param lines [Enumerable<String>]
    # @param known_total [Integer, nil]
    # @param count_tail [Boolean]
    # @return [Page]
    def window(lines, offset:, limit:, max_bytes:, max_line_length:, kind:,
               known_total:, count_tail: false)
      start_index   = offset - 1
      collected     = []
      seen          = 0
      bytes         = 0
      byte_capped   = false
      more          = false
      stopped_early = false

      lines.each do |raw|
        seen += 1
        next if seen <= start_index

        if collected.length >= limit
          more = true
          next if count_tail # keep counting so total_lines stays exact

          stopped_early = true
          break
        end

        line = truncate_line(raw, max_line_length)
        size = line.bytesize + 1 # +1 for the joining newline
        if bytes + size > max_bytes
          byte_capped = true
          more = true
          stopped_early = true
          break
        end
        collected << line
        bytes += size
      end

      Page.new(lines: collected, start_line: offset,
               total_lines: known_total || (stopped_early ? nil : seen),
               more: more, byte_capped: byte_capped, kind: kind)
    end
    private_class_method :window

    # Truncate +line+ to +max_line_length+ chars, appending
    # {PAGE_LINE_TRUNCATION_MARKER} when it overflows.
    #
    # @param line [String]
    # @param max_line_length [Integer]
    # @return [String]
    def truncate_line(line, max_line_length)
      return line if line.length <= max_line_length

      line[0, max_line_length] + PAGE_LINE_TRUNCATION_MARKER
    end
    private_class_method :truncate_line
  end
end
