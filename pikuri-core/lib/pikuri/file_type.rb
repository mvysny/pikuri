# frozen_string_literal: true

module Pikuri
  # Magic-byte content sniffing, plus the path-aware front over the
  # {Extractor} registry. Two core responsibilities:
  #
  # * {.detect_mime} — recognise a file from its leading bytes. Returns a
  #   MIME String for formats pikuri handles specially (+application/pdf+,
  #   the four image formats), or +nil+ for "unrecognised".
  # * {.binary?} — text-vs-binary heuristic, independent of {.detect_mime}
  #   (a file can be both recognised, e.g. PDF, *and* binary): what the
  #   bytes are vs. whether they're safe to render as text.
  #
  # On top sit two +Pathname+ conveniences, {.read_as_text} (whole document)
  # and {.read_as_text_paged} (line-windowed). Both own the *path-level*
  # refusals (missing file, directory, image) and the exception mapping,
  # then hand the IO to {Extractor}; format-to-text is the registry's
  # business, so a new extractor extends these wrappers for free.
  #
  # {.detect_mime}/{.binary?} take either a +String+ of bytes (caller
  # sampled) or a +Pathname+ (opened binary, {SAMPLE_BYTES} read).
  #
  # == Deliberate non-goals
  #
  # * *Not a full MIME database.* The set grows when a tool needs a format,
  #   not speculatively.
  # * *No path/extension fallback.* Extensions lie (a renamed +.png+);
  #   magic-byte detection on content is the source of truth.
  # * *No +image?+/+pdf?+ predicates.* Callers do +mime == 'application/pdf'+
  #   — one character, zero added surface.
  module FileType
    module_function

    # @return [Integer] bytes to sample for {.detect_mime}/{.binary?}. Covers
    #   every prefix sniffed today (largest: WebP's 12-byte header) with slack.
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

    # Recognise a file from its leading bytes. Returns the MIME String for
    # formats pikuri handles specially, or +nil+ for "unrecognised" (text,
    # opaque binary, ...).
    #
    # @param input [String, Pathname] bytes to inspect, or a +Pathname+
    #   opened binary and read up to {SAMPLE_BYTES}. Caller verifies the path
    #   exists; missing-file errors propagate as +Errno::ENOENT+.
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

    # Text-vs-binary heuristic (opencode's): any +NUL+ forces +true+; else
    # ratio bytes outside printable (+\t\n\v\f\r+ + ASCII 32..126) against the
    # sample. UTF-8 continuation bytes (0x80-0xBF) sit above 127 so they pass
    # unflagged; an empty sample is not-binary.
    #
    # @param input [String, Pathname] bytes, or a +Pathname+ opened binary
    #   and read up to {SAMPLE_BYTES}. Caller verifies the path exists.
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

    # Read +path+ as plain UTF-8 text through the {Extractor} registry:
    # unrecognised-but-textual passes through verbatim; with pikuri-pdf
    # registered, PDFs get +"--- Page N ---"+ markers (a scanned-image PDF
    # comes back empty — a deliberate silent skip callers detect by length).
    # Refusals raise (callers are internal pikuri code, not an LLM tool).
    #
    # @param path [Pathname] file to read.
    # @return [String] UTF-8 text; may be empty (empty file, scanned PDF).
    # @raise [ArgumentError] if +path+ isn't a +Pathname+, is a directory, an
    #   image, or opaque binary (the last mapped from {Extractor::Unsupported}).
    # @raise [Errno::ENOENT] if +path+ doesn't exist.
    # @raise [RuntimeError] on an extraction failure (mapped from
    #   {Extractor::Error}, path included).
    def read_as_text(path)
      mime = guard_extractable(path)
      path.open('rb') { |io| Extractor.extract(io, content_type: mime) }
    rescue Extractor::Unsupported
      raise ArgumentError, "#{path} appears to be binary; cannot extract as text"
    rescue Extractor::Error => e
      raise "Cannot extract text from #{path}: #{e.message}"
    end

    # Extract +path+ into a windowed {Extractor::Page} (lines from +offset+ up
    # to +limit+, byte-capped, long lines truncated). Same routing and refusal
    # contract as {.read_as_text}; windowing semantics are
    # {Extractor.extract_paged}'s.
    #
    # @param path [Pathname] file to read.
    # @param offset [Integer] 1-indexed first line; caller validates +>= 1+.
    # @param limit [Integer] max lines to collect; caller validates +>= 1+.
    # @param max_bytes [Integer] hard byte cap on collected content.
    # @param max_line_length [Integer] per-line truncation threshold.
    # @return [Extractor::Page]
    # @raise [ArgumentError] if +path+ isn't a +Pathname+, is a directory, an
    #   image, or binary.
    # @raise [Errno::ENOENT] if +path+ doesn't exist.
    # @raise [RuntimeError] on an extraction failure.
    def read_as_text_paged(path, offset: 1, limit: Extractor::PAGE_DEFAULT_LIMIT,
                           max_bytes: Extractor::PAGE_MAX_BYTES,
                           max_line_length: Extractor::PAGE_MAX_LINE_LENGTH)
      mime = guard_extractable(path)
      path.open('rb') do |io|
        Extractor.extract_paged(io, content_type: mime, offset: offset, limit: limit,
                                    max_bytes: max_bytes, max_line_length: max_line_length)
      end
    rescue Extractor::Unsupported
      raise ArgumentError, "#{path} appears to be binary; cannot extract as text"
    rescue Extractor::Error => e
      raise "Cannot extract text from #{path}: #{e.message}"
    end

    # Shared path-level refusals for the read-as-text pair: an existing
    # non-directory +Pathname+, not an image (images are vision-model data).
    # Returns the {.detect_mime} result as the content-type hint.
    #
    # @param path [Pathname]
    # @return [String, nil] the sniffed MIME type.
    # @raise [ArgumentError] on a non-Pathname, a directory, or an image.
    # @raise [Errno::ENOENT] if +path+ doesn't exist.
    def guard_extractable(path)
      raise ArgumentError, "expected Pathname, got #{path.class}" unless path.is_a?(Pathname)
      raise Errno::ENOENT, path.to_s unless path.exist?
      raise ArgumentError, "#{path} is a directory" if path.directory?

      mime = detect_mime(path)
      raise ArgumentError, "#{path} is an image (#{mime}); cannot extract as text" if mime&.start_with?('image/')

      mime
    end
    private_class_method :guard_extractable

    # Coerce +input+ into a bytes String for the sniffs: a +String+ is
    # returned as-is, a +Pathname+ is opened binary and up to {SAMPLE_BYTES}
    # read. Empty files → empty String (not-binary, +nil+ mime).
    #
    # @param input [String, Pathname]
    # @return [String] raw bytes.
    # @raise [ArgumentError] if neither — refuses to guess, since a bare
    #   String could be a path or actual bytes.
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
