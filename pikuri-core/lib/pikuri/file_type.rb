# frozen_string_literal: true

require 'pdf-reader'

module Pikuri
  # Magic-byte content sniffing + text extraction, centralised. Three
  # responsibilities:
  #
  # * {.detect_mime} — recognise a file from its leading bytes. Returns
  #   a MIME String for formats pikuri knows how to handle specially
  #   ({+application/pdf+}, the four image formats), or +nil+ for
  #   "unrecognised — could be text, could be opaque binary; caller
  #   decides".
  # * {.binary?} — heuristic text-vs-binary classifier. Independent of
  #   {.detect_mime}: a file can be both recognised (e.g. PDF) *and*
  #   binary. {.detect_mime} tells you what the bytes are;
  #   {.binary?} tells you whether they're safe to render as text.
  # * {.read_as_text} — read a file and return its content as plain
  #   UTF-8 text. PDFs go through +pdf-reader+ page-by-page; plain
  #   text passes through; images / binaries / missing files raise.
  #   The pure-extraction shape consumers like +Pikuri::VectorDb+'s
  #   indexer want (no LLM-tool concerns — no paging, no line
  #   numbering, no byte caps; just bytes-in-text-out).
  # * {.read_as_text_paged} — the LLM-tool shape: the same
  #   extraction as {.read_as_text}, but lazily windowed to a
  #   line range with a byte cap, returning a {Page} value the
  #   caller renders. Shared by +Workspace::Read+ and
  #   +VectorDb::Tools::Read+ so the offset/limit/byte-cap windowing lives
  #   in one tested place; each tool keeps its own presentation
  #   (cat-n numbering, trailer wording, citation vs. path). Same
  #   refusal contract as {.read_as_text} (raises on image / binary
  #   / missing / malformed-PDF).
  #
  # {.detect_mime} and {.binary?} accept either a +String+ of bytes
  # (sample taken by the caller) or a +Pathname+ — when given a path,
  # the module opens the file in binary mode and reads {SAMPLE_BYTES}
  # for the sniff itself. The Pathname form is the convenience path;
  # the bytes form is for callers that already have the sample or are
  # calling both methods on the same file and want to avoid a second
  # open. {.read_as_text} takes a +Pathname+ only — there's no
  # bytes-in shortcut because the PDF case needs to seek the file.
  #
  # == Why a separate module
  #
  # Without this module, magic-byte tables and the binary heuristic
  # ended up scattered through whichever tool needed them — first PDF
  # in {Workspace::Read}, then images alongside it, then a copy of
  # {.binary?} reached for by {Workspace::Edit}. Collecting the
  # detection logic here lets {Read} focus on routing
  # (mime-to-formatter), {Edit} drop its cross-tool reach, and new
  # tools (a future +Workspace::Diff+, an attachment-aware web fetcher,
  # ...) share one set of magic-byte truths.
  #
  # == Deliberate non-goals
  #
  # * *Not a full MIME database.* The set grows when a pikuri tool
  #   needs a new format, not speculatively. Keeps the "audit in an
  #   evening" ceiling honest.
  # * *No path / extension fallback.* Extensions lie (a renamed
  #   +.png+ → opaque garbage); magic-byte detection on the actual
  #   content is the source of truth. Callers that need
  #   extension-based behaviour can layer it themselves.
  # * *No convenience predicates* like +image?+ / +pdf?+. Callers do
  #   +mime == 'application/pdf'+ or +mime&.start_with?('image/')+ —
  #   one extra character, zero added API surface.
  module FileType
    module_function

    # @return [Integer] recommended number of bytes to sample for
    #   {.detect_mime} and {.binary?}. Big enough to catch every
    #   prefix pikuri sniffs today (the largest is WebP's 12-byte
    #   container header) with comfortable slack; small enough that
    #   reading it off any reasonable filesystem is effectively free.
    SAMPLE_BYTES = 4096

    # @return [Float] fraction of the sample that may be non-printable
    #   before {.binary?} flags the bytes as binary. Matches opencode's
    #   threshold.
    BINARY_NONPRINTABLE_THRESHOLD = 0.30

    # @return [Hash{String => String}] magic-byte prefixes → MIME types
    #   for the image formats with flat (offset-zero, fixed-length)
    #   signatures. WebP isn't here — its signature is split across the
    #   RIFF container header — and is handled directly in
    #   {.detect_mime}.
    IMAGE_MAGIC_BYTES = {
      "\x89PNG\r\n\x1a\n".b => 'image/png',
      "\xff\xd8\xff".b      => 'image/jpeg',
      "GIF87a".b            => 'image/gif',
      "GIF89a".b            => 'image/gif'
    }.freeze

    # @return [String] PDF magic prefix. Every conformant PDF starts
    #   with this five-byte ASCII sequence per ISO 32000-1 §7.5.2.
    PDF_MAGIC = '%PDF-'

    # @return [Integer] default line-window size for
    #   {.read_as_text_paged} when the caller omits +limit+.
    PAGE_DEFAULT_LIMIT = 2000

    # @return [Integer] default hard byte cap on the content collected
    #   by a single {.read_as_text_paged} call. Bypassable by paging
    #   via +offset+. The rendered output is slightly larger (line
    #   numbering, trailer) — that's the caller's concern.
    PAGE_MAX_BYTES = 50 * 1024

    # @return [Integer] default per-line character cap;
    #   {.read_as_text_paged} truncates longer lines and appends
    #   {PAGE_LINE_TRUNCATION_MARKER}.
    PAGE_MAX_LINE_LENGTH = 2000

    # @return [String] suffix appended to a line truncated at
    #   {PAGE_MAX_LINE_LENGTH}.
    PAGE_LINE_TRUNCATION_MARKER = "... (line truncated to #{PAGE_MAX_LINE_LENGTH} chars)"

    # One windowed slice of a document, returned by
    # {.read_as_text_paged}. The caller turns this into an
    # observation; this struct carries everything a trailer needs
    # without the caller re-reading the file.
    #
    # == Fields
    #
    # * +lines+ — +Array<String>+, the collected window. Already
    #   per-line truncated (with {PAGE_LINE_TRUNCATION_MARKER}); *not*
    #   line-numbered — numbering is presentation the caller adds. For
    #   a PDF the array includes +"--- Page N ---"+ marker lines (one
    #   per page that contributed text), which count toward +limit+ /
    #   the byte cap like any other line.
    # * +start_line+ — the 1-indexed line number of +lines.first+
    #   (i.e. the +offset+ the caller asked for). +lines.last+ is at
    #   +start_line + lines.length - 1+.
    # * +total_lines+ — total line count of the document when known,
    #   else +nil+. Known when extraction reached EOF (so the caller
    #   can print "of N"); +nil+ when the read stopped early — the
    #   byte cap fired, or a PDF filled the window before its last
    #   page (counting the rest would defeat the laziness).
    # * +more+ — +true+ if content remains past this window (the
    #   caller should offer +offset = start_line + lines.length+).
    # * +byte_capped+ — +true+ if {PAGE_MAX_BYTES} (not the line
    #   limit) was the stopping criterion.
    # * +kind+ — +:text+ or +:pdf+; lets the caller word PDF-specific
    #   trailers and the empty-document message.
    #
    # An empty document yields +lines: []+, +total_lines: 0+; an
    # +offset+ past EOF yields +lines: []+ with +total_lines+ set to
    # the real (non-zero) count — the caller distinguishes the two.
    Page = Data.define(:lines, :start_line, :total_lines, :more, :byte_capped, :kind)

    # Recognise a file from its leading bytes. Returns the MIME type
    # as a String for formats pikuri handles specially, or +nil+ for
    # "unrecognised" — callers interpret +nil+ themselves (text,
    # opaque binary, ...).
    #
    # @param input [String, Pathname] the bytes to inspect, or a
    #   +Pathname+ that this method opens in binary mode and reads up
    #   to {SAMPLE_BYTES} from. Caller is responsible for verifying the
    #   path exists; missing-file errors propagate as +Errno::ENOENT+.
    # @return [String, nil]
    def detect_mime(input)
      bytes = sample_of(input)
      return 'application/pdf' if bytes.start_with?(PDF_MAGIC)

      IMAGE_MAGIC_BYTES.each do |prefix, mime|
        return mime if bytes.start_with?(prefix)
      end
      return 'image/webp' if bytes.bytesize >= 12 &&
                             bytes.byteslice(0, 4) == 'RIFF'.b &&
                             bytes.byteslice(8, 4) == 'WEBP'.b

      nil
    end

    # Heuristic text-vs-binary classifier matching opencode's: any
    # +NUL+ byte forces +true+; otherwise count bytes outside the
    # printable +\t \n \v \f \r+ + ASCII-32..126 range and ratio
    # against the sample size. UTF-8 continuation bytes (0x80-0xBF)
    # are >127 so they sit outside the non-printable ranges and pass
    # through unflagged, letting UTF-8 text read fine. An empty
    # sample is treated as not-binary (callers reading an empty file
    # take the empty-text path).
    #
    # @param input [String, Pathname] the bytes to inspect, or a
    #   +Pathname+ that this method opens in binary mode and reads up
    #   to {SAMPLE_BYTES} from. Caller is responsible for verifying
    #   the path exists.
    # @return [Boolean]
    def binary?(input)
      bytes = sample_of(input)
      return false if bytes.empty?

      non_printable = 0
      bytes.each_byte do |b|
        return true if b.zero?

        non_printable += 1 if b < 9 || (b > 13 && b < 32)
      end
      non_printable.to_f / bytes.bytesize > BINARY_NONPRINTABLE_THRESHOLD
    end

    # Read +path+ and return its content as plain UTF-8 text. Two
    # extraction paths, picked by {.detect_mime}:
    #
    # * **PDF** — walked page-by-page via +pdf-reader+; each page's
    #   extracted text is stripped and pages are joined with a blank
    #   line. A scanned-image PDF (no extractable text) comes back as
    #   the empty String — a deliberate silent skip, callers detect by
    #   length if they care.
    # * **Plain text** — anything that {.detect_mime} doesn't
    #   recognise and that {.binary?} accepts. Read with UTF-8
    #   encoding; behaviour on non-UTF-8 bytes is whatever +File.read+
    #   does with +encoding: Encoding::UTF_8+ (which is "leave invalid
    #   bytes in, let downstream decide").
    #
    # Refusal cases — all raise rather than returning a sentinel
    # because the callers are internal pikuri code, not an LLM
    # tool. The LLM-facing +Workspace::Read+ does its own routing and
    # returns "Error: ..." observations; that's a separate concern.
    #
    # * Path doesn't exist → +Errno::ENOENT+.
    # * Path is a directory → +ArgumentError+.
    # * Image (PNG / JPEG / GIF / WebP per {.detect_mime}) →
    #   +ArgumentError+; images aren't text.
    # * Binary content (per {.binary?}) and not a recognised MIME →
    #   +ArgumentError+.
    # * Malformed PDF — +pdf-reader+'s
    #   +MalformedPDFError+ / +UnsupportedFeatureError+ /
    #   +InvalidPageError+ are re-raised as a +RuntimeError+ with the
    #   path included so callers don't need to know pdf-reader's
    #   exception hierarchy.
    #
    # @param path [Pathname] file to read.
    # @return [String] UTF-8 text. May be empty (empty text file, or
    #   scanned-image PDF).
    # @raise [ArgumentError] if +path+ isn't a +Pathname+, points at
    #   a directory, is an image, or is binary.
    # @raise [Errno::ENOENT] if +path+ doesn't exist.
    # @raise [RuntimeError] on a malformed / unsupported PDF.
    def read_as_text(path)
      raise ArgumentError, "expected Pathname, got #{path.class}" unless path.is_a?(Pathname)
      raise Errno::ENOENT, path.to_s unless path.exist?
      raise ArgumentError, "#{path} is a directory" if path.directory?

      mime = detect_mime(path)
      return read_pdf_text(path) if mime == 'application/pdf'
      raise ArgumentError, "#{path} is an image (#{mime}); cannot extract as text" if mime&.start_with?('image/')
      raise ArgumentError, "#{path} appears to be binary; cannot extract as text" if binary?(path)

      path.read(encoding: Encoding::UTF_8)
    end

    # Walk a PDF page-by-page via +pdf-reader+, returning a single
    # String with non-empty page texts joined by blank lines. Catches
    # the three +PDF::Reader+ exceptions Workspace::Read also handles
    # and re-raises them as +RuntimeError+ with the path included.
    #
    # @param path [Pathname]
    # @return [String]
    # @raise [RuntimeError] on malformed / unsupported PDF.
    def read_pdf_text(path)
      pages = path.open('rb') do |io|
        ::PDF::Reader.new(io).pages.map { |p| p.text.strip }
      end
      pages.reject(&:empty?).join("\n\n")
    rescue ::PDF::Reader::MalformedPDFError,
           ::PDF::Reader::UnsupportedFeatureError,
           ::PDF::Reader::InvalidPageError => e
      raise "Cannot extract PDF text from #{path}: " \
            "#{e.class.name.split('::').last}: #{e.message}"
    end
    private_class_method :read_pdf_text

    # Extract +path+ as text and return a windowed {Page}: the lines
    # from +offset+ (1-indexed) up to +limit+ of them, stopping early
    # if +max_bytes+ is reached, with over-long lines truncated at
    # +max_line_length+. Lazy by design — a text file is streamed
    # line-by-line and a PDF is parsed page-by-page only until the
    # window fills, so reading the first page of a 500-page PDF parses
    # a handful of pages, not all of them.
    #
    # Same routing and refusal contract as {.read_as_text}: PDFs are
    # extracted (with +"--- Page N ---"+ marker lines, unlike
    # {.read_as_text}'s marker-free join — paging is a display path,
    # the marker-free form stays the indexing path); images, binaries,
    # directories, missing files, and malformed PDFs all raise rather
    # than returning a sentinel. The LLM-facing callers map those into
    # +"Error: ..."+ observations themselves.
    #
    # @param path [Pathname] file to read.
    # @param offset [Integer] 1-indexed first line to include. The
    #   caller is responsible for validating +offset >= 1+.
    # @param limit [Integer] maximum lines to collect. Caller
    #   validates +limit >= 1+.
    # @param max_bytes [Integer] hard byte cap on collected content.
    # @param max_line_length [Integer] per-line truncation threshold.
    # @return [Page] the windowed slice.
    # @raise [ArgumentError] if +path+ isn't a +Pathname+, is a
    #   directory, an image, or binary.
    # @raise [Errno::ENOENT] if +path+ doesn't exist.
    # @raise [RuntimeError] on a malformed / unsupported PDF.
    def read_as_text_paged(path, offset: 1, limit: PAGE_DEFAULT_LIMIT,
                           max_bytes: PAGE_MAX_BYTES, max_line_length: PAGE_MAX_LINE_LENGTH)
      raise ArgumentError, "expected Pathname, got #{path.class}" unless path.is_a?(Pathname)
      raise Errno::ENOENT, path.to_s unless path.exist?
      raise ArgumentError, "#{path} is a directory" if path.directory?

      mime = detect_mime(path)
      if mime == 'application/pdf'
        return paged_pdf(path, offset: offset, limit: limit,
                               max_bytes: max_bytes, max_line_length: max_line_length)
      end
      raise ArgumentError, "#{path} is an image (#{mime}); cannot extract as text" if mime&.start_with?('image/')
      raise ArgumentError, "#{path} appears to be binary; cannot extract as text" if binary?(path)

      paged_text(path, offset: offset, limit: limit,
                       max_bytes: max_bytes, max_line_length: max_line_length)
    end

    # Stream a text file line-by-line into a {Page}. Keeps counting
    # lines past the collection window so +total_lines+ can report the
    # real total when the line limit (not the byte cap) stopped
    # collection; on the byte cap it breaks and leaves +total_lines+
    # +nil+ (the rest of the file is never read).
    #
    # @return [Page] +kind: :text+.
    def paged_text(path, offset:, limit:, max_bytes:, max_line_length:)
      start_index = offset - 1
      collected   = []
      total_lines = 0
      bytes       = 0
      byte_capped = false
      more        = false

      path.each_line do |raw|
        total_lines += 1
        next if total_lines <= start_index

        if collected.length >= limit
          more = true
          next
        end

        line = truncate_line(raw.chomp, max_line_length)
        size = line.bytesize + 1 # +1 for the joining newline
        if bytes + size > max_bytes
          byte_capped = true
          more = true
          break
        end
        collected << line
        bytes += size
      end

      Page.new(lines: collected, start_line: offset,
               total_lines: byte_capped ? nil : total_lines,
               more: more, byte_capped: byte_capped, kind: :text)
    end
    private_class_method :paged_text

    # PDF counterpart to {paged_text}: walk +pdf-reader+'s lazy page
    # iterator, emitting a +"--- Page N ---"+ header line then each
    # line of the page's text, applying the same offset / limit /
    # byte-cap contract. The +throw :done+ short-circuits both loops
    # the moment the window fills, so parsing stops — which is why a
    # PDF that stops early can't report +total_lines+ (it would have
    # to parse every page to count).
    #
    # @return [Page] +kind: :pdf+.
    # @raise [RuntimeError] on a malformed / unsupported PDF.
    def paged_pdf(path, offset:, limit:, max_bytes:, max_line_length:)
      start_index = offset - 1
      collected   = []
      total_lines = 0
      bytes       = 0
      byte_capped = false
      more        = false

      catch(:done) do
        path.open('rb') do |io|
          reader = ::PDF::Reader.new(io)
          reader.pages.each_with_index do |page, idx|
            text = page.text.strip
            next if text.empty?

            ["--- Page #{idx + 1} ---", *text.split("\n")].each do |raw|
              total_lines += 1
              next if total_lines <= start_index

              if collected.length >= limit
                more = true
                throw :done
              end

              line = truncate_line(raw, max_line_length)
              size = line.bytesize + 1
              if bytes + size > max_bytes
                byte_capped = true
                more = true
                throw :done
              end
              collected << line
              bytes += size
            end
          end
        end
      end

      Page.new(lines: collected, start_line: offset,
               total_lines: more ? nil : total_lines,
               more: more, byte_capped: byte_capped, kind: :pdf)
    rescue ::PDF::Reader::MalformedPDFError,
           ::PDF::Reader::InvalidPageError,
           ::PDF::Reader::UnsupportedFeatureError => e
      raise "Cannot extract PDF text from #{path}: " \
            "#{e.class.name.split('::').last}: #{e.message}"
    end
    private_class_method :paged_pdf

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

    # Coerce an +input+ argument into a bytes String for the sniffs.
    # +String+ inputs are returned as-is (caller already sampled);
    # +Pathname+ inputs are opened in binary mode and up to
    # {SAMPLE_BYTES} are read off the front. Empty files come back
    # as an empty String — {.binary?} treats that as not-binary and
    # {.detect_mime} returns +nil+ for it, which is what the
    # empty-text path wants.
    #
    # @param input [String, Pathname]
    # @return [String] raw bytes (ASCII-8BIT encoding for the path
    #   case; whatever the caller passed for the bytes case)
    # @raise [ArgumentError] if +input+ is neither a +String+ nor a
    #   +Pathname+ — refuses to guess, since a bare String could be
    #   either a path or actual bytes.
    def sample_of(input)
      case input
      when String
        input
      when Pathname
        input.open('rb') { |io| io.read(SAMPLE_BYTES) || +'' }
      else
        raise ArgumentError, "expected String bytes or Pathname, got #{input.class}"
      end
    end
    private_class_method :sample_of
  end
end
