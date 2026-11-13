# frozen_string_literal: true

require 'cgi'
require 'fileutils'

module Pikuri
  module Demo
    # The demo +~/Documents+, built from +dev/demo-home/documents/+.
    #
    # A source is rendered as ERB over the facts when it contains +<%+. A name
    # like +invoice-4471.pdf.html+ or +lease-agreement.pdf+odt.html+ is
    # converted through {Converter} into each listed format; any other file
    # is written as it is. A few binaries are drawn ({GENERATED}).
    class Documents
      # The versioned sources.
      SOURCE = File.expand_path('../documents', __dir__)

      # Files with no source text: drawn by {Png}.
      GENERATED = { 'scan-receipt.png' => -> { Png.named('receipt') } }.freeze

      # @param facts [Facts]
      # @param converter [Converter]
      def initialize(facts:, converter:)
        @facts = facts
        @converter = converter
      end

      # @return [Hash{String => String}] Documents-relative path to bytes.
      def files
        @files ||= begin
          built = Dir.glob('**/*', base: SOURCE).sort.select { |r| File.file?(File.join(SOURCE, r)) }
                     .each_with_object({}) { |rel, acc| acc.merge!(build(rel)) }
          built.merge(GENERATED.transform_values(&:call))
        end
      end

      # @param dir [String] the demo Documents directory (already guarded).
      # @return [void]
      def write(dir)
        files.each do |rel, bytes|
          path = File.join(dir, rel)
          FileUtils.mkdir_p(File.dirname(path))
          File.binwrite(path, bytes)
        end
      end

      # A long PDF for the "exclude your books" scene: some of this book's
      # chapters, Markdown turned into just enough HTML (headings, code
      # blocks, paragraphs) for LibreOffice.
      #
      # @param chapters [Array<String>] +book/<name>.md+ basenames.
      # @return [String] HTML body content.
      def self.book_html(chapters)
        chapters.map do |name|
          text = File.read(File.expand_path("../../../book/#{name}.md", __dir__))
          text.split(/^```.*\n/).each_with_index.map do |chunk, i|
            next "<pre>#{CGI.escapeHTML(chunk)}</pre>" if i.odd?

            chunk.split(/\n{2,}/).map do |para|
              if (h = para.match(/\A(#+)\s+(.*)/))
                level = [h[1].size, 3].min
                "<h#{level}>#{CGI.escapeHTML(h[2])}</h#{level}>"
              else
                "<p>#{CGI.escapeHTML(para.strip)}</p>"
              end
            end.join("\n")
          end.join("\n")
        end.join("\n")
      end

      private

      # @param rel [String] path under {SOURCE}.
      # @return [Hash{String => String}] what it becomes.
      def build(rel)
        text = File.binread(File.join(SOURCE, rel))
        text = @facts.render(text.force_encoding('UTF-8')) if text.include?('<%')
        match = rel.match(/\A(.+)\.([a-z]+(?:\+[a-z]+)*)\.html\z/)
        formats = match && match[2].split('+')
        return { rel => text } unless formats && (formats - Converter::FILTERS.keys).empty?

        formats.to_h { |to| ["#{match[1]}.#{to}", @converter.convert(text, to)] }
      end
    end
  end
end
