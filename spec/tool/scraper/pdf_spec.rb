# frozen_string_literal: true

require 'tool/scraper/pdf'

# Drive +PDF.extract+ against in-memory PDFs built by the helper below
# rather than checking a binary fixture into the repo. The helper
# emits the smallest valid PDF +pdf-reader+ will accept — one page,
# Helvetica, a single +Tj+ string-show op — so the assertion exercises
# the real extraction path end-to-end.
RSpec.describe Tool::Scraper::PDF, '.extract' do
  # Build a 1-page PDF that prints +text+ at a fixed position. Returns
  # the raw bytes ready to feed into +PDF.extract+. Object byte offsets
  # are computed as we append, so the xref table is always correct.
  def build_pdf(text)
    out = +"%PDF-1.4\n"
    offsets = []

    add_obj = lambda do |body|
      offsets << out.bytesize
      out << "#{offsets.size} 0 obj\n#{body}\nendobj\n"
    end

    add_obj.call('<< /Type /Catalog /Pages 2 0 R >>')
    add_obj.call('<< /Type /Pages /Kids [3 0 R] /Count 1 >>')
    add_obj.call('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] ' \
                 '/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>')

    stream = "BT /F1 12 Tf 100 700 Td (#{text}) Tj ET"
    add_obj.call("<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream")
    add_obj.call('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')

    xref_pos = out.bytesize
    out << "xref\n0 #{offsets.size + 1}\n"
    out << "0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{offsets.size + 1} /Root 1 0 R >>\n"
    out << "startxref\n#{xref_pos}\n%%EOF\n"
    out
  end

  it 'returns the page text from a one-page PDF' do
    bytes = build_pdf('Hello PDF')
    assert_equal 'Hello PDF', described_class.extract(bytes)
  end

  it 'returns an empty string when the PDF carries no extractable text' do
    # Same shape as +build_pdf+ but with an empty content stream — pdf-reader
    # parses the document fine, the page just has nothing to show. We choose
    # to return "" rather than raise so the caller's cache stores a stable
    # result and the LLM can observe the empty body.
    bytes = build_pdf('')
    # "()" Tj is a zero-length text show; pdf-reader collapses it to "".
    assert_equal '', described_class.extract(bytes)
  end

  it 'raises FetchError on malformed PDF bytes' do
    err = assert_raises(Tool::Scraper::FetchError) { described_class.extract('not a pdf at all') }
    assert_includes err.message, 'PDF rendering failed'
    assert_includes err.message, 'MalformedPDFError'
  end
end
