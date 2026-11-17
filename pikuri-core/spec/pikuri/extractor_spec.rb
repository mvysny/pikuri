# frozen_string_literal: true

require 'stringio'

# Exercise the registry front doors — routing (which extractor claims
# what, in which order) and the two consumption shapes. The extractors
# themselves are tested beside their own files; the path-aware
# wrappers in file_type_spec.rb cover the same windowing through real
# files, so this spec sticks to what only the registry decides.
RSpec.describe Pikuri::Extractor do
  def extract(body, content_type: nil)
    described_class.extract(StringIO.new(body), content_type: content_type)
  end

  describe '.extract routing' do
    it 'passes text/* content through verbatim' do
      assert_equal "User-agent: *\nDisallow: /private",
                   extract("User-agent: *\nDisallow: /private", content_type: 'text/plain')
    end

    it 'passes unrecognised-but-textual content through when there is no content-type' do
      assert_equal "# Title\n\nbody", extract("# Title\n\nbody")
    end

    it 'passes text/html through as raw markup out of the box (rendering lives in pikuri-web)' do
      html = '<html><body><p>hello world</p></body></html>'
      assert_equal html, extract(html, content_type: 'text/html')
    end

    it 'raises Unsupported for application/pdf out of the box (PDF support lives in pikuri-pdf)' do
      err = assert_raises(Pikuri::Extractor::Unsupported) do
        extract("%PDF-1.4\nwhatever", content_type: 'application/pdf')
      end
      assert_includes err.message, 'application/pdf'
    end

    it 'raises Unsupported for a non-text content-type nothing claims, without sniffing' do
      # The body is perfectly readable text, but a transport that says
      # application/octet-stream is not second-guessed.
      err = assert_raises(Pikuri::Extractor::Unsupported) do
        extract('plain enough', content_type: 'application/octet-stream')
      end
      assert_includes err.message, 'application/octet-stream'
    end

    it 'raises Unsupported for opaque binary content with no content-type' do
      assert_raises(Pikuri::Extractor::Unsupported) do
        extract("PK\x03\x04".b + ("\x00" * 32).b)
      end
    end

    it 'raises Unsupported for a PDF with no content-type, even when its head reads as text' do
      assert_raises(Pikuri::Extractor::Unsupported) do
        extract("%PDF-1.4\n1 0 obj << /Type /Font /Encoding /Identity-H >> endobj\n")
      end
      assert_raises(Pikuri::Extractor::Unsupported) do
        described_class.extract_paged(StringIO.new("%PDF-1.4\n1 0 obj << >> endobj\n"))
      end
    end

    it 'raises Unsupported for an empty-string content-type (missing header is not nil)' do
      assert_raises(Pikuri::Extractor::Unsupported) { extract('whatever', content_type: '') }
    end

    it 'rewinds after the sniff so the matched extractor reads from the start' do
      assert_equal 'full body here', extract('full body here', content_type: 'text/plain')
    end
  end

  describe '.extract_paged' do
    def extract_paged(body, **kwargs)
      described_class.extract_paged(StringIO.new(body), **kwargs)
    end

    it 'streams plain text lazily: the byte cap stops the read, leaving total_lines nil' do
      body = (1..80).map { 'a' * 1023 }.join("\n")
      page = extract_paged(body, max_bytes: 4096)

      assert page.byte_capped
      assert page.more
      assert_nil page.total_lines
      assert_equal :text, page.kind
    end

    it 'windows plain text by offset and limit with an exact total' do
      page = extract_paged("one\ntwo\nthree\nfour\nfive", offset: 2, limit: 2)

      assert_equal %w[two three], page.lines
      assert_equal 2, page.start_line
      assert_equal 5, page.total_lines
      assert page.more
      assert_equal :text, page.kind
    end

    it 'extracts formats without extract_lines in full, so their total is known even when the window fills' do
      whole = Module.new do
        def self.kind = :whole

        def self.matches?(sample:, content_type:)
          sample.start_with?('WHOLE')
        end

        def self.extract(io)
          io.read.split.join("\n")
        end
      end

      described_class.registry.unshift(whole)
      begin
        page = extract_paged('WHOLE a b c d', limit: 1)

        assert_equal %w[WHOLE], page.lines
        assert page.more
        assert_equal 5, page.total_lines
        assert_equal :whole, page.kind
      ensure
        described_class.registry.delete(whole)
      end
    end

    it 'consumes extract_lines lazily, stopping the moment the window fills' do
      # An extractor whose line stream is INFINITE: if extract_paged
      # consumed it eagerly (or counted the tail for a total), this
      # spec would hang. Stopping with the window proves both the
      # lazy consumption and the no-tail-count default for
      # extract_lines extractors — the contract PDF relies on so
      # pages past the window are never parsed.
      endless = Module.new do
        def self.kind = :endless

        def self.matches?(sample:, content_type:)
          sample.start_with?('ENDLESS')
        end

        def self.extract(io)
          raise 'extract_paged must prefer extract_lines'
        end

        def self.extract_lines(_io)
          Enumerator.new { |lines| 1.step { |i| lines << "line#{i}" } }
        end
      end

      described_class.registry.unshift(endless)
      begin
        page = extract_paged('ENDLESS stream', limit: 3)

        assert_equal %w[line1 line2 line3], page.lines
        assert page.more
        assert_nil page.total_lines, 'counting an extract_lines tail would defeat the laziness'
        assert_equal :endless, page.kind
      ensure
        described_class.registry.delete(endless)
      end
    end

    it 'keeps the exact total for plain text by counting the cheap stream tail' do
      page = extract_paged("a\nb\nc\nd\ne", limit: 2)

      assert_equal %w[a b], page.lines
      assert page.more
      assert_equal 5, page.total_lines
    end
  end

  describe '.registry' do
    it 'ships only the terminal Passthrough; further formats are plug-in gems' do
      assert_equal [Pikuri::Extractor::Passthrough], described_class.registry
    end
  end
end
