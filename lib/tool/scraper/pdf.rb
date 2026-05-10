# frozen_string_literal: true

require 'pdf-reader'
require 'stringio'
class Tool
  module Scraper
    # PDF → text extractor used by {Simple.visit} when the fetched
    # response carries +application/pdf+. Wraps the +pdf-reader+ gem:
    # walk every page, concatenate the extracted text, hand the result
    # back as a single string the LLM can read.
    #
    # Best-effort by design. +pdf-reader+ produces clean text from PDFs
    # generated from a digital source (LaTeX, Word export, ...) but
    # returns nothing useful from scanned documents — there is no OCR
    # in this path. When extraction yields no text we still return an
    # empty string rather than raising, so the caller's cache stores a
    # consistent result and the LLM sees an empty observation it can
    # react to.
    #
    # Pure parser — no I/O. {.extract} takes PDF bytes and returns text,
    # so tests can drive it against an in-memory fixture without
    # touching the network.
    module PDF
      # Render +bytes+ as plain text, one page per paragraph.
      #
      # +pdf-reader+ raises a handful of typed exceptions for documents
      # it cannot parse — broken xrefs ({::PDF::Reader::MalformedPDFError}),
      # invalid page references ({::PDF::Reader::InvalidPageError}),
      # encrypted/XFA files ({::PDF::Reader::UnsupportedFeatureError}).
      # All three describe a property of the PDF the LLM can react to
      # ("try a different URL"), so we re-raise them as {FetchError} —
      # same convention as the HTTP layer in {Simple.fetch}. Genuine
      # bugs in +pdf-reader+ itself surface as their own classes and
      # crash loud.
      #
      # @param bytes [String] raw PDF document (binary string)
      # @return [String] concatenated page text; possibly empty when
      #   the PDF carries no extractable text (scanned image, empty
      #   document)
      # @raise [FetchError] when +pdf-reader+ refuses the document
      def self.extract(bytes)
        reader = ::PDF::Reader.new(StringIO.new(bytes))
        reader.pages.map { |p| p.text.strip }.reject(&:empty?).join("\n\n")
      rescue ::PDF::Reader::MalformedPDFError,
             ::PDF::Reader::InvalidPageError,
             ::PDF::Reader::UnsupportedFeatureError => e
        raise FetchError, "PDF rendering failed: #{e.class.name.split('::').last}: #{e.message}"
      end
    end
  end
end
