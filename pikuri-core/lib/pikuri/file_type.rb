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
  # Both methods accept either a +String+ of bytes (sample taken by the
  # caller) or a +Pathname+ — when given a path, the module opens the
  # file in binary mode and reads {SAMPLE_BYTES} for the sniff itself.
  # The Pathname form is the convenience path; the bytes form is for
  # callers that already have the sample or are calling both methods on
  # the same file and want to avoid a second open.
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
