# frozen_string_literal: true

require 'stringio'
require 'tmpdir'
require 'fileutils'
require 'pathname'

# Exercise the extractor *through the registry front doors* —
# +Extractor.extract+ and the +FileType.read_as_text+ /
# +read_as_text_paged+ path wrappers — with {Pikuri::Extractors::PDF}
# registered, the wiring a host script sets up. These blocks lived in
# pikuri-core's specs while the PDF extractor was bundled there; they
# moved here with it.
RSpec.describe Pikuri::Extractors::PDF, 'registered' do
  before { described_class.register }
  after  { Pikuri::Extractor.registry.delete(described_class) }

  describe 'Extractor.extract routing' do
    it 'claims a %PDF- magic body even under a lying text content-type' do
      # Garbage after the magic prefix: reaching the PDF parse error
      # proves the PDF extractor (not the text passthrough) claimed it.
      err = assert_raises(Pikuri::Extractor::Error) do
        Pikuri::Extractor.extract(StringIO.new("%PDF-1.4\nnot really a pdf"),
                                  content_type: 'text/plain')
      end
      assert_includes err.message, 'PDF rendering failed'
    end
  end

  describe 'FileType path wrappers' do
    let(:root) { Pathname.new(Dir.mktmpdir('pikuri-pdf-ft-')).realpath }

    after { FileUtils.rm_rf(root) }

    def write_pdf(rel, *page_texts)
      path = root + rel
      File.binwrite(path, build_pdf(*page_texts))
      path
    end

    describe '.read_as_text' do
      it 'extracts text from a single-page PDF, headed by its page marker' do
        path = write_pdf('doc.pdf', 'Hello PDF')
        assert_equal "--- Page 1 ---\nHello PDF", Pikuri::FileType.read_as_text(path)
      end

      it 'emits one marker-headed block per page — same shape the Read tools window' do
        path = write_pdf('multi.pdf', 'Alpha', 'Beta')
        assert_equal "--- Page 1 ---\nAlpha\n--- Page 2 ---\nBeta",
                     Pikuri::FileType.read_as_text(path)
      end

      it 'returns the empty String for a PDF with no extractable text' do
        # Zero pages → no text. Workspace::Read returns a hint string
        # for the LLM; read_as_text returns '' and lets the caller
        # decide (an indexer simply gets no text).
        path = write_pdf('empty.pdf')
        assert_equal '', Pikuri::FileType.read_as_text(path)
      end

      it 'raises a RuntimeError with the path for a malformed PDF' do
        # PDF magic but garbage afterward; pdf-reader rejects this.
        path = root + 'broken.pdf'
        File.binwrite(path, "%PDF-1.4\nnot really a pdf\n".b)
        err = assert_raises(RuntimeError) { Pikuri::FileType.read_as_text(path) }
        assert_match(/broken\.pdf/, err.message)
      end
    end

    describe '.read_as_text_paged' do
      it 'emits --- Page N --- markers and a known total at EOF' do
        path = write_pdf('multi.pdf', 'Alpha content', 'Beta content')
        page = Pikuri::FileType.read_as_text_paged(path)

        assert_equal :pdf, page.kind
        assert_includes page.lines, '--- Page 1 ---'
        assert_includes page.lines, '--- Page 2 ---'
        assert_equal 4, page.total_lines
        refute page.more
      end

      it 'stops parsing when the window fills, leaving total_lines nil' do
        # PDF's extract_lines stream is consumed lazily; counting
        # the tail would mean parsing every remaining page, so the
        # total stays unknown when the window stops the read early.
        path = write_pdf('cap.pdf', 'Alpha content', 'Beta content')
        page = Pikuri::FileType.read_as_text_paged(path, offset: 1, limit: 2)

        assert_equal ['--- Page 1 ---', 'Alpha content'], page.lines
        assert page.more
        assert_nil page.total_lines
      end

      it 'reports a text-free PDF as zero lines, total 0' do
        path = write_pdf('blank.pdf', '')
        page = Pikuri::FileType.read_as_text_paged(path)

        assert_empty page.lines
        assert_equal 0, page.total_lines
      end

      it 'raises a RuntimeError with the path on a malformed PDF' do
        path = root + 'broken.pdf'
        File.binwrite(path, "%PDF-1.4\nnot really a pdf\n".b)
        err = assert_raises(RuntimeError) { Pikuri::FileType.read_as_text_paged(path) }
        assert_match(/broken\.pdf/, err.message)
      end
    end
  end
end
