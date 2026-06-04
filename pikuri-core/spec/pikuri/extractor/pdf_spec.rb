# frozen_string_literal: true

require 'stringio'

# Drive +Extractor::PDF.extract+ against in-memory PDFs built by the
# helper below rather than checking a binary fixture into the repo.
# The helper emits the smallest valid PDF +pdf-reader+ will accept —
# one page per text, Helvetica, a single +Tj+ string-show op — so the
# assertions exercise the real extraction path end-to-end.
RSpec.describe Pikuri::Extractor::PDF, '.extract' do
  # Build a PDF that prints each of +page_texts+ on its own page.
  # Returns the raw bytes ready to wrap in a StringIO. Object byte
  # offsets are computed as we append, so the xref table is always
  # correct.
  def build_pdf(*page_texts)
    out = +"%PDF-1.4\n"
    offsets = []
    add_obj = lambda do |body|
      offsets << out.bytesize
      out << "#{offsets.size} 0 obj\n#{body}\nendobj\n"
    end

    page_count = page_texts.length
    font_obj_num = 2 + page_count * 2 + 1

    add_obj.call('<< /Type /Catalog /Pages 2 0 R >>')
    page_refs = (0...page_count).map { |i| "#{3 + i * 2} 0 R" }
    add_obj.call("<< /Type /Pages /Kids [#{page_refs.join(' ')}] /Count #{page_count} >>")

    page_texts.each_with_index do |text, i|
      content_obj_num = 3 + i * 2 + 1
      add_obj.call("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " \
                   "/Contents #{content_obj_num} 0 R /Resources << /Font << /F1 #{font_obj_num} 0 R >> >> >>")
      stream = "BT /F1 12 Tf 100 700 Td (#{text}) Tj ET"
      add_obj.call("<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream")
    end

    add_obj.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

    xref_pos = out.bytesize
    out << "xref\n0 #{offsets.size + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{offsets.size + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_pos}\n%%EOF\n"
    out
  end

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
end
