# frozen_string_literal: true

module Pikuri
  # The format→text extraction seam: one registry of extractors that
  # turn an +IO+ of some recognised format (HTML and plain text out
  # of the box; PDF / office formats via the pikuri-pdf /
  # pikuri-extractors plug-in gems) into Markdown-flavoured UTF-8
  # text, consumed through two front doors:
  #
  # * {.extract} — the whole document as one String. The shape the
  #   indexing / caching callers want ({Pikuri::VectorDb}'s indexer,
  #   {Tool::WebScrape}'s URL cache): no windowing, no presentation.
  # * {.extract_paged} — the LLM-tool shape: the same extraction,
  #   windowed to a line range with a byte cap, returned as a {Page}
  #   the caller renders. Backs +Workspace::Read+ and
  #   +VectorDb::Tools::Read+ (via the {FileType} path wrappers) so
  #   the offset/limit/byte-cap logic lives in one tested place.
  #
  # Both front doors — +Tool::Scraper+ dispatching on the HTTP
  # +Content-Type+ header for the web tools, and {FileType} resolving
  # local paths — route through this one registry, so both share one
  # set of format truths and "support a new format" is a registry
  # entry (pikuri-pdf and pikuri-extractors plug PDF and office
  # formats in without pikuri-core knowing), not a new special case
  # in two dispatchers.
  #
  # == The extractor duck type
  #
  # Each {.registry} entry implements three methods:
  #
  # * +matches?(sample:, content_type:)+ → +Boolean+ — claim the
  #   content. +sample+ is the leading {FileType::SAMPLE_BYTES} bytes
  #   (for magic-byte sniffs); +content_type+ is the normalized HTTP
  #   +Content-Type+ for web content, the {FileType.detect_mime}
  #   result for local files, and may be +nil+ ("no transport
  #   metadata — sniff if you can").
  # * +extract(io)+ → +String+ — the whole document as
  #   Markdown-flavoured UTF-8 text. Raises {Error} on content the
  #   extractor claimed but cannot parse (malformed PDF, ...).
  # * +kind+ → +Symbol+ — a short tag (+:text+ / +:pdf+ / +:html+)
  #   carried on {Page#kind} so rendering callers can word
  #   format-specific trailers ("End of PDF", the scanned-image
  #   hint) without re-sniffing.
  #
  # plus one *optional* method for formats whose lines can be
  # produced incrementally:
  #
  # * +extract_lines(io)+ → +Enumerator<String>+ — the same content
  #   as +extract+, as a lazy stream of already-+chomp+ed lines.
  #   {.extract_paged} prefers this when present and stops consuming
  #   the moment the window fills, so the rest of the document is
  #   never parsed (pikuri-pdf's extractor: pdf-reader's page list
  #   parses on access; {Passthrough}: the IO is read line-by-line).
  #   The enumerator
  #   must be consumed while +io+ is still open, and may raise
  #   {Error} mid-iteration. Extractors that need the whole document
  #   to produce anything ({HTML}: Readability walks the full DOM —
  #   true of any subprocess-based extractor too) simply omit it;
  #   {.extract_paged} then extracts in full and windows the result.
  #
  # Windowing itself (offset / limit / byte cap / line truncation) is
  # presentation and deliberately lives once in {.extract_paged}, not
  # per extractor — +extract_lines+ is line *production*, the only
  # genuinely format-specific half of paging.
  #
  # == Errors
  #
  # Both failure modes are failures the *caller's* LLM can react to,
  # so they share one rescuable root:
  #
  # * {Unsupported} — nothing in {.registry} claimed the content
  #   (opaque binary, an unhandled content-type).
  # * {Error} (the root) — an extractor claimed the content but the
  #   parse failed (malformed PDF, ...).
  #
  # Callers map them to their own conventions:
  # +Tool::Scraper+ re-raises both as +FetchError+;
  # {FileType.read_as_text} maps {Unsupported} to the +ArgumentError+
  # binary refusal and {Error} to a +RuntimeError+ carrying the path.
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

    # One windowed slice of a document, returned by {.extract_paged}.
    # The caller turns this into an observation; this struct carries
    # everything a trailer needs without the caller re-reading the
    # document.
    #
    # == Fields
    #
    # * +lines+ — +Array<String>+, the collected window. Already
    #   per-line truncated (with {PAGE_LINE_TRUNCATION_MARKER}); *not*
    #   line-numbered — numbering is presentation the caller adds. For
    #   a PDF the array includes the +"--- Page N ---"+ marker lines
    #   pikuri-pdf's extractor emits, which count toward +limit+ / the
    #   byte cap like any other line.
    # * +start_line+ — the 1-indexed line number of +lines.first+
    #   (i.e. the +offset+ the caller asked for). +lines.last+ is at
    #   +start_line + lines.length - 1+.
    # * +total_lines+ — total line count of the document when known,
    #   else +nil+. Known when the read reached EOF, when the format
    #   was extracted in full (no +extract_lines+ — e.g. HTML), or
    #   when the lazy stream is cheap enough to count to the end
    #   (plain text). +nil+ when a lazy stream stopped early — the
    #   byte cap fired, or a PDF filled the window before its last
    #   page (counting the rest would mean parsing every page,
    #   defeating the laziness).
    # * +more+ — +true+ if content remains past this window (the
    #   caller should offer +offset = start_line + lines.length+).
    # * +byte_capped+ — +true+ if the byte cap (not the line limit)
    #   was the stopping criterion.
    # * +kind+ — the matched extractor's +kind+ tag (+:text+ /
    #   +:pdf+ / +:html+); lets the caller word format-specific
    #   trailers and the empty-document message.
    #
    # An empty document yields +lines: []+, +total_lines: 0+; an
    # +offset+ past EOF yields +lines: []+ with +total_lines+ set to
    # the real (non-zero) count — the caller distinguishes the two.
    Page = Data.define(:lines, :start_line, :total_lines, :more, :byte_capped, :kind)

    # The extractor registry, consulted in order — first match wins.
    # Core ships two entries: {HTML} matches on content-type, and
    # {Passthrough} is the terminal plain-text arm. A gem adding a
    # format picks its insertion point by the strength of its claim:
    # a magic-byte sniff that never misfires on text goes at the
    # *front* so it beats {HTML}'s content-type match even under a
    # lying header (+registry.unshift(X)+ — pikuri-pdf does this);
    # a content-type / weaker-sniff claimer inserts before the
    # terminal entry (+registry.insert(-2, X)+ — pikuri-extractors
    # does this).
    #
    # @return [Array<#matches?>] mutable, deliberately — this is the
    #   plug-in seam.
    def registry
      @registry ||= [HTML, Passthrough]
    end

    # Extract the whole document behind +io+ as one Markdown-flavoured
    # UTF-8 String. May be empty (empty text file, scanned-image PDF
    # with no extractable text).
    #
    # @param io [IO, StringIO] seekable IO positioned at the start of
    #   the content; this method reads a leading sample for the
    #   +matches?+ sniff and rewinds before extracting.
    # @param content_type [String, nil] normalized content-type when
    #   the transport supplies one (HTTP header, {FileType.detect_mime}
    #   result); +nil+ when unknown — extractors then rely on their
    #   byte sniffs.
    # @return [String]
    # @raise [Unsupported] when no registry entry claims the content.
    # @raise [Error] when the matched extractor cannot parse it.
    def extract(io, content_type: nil)
      extractor_for(io, content_type).extract(io)
    end

    # Extract +io+ and return a windowed {Page}: the lines from
    # +offset+ (1-indexed) up to +limit+ of them, stopping early if
    # +max_bytes+ is reached, with over-long lines truncated at
    # +max_line_length+.
    #
    # Lazy where the format allows: extractors that implement
    # +extract_lines+ (plain text; pikuri-pdf's PDF) are consumed
    # only until the window fills — reading the first window of a
    # 500-page PDF parses a handful of pages, and the first page of
    # a gigabyte log never loads it. Extractors without it (HTML) are extracted
    # in full and then windowed, which is also what makes their
    # +total_lines+ always exact.
    #
    # @param io [IO, StringIO] seekable IO positioned at the start.
    # @param content_type [String, nil] as for {.extract}.
    # @param offset [Integer] 1-indexed first line to include. The
    #   caller is responsible for validating +offset >= 1+.
    # @param limit [Integer] maximum lines to collect. Caller
    #   validates +limit >= 1+.
    # @param max_bytes [Integer] hard byte cap on collected content.
    # @param max_line_length [Integer] per-line truncation threshold.
    # @return [Page] the windowed slice.
    # @raise [Unsupported] when no registry entry claims the content.
    # @raise [Error] when the matched extractor cannot parse it.
    def extract_paged(io, content_type: nil, offset: 1, limit: PAGE_DEFAULT_LIMIT,
                      max_bytes: PAGE_MAX_BYTES, max_line_length: PAGE_MAX_LINE_LENGTH)
      extractor = extractor_for(io, content_type)
      if extractor.respond_to?(:extract_lines)
        # count_tail is a per-format economics call: once the window
        # fills, counting the rest of a plain-text stream is a cheap
        # sequential read (so the trailer can say "of N"), while for
        # a PDF it would mean parsing every remaining page — exactly
        # what extract_lines exists to avoid. Plugged-in extractors
        # (pikuri-pdf's included) get the conservative default (stop
        # early, total unknown).
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

    # Find the first registry entry claiming +io+'s content: read the
    # leading {FileType::SAMPLE_BYTES} for the sniff, rewind, and ask
    # each extractor in order.
    #
    # @param io [IO, StringIO] seekable IO positioned at the start.
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

    # Collect a {Page} window out of +lines+ (an Array or a lazy
    # Enumerator of already-+chomp+ed lines). +known_total+ is the
    # full line count when the caller extracted everything up front
    # (Array case), +nil+ for a lazy stream — then +total_lines+ is
    # exact only if the iteration reached EOF: +count_tail+ keeps
    # the loop counting (without collecting) past the line limit
    # when consuming the rest of the stream is cheap; without it the
    # loop breaks and leaves the total unknown. The byte cap always
    # aborts the count.
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
