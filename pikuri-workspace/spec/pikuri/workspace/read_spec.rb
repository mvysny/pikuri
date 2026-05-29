# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Read do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-read-root-')).realpath }
  let(:workspace) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:tool)      { described_class.new(workspace: workspace) }

  after { FileUtils.rm_rf(root) }

  def write_file(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  describe '.read happy path' do
    it 'returns cat-n formatted content followed by an EOF trailer' do
      write_file('hello.txt', "alpha\nbeta\ngamma\n")

      result = described_class.read(workspace: workspace, path: 'hello.txt', offset: 1, limit: 2000)

      expected = "     1\talpha\n     2\tbeta\n     3\tgamma\n\n(End of file - total 3 lines)"
      assert_equal expected, result
    end

    it 'preserves trailing whitespace on individual lines' do
      write_file('trail.txt', "alpha  \nbeta\n")

      result = described_class.read(workspace: workspace, path: 'trail.txt', offset: 1, limit: 2000)

      assert_includes result, "     1\talpha  "
    end
  end

  describe 'offset / limit' do
    it 'skips the first offset-1 lines' do
      write_file('skip.txt', (1..5).map { |n| "line #{n}" }.join("\n") + "\n")

      result = described_class.read(workspace: workspace, path: 'skip.txt', offset: 3, limit: 2000)

      assert_includes result, "     3\tline 3"
      assert_includes result, "     5\tline 5"
      refute_includes result, 'line 2'
    end

    it 'caps at limit and emits an actionable continuation marker' do
      write_file('big.txt', (1..10).map { |n| "L#{n}" }.join("\n") + "\n")

      result = described_class.read(workspace: workspace, path: 'big.txt', offset: 1, limit: 3)

      assert_includes result, "     3\tL3"
      refute_includes result, 'L4'
      assert_includes result, '(Showing lines 1-3 of 10. Use offset=4 to continue.)'
    end

    it 'returns an error when offset is past EOF' do
      write_file('short.txt', "one\ntwo\n")

      result = described_class.read(workspace: workspace, path: 'short.txt', offset: 99, limit: 2000)

      assert_equal 'Error: offset 99 is beyond end of file (2 lines total)', result
    end

    it 'rejects offset < 1' do
      write_file('any.txt', "x\n")

      result = described_class.read(workspace: workspace, path: 'any.txt', offset: 0, limit: 2000)

      assert_equal 'Error: offset must be >= 1, got 0', result
    end

    it 'rejects limit < 1' do
      write_file('any.txt', "x\n")

      result = described_class.read(workspace: workspace, path: 'any.txt', offset: 1, limit: 0)

      assert_equal 'Error: limit must be >= 1, got 0', result
    end
  end

  describe 'empty file' do
    it 'returns "(Empty file)" rather than an awkward EOF marker' do
      write_file('empty.txt', '')

      result = described_class.read(workspace: workspace, path: 'empty.txt', offset: 1, limit: 2000)

      assert_equal '(Empty file)', result
    end
  end

  describe 'long-line truncation' do
    it 'truncates lines longer than MAX_LINE_LENGTH and appends the marker' do
      long = 'x' * (Pikuri::Workspace::Read::MAX_LINE_LENGTH + 50)
      write_file('long.txt', "#{long}\nshort\n")

      result = described_class.read(workspace: workspace, path: 'long.txt', offset: 1, limit: 2000)

      assert_includes result, Pikuri::Workspace::Read::LINE_TRUNCATION_MARKER
      # The truncated payload should be exactly MAX_LINE_LENGTH x's followed
      # by the marker (no x's bleed past the cap).
      assert_includes result, 'x' * Pikuri::Workspace::Read::MAX_LINE_LENGTH + Pikuri::Workspace::Read::LINE_TRUNCATION_MARKER
      refute_includes result, 'x' * (Pikuri::Workspace::Read::MAX_LINE_LENGTH + 1) + '.'
      assert_includes result, "     2\tshort"
    end
  end

  describe 'byte cap' do
    it 'stops mid-file when MAX_BYTES is reached and reports the cap' do
      # Each line is ~1 KB; ~80 lines should comfortably exceed 50 KB.
      bulky_line = 'a' * 1023
      content = (1..80).map { bulky_line }.join("\n") + "\n"
      write_file('bulky.txt', content)

      result = described_class.read(workspace: workspace, path: 'bulky.txt', offset: 1, limit: 2000)

      assert_includes result, "Output capped at #{Pikuri::Workspace::Read::MAX_BYTES_LABEL}."
      assert_match(/Use offset=\d+ to continue\./, result)
    end
  end

  describe 'refusals' do
    it 'refuses directories and points at the glob tool' do
      FileUtils.mkdir_p(root + 'subdir')

      result = described_class.read(workspace: workspace, path: 'subdir', offset: 1, limit: 2000)

      assert_equal 'Error: subdir is a directory; use the glob tool to list files.', result
    end

    it 'refuses missing files' do
      result = described_class.read(workspace: workspace, path: 'nope.txt', offset: 1, limit: 2000)

      assert_equal 'Error: file not found: nope.txt', result
    end

    it 'refuses binary files (null byte in sample)' do
      write_file('bin.dat', "abc\x00def\x00ghi")

      result = described_class.read(workspace: workspace, path: 'bin.dat', offset: 1, limit: 2000)

      assert_equal 'Error: cannot read binary file: bin.dat', result
    end

    it 'refuses files dense in control characters' do
      # 50% non-printable: alternating 'a' and a control char 0x01.
      content = (['a', "\x01"] * 200).join
      write_file('ctrl.dat', content)

      result = described_class.read(workspace: workspace, path: 'ctrl.dat', offset: 1, limit: 2000)

      assert_equal 'Error: cannot read binary file: ctrl.dat', result
    end

    it 'allows UTF-8 multi-byte text (continuation bytes are not non-printable)' do
      write_file('utf8.txt', "héllo\nwörld\n")

      result = described_class.read(workspace: workspace, path: 'utf8.txt', offset: 1, limit: 2000)

      assert_includes result, "     1\théllo"
      assert_includes result, "     2\twörld"
    end

    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = described_class.read(workspace: workspace, path: '../escape.txt', offset: 1, limit: 2000)

      assert result.start_with?('Error: path'), "expected workspace error, got #{result.inspect}"
      assert_includes result, 'is outside the workspace'
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a cat-n observation for the LLM' do
      write_file('integ.txt', "one\ntwo\nthree\n")

      result = tool.run('path' => 'integ.txt')

      assert_includes result, "     1\tone"
      assert_includes result, '(End of file - total 3 lines)'
    end

    it 'reports unknown parameters via the Parameters validator' do
      write_file('integ.txt', "x\n")

      result = tool.run('path' => 'integ.txt', 'depth' => 3)

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'depth'
    end

    it 'reports a missing required path' do
      result = tool.run({})

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'path'
    end
  end

  describe 'PDF extraction' do
    # In-memory PDF builder — same approach as the scraper/pdf_spec helper:
    # emit the smallest valid PDF +pdf-reader+ accepts, one Tj string-show op
    # per page, computing object byte offsets as we append so the xref table
    # stays correct. Variable arity drives the page count.
    def build_pdf(*page_texts)
      out = +"%PDF-1.4\n"
      offsets = []
      add_obj = lambda do |body|
        offsets << out.bytesize
        out << "#{offsets.size} 0 obj\n#{body}\nendobj\n"
      end

      page_count = page_texts.length
      # Layout: 1=Catalog, 2=Pages, then per page (Page, Content) pairs,
      # last object = Font.
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

    def write_pdf(rel, *page_texts)
      path = root + rel
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, build_pdf(*page_texts))
      path
    end

    it 'extracts a one-page PDF with a page marker followed by the text' do
      write_pdf('doc.pdf', 'Hello PDF')

      result = described_class.read(workspace: workspace, path: 'doc.pdf', offset: 1, limit: 2000)

      assert_includes result, "     1\t--- Page 1 ---"
      assert_includes result, "     2\tHello PDF"
      assert_includes result, '(End of PDF - total 2 lines)'
    end

    it 'emits one --- Page N --- marker per page, line numbering is continuous' do
      write_pdf('multi.pdf', 'Alpha content', 'Beta content')

      result = described_class.read(workspace: workspace, path: 'multi.pdf', offset: 1, limit: 2000)

      assert_includes result, "     1\t--- Page 1 ---"
      assert_includes result, "     2\tAlpha content"
      assert_includes result, "     3\t--- Page 2 ---"
      assert_includes result, "     4\tBeta content"
      assert_includes result, '(End of PDF - total 4 lines)'
    end

    it 'applies line-based offset and limit to the extracted stream' do
      write_pdf('paged.pdf', 'Alpha content', 'Beta content')

      result = described_class.read(workspace: workspace, path: 'paged.pdf', offset: 3, limit: 2000)

      refute_includes result, 'Alpha content'
      assert_includes result, "     3\t--- Page 2 ---"
      assert_includes result, "     4\tBeta content"
    end

    it 'caps at limit and emits a continuation hint without claiming a total' do
      write_pdf('cap.pdf', 'Alpha content', 'Beta content')

      result = described_class.read(workspace: workspace, path: 'cap.pdf', offset: 1, limit: 2)

      assert_includes result, "     1\t--- Page 1 ---"
      assert_includes result, "     2\tAlpha content"
      refute_includes result, 'Page 2'
      assert_includes result, '(Showing PDF lines 1-2. Use offset=3 to continue.)'
    end

    it 'reports an empty PDF with an LLM-actionable hint' do
      # build_pdf('') emits a zero-length Tj, which pdf-reader collapses
      # to empty page text — the no-extractable-text branch.
      write_pdf('blank.pdf', '')

      result = described_class.read(workspace: workspace, path: 'blank.pdf', offset: 1, limit: 2000)

      assert_equal '(PDF has no extractable text; likely scanned image content)', result
    end

    it 'surfaces malformed PDF bytes as an Error string the model can react to' do
      # Magic-prefix routes to the PDF extractor, but pdf-reader rejects the body.
      path = root + 'broken.pdf'
      File.binwrite(path, "%PDF-1.4\nthis is not a valid pdf body")

      result = described_class.read(workspace: workspace, path: 'broken.pdf', offset: 1, limit: 2000)

      # Message now comes from the shared FileType.read_as_text_paged
      # (capital "Cannot", resolved path — same as read_as_text's own
      # contract), surfaced verbatim behind the "Error: " prefix.
      assert result.start_with?('Error: Cannot extract PDF text from'),
             "expected PDF error, got #{result.inspect}"
      assert_includes result, 'broken.pdf'
      assert_includes result, 'MalformedPDFError'
    end

    it 'errors when offset is past the extracted stream' do
      write_pdf('short.pdf', 'one liner')

      result = described_class.read(workspace: workspace, path: 'short.pdf', offset: 99, limit: 2000)

      assert_equal 'Error: offset 99 is beyond end of file (2 lines total)', result
    end
  end

  describe 'image attachments' do
    # Per-format magic-byte detection is covered in
    # spec/pikuri/file_type_spec.rb. These specs cover Read's routing
    # contract: that a sniff-recognised image flows through to a
    # RubyLLM::Content with the right metadata, ordering ahead of the
    # binary refusal, and the 5 MB size cap.
    PNG_MAGIC = "\x89PNG\r\n\x1a\n".b

    def write_image(rel, magic, padding_bytes = 32)
      path = root + rel
      FileUtils.mkdir_p(path.dirname)
      File.binwrite(path, magic + ("\x00".b * padding_bytes))
      path
    end

    it 'returns a RubyLLM::Content with the file attached and a metadata note' do
      path = write_image('shot.png', PNG_MAGIC)

      result = described_class.read(workspace: workspace, path: 'shot.png', offset: 1, limit: 2000)

      assert_kind_of RubyLLM::Content, result
      assert_equal 1, result.attachments.length
      attachment = result.attachments.first
      assert_equal path.to_s, attachment.source.to_s
      assert_equal 'image/png', attachment.mime_type
      assert_includes result.text, 'Read image: shot.png'
      assert_includes result.text, "(#{path.size} bytes, image/png)"
    end

    it 'refuses images larger than MAX_IMAGE_BYTES with an Error string the model can react to' do
      path = root + 'huge.png'
      File.binwrite(path, PNG_MAGIC + ("\x00".b * (Pikuri::Workspace::Read::MAX_IMAGE_BYTES + 1)))

      result = described_class.read(workspace: workspace, path: 'huge.png', offset: 1, limit: 2000)

      assert_kind_of String, result
      assert result.start_with?('Error: image too large to inline: huge.png is'),
             "expected size refusal, got #{result.inspect}"
      assert_includes result, Pikuri::Workspace::Read::MAX_IMAGE_BYTES_LABEL
    end

    it 'routes images ahead of the binary-content refusal' do
      # PNG content is dense in NUL bytes — would otherwise be refused
      # by FileType.binary?. The mime-detection branch must run first.
      write_image('nul.png', PNG_MAGIC, 1024)

      result = described_class.read(workspace: workspace, path: 'nul.png', offset: 1, limit: 2000)

      assert_kind_of RubyLLM::Content, result
    end

    it 'leaves non-image binaries (no magic) on the binary refusal path' do
      # Plausible ZIP magic — not an image.
      write_image('thing.zip', "PK\x03\x04".b, 32)

      result = described_class.read(workspace: workspace, path: 'thing.zip', offset: 1, limit: 2000)

      assert_equal 'Error: cannot read binary file: thing.zip', result
    end
  end

  describe 'parameters schema' do
    it 'advertises path as required and offset/limit as optional integers' do
      schema = tool.parameters.to_h

      assert_equal %w[path], schema[:required]
      assert_equal 'string', schema[:properties][:path][:type]
      assert_equal 'integer', schema[:properties][:offset][:type]
      assert_equal 'integer', schema[:properties][:limit][:type]
    end

    it 'wires through to_ruby_llm_tool under the "read" name' do
      klass = tool.to_ruby_llm_tool

      assert_equal 'read', klass.name
    end
  end
end
