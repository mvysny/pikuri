# frozen_string_literal: true

require 'stringio'

# Exercise the registry front doors — routing (which extractor claims
# what, in which order) and the two consumption shapes. The extractors
# themselves are tested in spec/pikuri/extractor/; the path-aware
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

    it 'routes text/html through the HTML extractor' do
      out = extract('<html><body><h1>Hi</h1><p>hello world</p></body></html>',
                    content_type: 'text/html')
      assert_includes out, 'hello world'
      refute_includes out, '<p>'
    end

    it 'routes application/xhtml+xml through the HTML extractor' do
      out = extract('<html><body><p>xhtml content</p></body></html>',
                    content_type: 'application/xhtml+xml')
      assert_includes out, 'xhtml content'
    end

    it 'routes a %PDF- magic body to the PDF extractor even under a lying text content-type' do
      # Garbage after the magic prefix: reaching the PDF parse error
      # proves the PDF extractor (not the text passthrough) claimed it.
      err = assert_raises(Pikuri::Extractor::Error) do
        extract("%PDF-1.4\nnot really a pdf", content_type: 'text/plain')
      end
      assert_includes err.message, 'PDF rendering failed'
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

    it 'extracts non-text formats in full, so total_lines is known even when the window fills' do
      html = '<html><head><title>T</title></head><body><article>' \
             "<p>#{'x' * 600}</p></article></body></html>"
      page = extract_paged(html, content_type: 'text/html', limit: 1)

      assert_equal 1, page.lines.length
      assert page.more
      refute_nil page.total_lines
      assert_equal :html, page.kind
    end
  end

  describe '.registry' do
    it 'orders PDF (strongest sniff) before HTML before the terminal Passthrough' do
      assert_equal [Pikuri::Extractor::PDF, Pikuri::Extractor::HTML, Pikuri::Extractor::Passthrough],
                   described_class.registry
    end
  end
end
