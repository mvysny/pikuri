# frozen_string_literal: true

require 'pdf-reader'

module Pikuri
  module Extractors
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
    # == Why a separate gem
    #
    # This extractor lived in pikuri-core until pdf-reader's
    # dependency tail (Ascii85, afm, hashery, ruby-rc4, ttfunk) became
    # the largest single bite in the core's audit tree — five gems for
    # one file format, serving nothing else in core. Splitting it out
    # keeps the core minimal; hosts that want PDFs opt in with one
    # {.register} call. Distinct from pikuri-extractors' sandboxed
    # subprocess converters: this one is in-process and *lazy*
    # ({.extract_lines} parses pages on demand), a property a
    # subprocess converter structurally cannot have — see
    # +Pikuri::Extractor+'s windowing yardoc.
    #
    # == Registration is explicit
    #
    # Requiring pikuri-pdf defines this module but registers nothing.
    # A host script opts in with +Pikuri::Extractors::PDF.register+,
    # which inserts it at the *front* of the registry — unlike
    # pikuri-extractors' before-the-terminal insert — because the
    # +%PDF-+ magic-byte sniff is the strongest signal in the
    # registry: it must win over +HTML+'s content-type match so a PDF
    # served under a lying header is still extracted, and it never
    # misfires on text.
    #
    # Matched by the +%PDF-+ magic prefix *or* an +application/pdf+
    # content-type.
    #
    # Best-effort by design: +pdf-reader+ produces clean text from
    # PDFs generated from a digital source (LaTeX, Word export, ...)
    # but nothing useful from scanned documents.
    module PDF
      # Insert this extractor at the front of
      # +Pikuri::Extractor.registry+ (see "Registration is explicit"
      # above for why the front). Idempotent.
      #
      # @return [Module] self, for one-line wiring in host scripts.
      def self.register
        registry = Pikuri::Extractor.registry
        registry.unshift(self) unless registry.include?(self)
        self
      end

      # @return [Symbol] {Pikuri::Extractor::Page#kind} tag.
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
      # Defined as +extract_lines.to_a.join+ so the two duck-type
      # shapes cannot drift apart.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start
      #   of the PDF bytes.
      # @return [String] concatenated page blocks; possibly empty when
      #   the PDF carries no extractable text (scanned image, empty
      #   document).
      # @raise [Pikuri::Extractor::Error] when +pdf-reader+ refuses
      #   the document.
      def self.extract(io)
        extract_lines(io).to_a.join("\n")
      end

      # The lazy line stream behind {.extract}: a marker line per
      # text-carrying page, then that page's lines. +pdf-reader+
      # parses a page's content stream only when +Page#text+ is
      # called, so a consumer that stops early (the
      # +Pikuri::Extractor.extract_paged+ window) never pays for the
      # pages past its window.
      #
      # +pdf-reader+ raises a handful of typed exceptions for
      # documents it cannot parse — broken xrefs
      # ({::PDF::Reader::MalformedPDFError}), invalid page references
      # ({::PDF::Reader::InvalidPageError}), encrypted/XFA files
      # ({::PDF::Reader::UnsupportedFeatureError}). All three describe
      # a property of the document the LLM can react to ("try a
      # different URL / file"), so they re-raise as
      # {Pikuri::Extractor::Error} — from inside the enumerator, i.e.
      # at consumption time, which for a broken xref means the first
      # +next+. Genuine bugs in +pdf-reader+ itself surface as their
      # own classes and crash loud.
      #
      # @param io [IO, StringIO] seekable IO positioned at the start
      #   of the PDF bytes; must remain open while the enumerator is
      #   consumed.
      # @return [Enumerator<String>] chomped lines, produced
      #   page-by-page.
      # @raise [Pikuri::Extractor::Error] when +pdf-reader+ refuses
      #   the document (raised on consumption).
      def self.extract_lines(io)
        Enumerator.new do |lines|
          ::PDF::Reader.new(io).pages.each_with_index do |page, idx|
            text = page.text.strip
            next if text.empty?

            lines << "--- Page #{idx + 1} ---"
            text.split("\n").each { |line| lines << line }
          end
        rescue ::PDF::Reader::MalformedPDFError,
               ::PDF::Reader::InvalidPageError,
               ::PDF::Reader::UnsupportedFeatureError => e
          raise Pikuri::Extractor::Error,
                "PDF rendering failed: #{e.class.name.split('::').last}: #{e.message}"
        end
      end
    end
  end
end
