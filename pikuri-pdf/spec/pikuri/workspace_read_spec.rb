# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'pathname'

# The workspace +read+ tool driving registered PDF extraction
# end-to-end: cat-n numbering over the marker lines, the PDF-worded
# trailers, the scanned-image hint. The tool's kind-keyed rendering
# lives in pikuri-workspace; the extractor that produces the +:pdf+
# kind lives here — so the integration of the two is this gem's
# concern (these specs moved here from pikuri-workspace when the PDF
# extractor left pikuri-core). pikuri-workspace is a test-only
# dependency, resolved through the monorepo's top-level Gemfile.
require 'pikuri-workspace'

RSpec.describe 'Workspace::Read on a registered PDF extractor' do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-pdf-read-')).realpath }
  let(:workspace) { Pikuri::Workspace::Filesystem.new(project_root: root) }

  before { Pikuri::Extractors::PDF.register }

  after do
    Pikuri::Extractor.registry.delete(Pikuri::Extractors::PDF)
    FileUtils.rm_rf(root)
  end

  def read(path, offset: 1, limit: 2000)
    Pikuri::Workspace::Read.read(workspace: workspace, path: path, offset: offset, limit: limit)
  end

  def write_pdf(rel, *page_texts)
    path = root + rel
    File.binwrite(path, build_pdf(*page_texts))
    path
  end

  it 'extracts a one-page PDF with a page marker followed by the text' do
    write_pdf('doc.pdf', 'Hello PDF')

    result = read('doc.pdf')

    assert_includes result, "     1\t--- Page 1 ---"
    assert_includes result, "     2\tHello PDF"
    assert_includes result, '(End of PDF - total 2 lines)'
  end

  it 'emits one --- Page N --- marker per page, line numbering is continuous' do
    write_pdf('multi.pdf', 'Alpha content', 'Beta content')

    result = read('multi.pdf')

    assert_includes result, "     1\t--- Page 1 ---"
    assert_includes result, "     2\tAlpha content"
    assert_includes result, "     3\t--- Page 2 ---"
    assert_includes result, "     4\tBeta content"
    assert_includes result, '(End of PDF - total 4 lines)'
  end

  it 'applies line-based offset and limit to the extracted stream' do
    write_pdf('paged.pdf', 'Alpha content', 'Beta content')

    result = read('paged.pdf', offset: 3)

    refute_includes result, 'Alpha content'
    assert_includes result, "     3\t--- Page 2 ---"
    assert_includes result, "     4\tBeta content"
  end

  it 'caps at limit and emits a continuation hint without claiming a total' do
    # PDF extraction is consumed lazily (extract_lines): page 2 is
    # never parsed, so the trailer cannot claim an exact total.
    write_pdf('cap.pdf', 'Alpha content', 'Beta content')

    result = read('cap.pdf', limit: 2)

    assert_includes result, "     1\t--- Page 1 ---"
    assert_includes result, "     2\tAlpha content"
    refute_includes result, 'Page 2'
    assert_includes result, '(Showing PDF lines 1-2. Use offset=3 to continue.)'
  end

  it 'reports an empty PDF with an LLM-actionable hint' do
    # build_pdf('') emits a zero-length Tj, which pdf-reader collapses
    # to empty page text — the no-extractable-text branch.
    write_pdf('blank.pdf', '')

    result = read('blank.pdf')

    assert_equal '(PDF has no extractable text; likely scanned image content)', result
  end

  it 'surfaces malformed PDF bytes as an Error string the model can react to' do
    # Magic-prefix routes to the PDF extractor, but pdf-reader rejects the body.
    File.binwrite(root + 'broken.pdf', "%PDF-1.4\nthis is not a valid pdf body")

    result = read('broken.pdf')

    # Message comes from the shared FileType.read_as_text_paged
    # (capital "Cannot", resolved path — same as read_as_text's own
    # contract), surfaced verbatim behind the "Error: " prefix.
    assert result.start_with?('Error: Cannot extract text from'),
           "expected PDF error, got #{result.inspect}"
    assert_includes result, 'broken.pdf'
    assert_includes result, 'MalformedPDFError'
  end

  it 'errors when offset is past the extracted stream' do
    write_pdf('short.pdf', 'one liner')

    result = read('short.pdf', offset: 99)

    assert_equal 'Error: offset 99 is beyond end of file (2 lines total)', result
  end
end
