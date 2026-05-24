# frozen_string_literal: true

module Pikuri
  # Magic-byte content sniffing, centralised. Two responsibilities:
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
  #
  # Both methods take a +bytes+ sample — {SAMPLE_BYTES} of leading
  # content is the recommended slice. Callers read the sample once and
  # pass it to both, rather than re-reading.
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

    # Recognise a file from its leading bytes. Returns the MIME type
    # as a String for formats pikuri handles specially, or +nil+ for
    # "unrecognised" — callers interpret +nil+ themselves (text,
    # opaque binary, ...).
    #
    # @param bytes [String] sample of the file's leading bytes
    #   (typically {SAMPLE_BYTES} read with +File.binread+ or
    #   +io.read(SAMPLE_BYTES)+)
    # @return [String, nil]
    def detect_mime(bytes)
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
    # @param bytes [String] sample bytes
    # @return [Boolean]
    def binary?(bytes)
      return false if bytes.empty?

      non_printable = 0
      bytes.each_byte do |b|
        return true if b.zero?

        non_printable += 1 if b < 9 || (b > 13 && b < 32)
      end
      non_printable.to_f / bytes.bytesize > BINARY_NONPRINTABLE_THRESHOLD
    end
  end
end
