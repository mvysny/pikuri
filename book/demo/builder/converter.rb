# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'tmpdir'

module Pikuri
  module Demo
    # HTML to PDF, DOCX or ODT through LibreOffice, the way the binary
    # documents and attachments are made: only the HTML is versioned.
    #
    # LibreOffice stamps every PDF with a creation date and a fresh ID, so two
    # conversions of one source differ. Each result is therefore cached by the
    # digest of its source, which keeps the builder's inputs, and so its cache
    # key, the same from build to build. LibreOffice runs with its own user
    # profile under the cache, never the user's.
    class Converter
      # Target extension => LibreOffice's --convert-to argument.
      FILTERS = { 'pdf' => 'pdf:writer_pdf_Export', 'docx' => 'docx:MS Word 2007 XML', 'odt' => 'odt' }.freeze

      # @param cache_dir [String]
      def initialize(cache_dir:)
        @cache_dir = cache_dir
      end

      # @param html [String] the rendered source.
      # @param to [String] a key of {FILTERS}.
      # @return [String] the converted bytes.
      # @raise [RuntimeError] when LibreOffice fails.
      def convert(html, to)
        cached = File.join(@cache_dir, "#{Digest::SHA256.hexdigest("#{to}\0#{html}")}.#{to}")
        return File.binread(cached) if File.file?(cached)

        FileUtils.mkdir_p(@cache_dir)
        Dir.mktmpdir('pikuri-demo-convert-') do |tmp|
          source = File.join(tmp, 'source.html')
          File.write(source, html)
          _out, err, status = Open3.capture3(
            'soffice', "-env:UserInstallation=file://#{File.join(@cache_dir, 'libreoffice-profile')}",
            '--headless', '--infilter=HTML (StarWriter)', '--convert-to', FILTERS.fetch(to),
            '--outdir', tmp, source
          )
          result = File.join(tmp, "source.#{to}")
          raise "soffice couldn't convert to #{to}: #{err.strip}" unless status.success? && File.file?(result)

          FileUtils.mv(result, cached)
        end
        File.binread(cached)
      end
    end
  end
end
