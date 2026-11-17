# frozen_string_literal: true

module Pikuri
  module Extractor
    # The terminal plain-text arm of the registry: content that *is* already
    # text passes through verbatim (forced to UTF-8, invalid bytes left in, as
    # +File.read+ does). Markdown, source files, JSON, robots.txt land here.
    #
    # Matching splits on whether the transport gave a content-type:
    #
    # * With one (the web path): claim +text/*+ only — a non-text type no
    #   earlier extractor claimed is *not* second-guessed by sniffing
    #   (+application/octet-stream+ gets the {Unsupported} refusal).
    # * Without one (the local-file path, {FileType.detect_mime} → +nil+): claim
    #   anything passing {FileType.binary?} on the sample; opaque binaries stay
    #   unclaimed and surface as {Unsupported}. A format {FileType.detect_mime}
    #   recognises is never text, however ASCII its head: a PDF's first 4 KB of
    #   dictionaries passes {FileType.binary?}, and would reach the model raw on
    #   a host without a PDF extractor.
    module Passthrough
      # @return [Symbol] {Page#kind} tag.
      def self.kind
        :text
      end

      # @param sample [String] leading bytes of the content.
      # @param content_type [String, nil] normalized content-type,
      #   +nil+ when the transport has none.
      # @return [Boolean]
      def self.matches?(sample:, content_type:)
        return content_type.start_with?('text/') unless content_type.nil?

        FileType.detect_mime(sample).nil? && !FileType.binary?(sample)
      end

      # @param io [IO, StringIO] IO over the text content.
      # @return [String] the content, tagged UTF-8. Deliberately NOT derived
      #   from {.extract_lines} — a passthrough stays verbatim (trailing
      #   newline, CRLF), which joining chomped lines would normalize away.
      def self.extract(io)
        io.read.force_encoding(Encoding::UTF_8)
      end

      # Lazy line stream for {Extractor.extract_paged}: read line-by-line, so a
      # window over the head of a gigabyte log never loads the rest. The whole
      # stream is a cheap sequential read — which is why paging counts this
      # tail for an exact +total_lines+.
      #
      # @param io [IO, StringIO] IO over the text content; must stay open while
      #   the enumerator is consumed.
      # @return [Enumerator::Lazy<String>] chomped lines, tagged UTF-8.
      def self.extract_lines(io)
        io.each_line.lazy.map { |raw| raw.chomp.force_encoding(Encoding::UTF_8) }
      end
    end
  end
end
