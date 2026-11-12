# frozen_string_literal: true

require 'pdf-reader'

module Pikuri
  module Extractors
    # PDF → text extractor over the +pdf-reader+ gem: each page emits a
    # +"--- Page N ---"+ marker line then its text, blocks joined by
    # single newlines. The markers carry page provenance downstream (a
    # cited answer, a +vectordb+ hit's page number). A page with no
    # extractable text contributes nothing — no marker — so a fully
    # scanned PDF extracts to the empty String, a deliberate silent
    # skip callers detect by length. No OCR here: +pdf-reader+ gives
    # clean text from digitally-generated PDFs, nothing from scans.
    #
    # == Why a separate gem
    #
    # Split from pikuri-core to keep pdf-reader's five-gem dependency
    # tail (Ascii85, afm, hashery, ruby-rc4, ttfunk) out of the core
    # audit tree — five gems for one format nothing else in core uses.
    # Hosts opt in with one {.register} call. Being in-process, it pages
    # *lazily* ({.extract_lines} parses pages on demand) — a property a
    # subprocess converter structurally cannot have. (The full
    # this-gem-vs-pikuri-extractors PDF trade-off is in
    # +pikuri-extractors/design/architecture.md+.)
    #
    # == Registration is explicit
    #
    # Requiring the gem registers nothing; a host opts in with
    # +Pikuri::Extractors::PDF.register+, which *front*-inserts into the
    # registry (unlike pikuri-extractors' before-terminal insert)
    # because the +%PDF-+ magic sniff is the registry's strongest
    # signal — it must beat pikuri-web's +HTML+ content-type match so a
    # PDF under a lying header still extracts, and it never misfires on text.
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
      # The three typed +pdf-reader+ parse failures — broken xrefs
      # ({::PDF::Reader::MalformedPDFError}), bad page refs
      # ({::PDF::Reader::InvalidPageError}), encrypted/XFA
      # ({::PDF::Reader::UnsupportedFeatureError}) — are document
      # properties the LLM can react to, so they re-raise as
      # {Pikuri::Extractor::Error}, from *inside* the enumerator: at
      # consumption time, which for a broken xref means the first
      # +next+. Other +pdf-reader+ errors are bugs and crash loud.
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
