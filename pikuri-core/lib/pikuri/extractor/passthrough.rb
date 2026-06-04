# frozen_string_literal: true

module Pikuri
  module Extractor
    # The terminal plain-text arm of the registry: content that *is*
    # already text needs no extraction, so it passes through verbatim
    # (forced to UTF-8 — invalid bytes are left in for downstream to
    # deal with, matching what +File.read+ with a UTF-8 encoding does).
    # Markdown, source files, JSON, robots.txt all land here.
    #
    # Matching is split by whether the transport supplied a
    # content-type:
    #
    # * With a content-type (the web path): claim +text/*+ only.
    #   A non-text type that no earlier extractor claimed is *not*
    #   second-guessed by sniffing — a server declaring
    #   +application/octet-stream+ gets the {Unsupported} refusal the
    #   LLM can react to, same as before this registry existed.
    # * Without one (the local-file path, where {FileType.detect_mime}
    #   returned +nil+ for "unrecognised"): claim anything that passes
    #   the {FileType.binary?} heuristic on the sample. Opaque
    #   binaries stay unclaimed and surface as {Unsupported}.
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

        !FileType.binary?(sample)
      end

      # @param io [IO, StringIO] IO over the text content.
      # @return [String] the content, tagged UTF-8.
      def self.extract(io)
        io.read.force_encoding(Encoding::UTF_8)
      end
    end
  end
end
