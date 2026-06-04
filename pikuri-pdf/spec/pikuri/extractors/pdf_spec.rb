# frozen_string_literal: true

require 'stringio'

# Drive +Extractors::PDF.extract+ against in-memory PDFs built by the
# shared +build_pdf+ helper rather than checking a binary fixture into
# the repo, so the assertions exercise the real extraction path
# end-to-end.
RSpec.describe Pikuri::Extractors::PDF, '.extract' do
  def extract(bytes)
    described_class.extract(StringIO.new(bytes))
  end

  it 'returns the page text headed by a --- Page N --- marker' do
    assert_equal "--- Page 1 ---\nHello PDF", extract(build_pdf('Hello PDF'))
  end

  it 'emits one marker-headed block per page, joined by single newlines' do
    assert_equal "--- Page 1 ---\nAlpha\n--- Page 2 ---\nBeta",
                 extract(build_pdf('Alpha', 'Beta'))
  end

  it 'skips pages with no extractable text, keeping the original page numbers' do
    # The middle page carries a zero-length Tj, which pdf-reader
    # collapses to "" — no marker for it, but page 3 keeps its number
    # so citations stay correct.
    assert_equal "--- Page 1 ---\nAlpha\n--- Page 3 ---\nGamma",
                 extract(build_pdf('Alpha', '', 'Gamma'))
  end

  it 'returns an empty string when the PDF carries no extractable text at all' do
    # We choose to return "" rather than raise so the caller's cache
    # stores a stable result and the LLM can observe the empty body.
    assert_equal '', extract(build_pdf(''))
  end

  it 'raises Extractor::Error on malformed PDF bytes' do
    err = assert_raises(Pikuri::Extractor::Error) { extract('not a pdf at all') }
    assert_includes err.message, 'PDF rendering failed'
    assert_includes err.message, 'MalformedPDFError'
  end

  describe '.extract_lines' do
    it 'yields the marker and page lines in extract order' do
      lines = described_class.extract_lines(StringIO.new(build_pdf('Alpha', 'Beta'))).to_a
      assert_equal ['--- Page 1 ---', 'Alpha', '--- Page 2 ---', 'Beta'], lines
    end

    it 'is the single source extract joins, so the two shapes cannot drift' do
      bytes = build_pdf('Alpha', 'Beta')
      assert_equal described_class.extract_lines(StringIO.new(bytes)).to_a.join("\n"),
                   extract(bytes)
    end

    it 'can be consumed partially' do
      # The laziness that matters — pdf-reader parsing pages only on
      # Page#text access — is pdf-reader's documented behavior;
      # extract_paged's early stop is proven in pikuri-core's
      # extractor_spec with an infinite stream. Here we just pin that
      # a partial consumer gets the head without error.
      enum = described_class.extract_lines(StringIO.new(build_pdf('Alpha', 'Beta')))
      assert_equal ['--- Page 1 ---', 'Alpha'], enum.first(2)
    end

    it 'raises Extractor::Error at consumption time on malformed bytes' do
      enum = described_class.extract_lines(StringIO.new('not a pdf at all'))
      err = assert_raises(Pikuri::Extractor::Error) { enum.first }
      assert_includes err.message, 'MalformedPDFError'
    end
  end

  describe '.matches?' do
    it 'claims the %PDF- magic prefix regardless of content-type' do
      assert described_class.matches?(sample: '%PDF-1.4 etc'.b, content_type: nil)
      assert described_class.matches?(sample: '%PDF-1.4 etc'.b, content_type: 'text/plain')
    end

    it 'claims an application/pdf content-type regardless of the sample' do
      assert described_class.matches?(sample: ''.b, content_type: 'application/pdf')
    end

    it 'declines everything else' do
      refute described_class.matches?(sample: 'plain text'.b, content_type: nil)
      refute described_class.matches?(sample: 'plain text'.b, content_type: 'text/html')
    end
  end

  describe '.register' do
    after { Pikuri::Extractor.registry.delete(described_class) }

    it 'inserts at the front of the registry, ahead of HTML' do
      described_class.register
      assert_equal described_class, Pikuri::Extractor.registry.first
    end

    it 'is idempotent and returns self' do
      assert_equal described_class, described_class.register
      before_count = Pikuri::Extractor.registry.length
      described_class.register
      assert_equal before_count, Pikuri::Extractor.registry.length
    end
  end
end
