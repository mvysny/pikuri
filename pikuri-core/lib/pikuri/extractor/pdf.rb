# frozen_string_literal: true

require 'pdf-reader'

module Pikuri
  module Extractor
    # PDF → text extractor. Wraps the +pdf-reader+ gem: walk every
    # page, emit a +"--- Page N ---"+ marker line followed by that
    # page's extracted text, join the blocks with single newlines.
    # The markers give every consumer page provenance — the Read
    # tools tell the model to cite pages back to the user from them,
    # +vectordb_search+ chunks carry them so a hit can say which page
    # it came from, and what +vectordb_read+ shows matches what was
    # indexed exactly. Pages with no extractable text contribute
    # nothing (no marker either), so a fully scanned PDF extracts to
    # the empty String — a deliberate silent skip callers detect by
    # length if they care. No OCR in this path.
    #
    # Matched by the +%PDF-+ magic prefix *or* an +application/pdf+
    # content-type — magic first in the registry order, so a PDF
    # served under a lying header is still extracted.
    #
    # Best-effort by design: +pdf-reader+ produces clean text from
    # PDFs generated from a digital source (LaTeX, Word export, ...)
    # but nothing useful from scanned documents.
    module PDF
      # @return [Symbol] {Page#kind} tag.
      def self.kind
        :pdf
      end

      # @param sample [String] leading bytes of the content.
      # @param content_type [String, nil] normalized content-type,
      #   when the transport supplies one.
      # @return [Boolean]
      def self.matches?(sample:, content_type:)
        content_type == 'application/pdf' || sample.start_with?(FileType::PDF_MAGIC)
      end

      # Render the PDF behind +io+ as plain text, one
      # +"--- Page N ---"+-headed block per page that carries text.
      #
      # +pdf-reader+ raises a handful of typed exceptions for
      # documents it cannot parse — broken xrefs
      # ({::PDF::Reader::MalformedPDFError}), invalid page references
      # ({::PDF::Reader::InvalidPageError}), encrypted/XFA files
      # ({::PDF::Reader::UnsupportedFeatureError}). All three describe
      # a property of the document the LLM can react to ("try a
      # different URL / file"), so they re-raise as {Extractor::Error}.
      # Genuine bugs in +pdf-reader+ itself surface as their own
      # classes and crash loud.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start
      #   of the PDF bytes.
      # @return [String] concatenated page blocks; possibly empty when
      #   the PDF carries no extractable text (scanned image, empty
      #   document).
      # @raise [Extractor::Error] when +pdf-reader+ refuses the
      #   document.
      def self.extract(io)
        pages = ::PDF::Reader.new(io).pages.map { |p| p.text.strip }
        pages.each_with_index
             .filter_map { |text, idx| "--- Page #{idx + 1} ---\n#{text}" unless text.empty? }
             .join("\n")
      rescue ::PDF::Reader::MalformedPDFError,
             ::PDF::Reader::InvalidPageError,
             ::PDF::Reader::UnsupportedFeatureError => e
        raise Error, "PDF rendering failed: #{e.class.name.split('::').last}: #{e.message}"
      end
    end
  end
end
