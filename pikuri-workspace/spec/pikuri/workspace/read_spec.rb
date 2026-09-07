# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Read do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-read-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
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

      result = described_class.read(workspace: workspace, path: 'hello.txt', offset: 1, limit: 2000).to_s

      expected = "     1\talpha\n     2\tbeta\n     3\tgamma\n\n(End of file - total 3 lines)"
      assert_equal expected, result
    end

    it 'preserves trailing whitespace on individual lines' do
      write_file('trail.txt', "alpha  \nbeta\n")

      result = described_class.read(workspace: workspace, path: 'trail.txt', offset: 1, limit: 2000).to_s

      assert_includes result, "     1\talpha  "
    end
  end

  describe 'offset / limit' do
    it 'skips the first offset-1 lines' do
      write_file('skip.txt', (1..5).map { |n| "line #{n}" }.join("\n") + "\n")

      result = described_class.read(workspace: workspace, path: 'skip.txt', offset: 3, limit: 2000).to_s

      assert_includes result, "     3\tline 3"
      assert_includes result, "     5\tline 5"
      refute_includes result, 'line 2'
    end

    it 'caps at limit and emits an actionable continuation marker' do
      write_file('big.txt', (1..10).map { |n| "L#{n}" }.join("\n") + "\n")

      result = described_class.read(workspace: workspace, path: 'big.txt', offset: 1, limit: 3).to_s

      assert_includes result, "     3\tL3"
      refute_includes result, 'L4'
      assert_includes result, '(Showing lines 1-3 of 10. Use offset=4 to continue.)'
    end

    it 'returns an error when offset is past EOF' do
      write_file('short.txt', "one\ntwo\n")

      result = described_class.read(workspace: workspace, path: 'short.txt', offset: 99, limit: 2000).to_s

      assert_equal 'Error: offset 99 is beyond end of file (2 lines total)', result
    end

    it 'rejects offset < 1' do
      write_file('any.txt', "x\n")

      result = described_class.read(workspace: workspace, path: 'any.txt', offset: 0, limit: 2000).to_s

      assert_equal 'Error: offset must be >= 1, got 0', result
    end

    it 'rejects limit < 1' do
      write_file('any.txt', "x\n")

      result = described_class.read(workspace: workspace, path: 'any.txt', offset: 1, limit: 0).to_s

      assert_equal 'Error: limit must be >= 1, got 0', result
    end
  end

  describe 'empty file' do
    it 'returns "(Empty file)" rather than an awkward EOF marker' do
      write_file('empty.txt', '')

      result = described_class.read(workspace: workspace, path: 'empty.txt', offset: 1, limit: 2000).to_s

      assert_equal '(Empty file)', result
    end
  end

  describe 'long-line truncation' do
    it 'truncates lines longer than MAX_LINE_LENGTH and appends the marker' do
      long = 'x' * (Pikuri::Workspace::Read::MAX_LINE_LENGTH + 50)
      write_file('long.txt', "#{long}\nshort\n")

      result = described_class.read(workspace: workspace, path: 'long.txt', offset: 1, limit: 2000).to_s

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

      result = described_class.read(workspace: workspace, path: 'bulky.txt', offset: 1, limit: 2000).to_s

      assert_includes result, "Output capped at #{Pikuri::Workspace::Read::MAX_BYTES_LABEL}."
      assert_match(/Use offset=\d+ to continue\./, result)
    end
  end

  describe 'refusals' do
    it 'refuses directories but hands back their entries rather than dead-ending' do
      FileUtils.mkdir_p(root + 'subdir/nested')
      write_file('subdir/a.rb', 'x' * 1024)

      result = described_class.read(workspace: workspace, path: 'subdir', offset: 1, limit: 2000).to_s

      assert_equal "Error: subdir is a directory, not a file. It contains " \
                   "(directories end with `/`):\nnested/  [empty]\na.rb  1.0K", result
    end

    it 'says so plainly when the directory is empty' do
      FileUtils.mkdir_p(root + 'hollow')

      result = described_class.read(workspace: workspace, path: 'hollow', offset: 1, limit: 2000).to_s

      assert_equal 'Error: hollow is a directory, not a file. It is empty.', result
    end

    # The refusal returns before mark_read. Free today, but a refactor that
    # moved the ledger write earlier would silently clear the read-before-edit
    # gate for a path nobody read.
    it 'does not mark the read ledger for a directory' do
      FileUtils.mkdir_p(root + 'subdir')

      described_class.read(workspace: workspace, path: 'subdir', offset: 1, limit: 2000)

      refute workspace.read?(root + 'subdir')
    end

    it 'refuses missing files' do
      result = described_class.read(workspace: workspace, path: 'nope.txt', offset: 1, limit: 2000).to_s

      assert_equal 'Error: file not found: nope.txt', result
    end

    it 'refuses binary files (null byte in sample)' do
      write_file('bin.dat', "abc\x00def\x00ghi")

      result = described_class.read(workspace: workspace, path: 'bin.dat', offset: 1, limit: 2000).to_s

      assert_equal 'Error: cannot read binary file: bin.dat', result
    end

    it 'refuses files dense in control characters' do
      # 50% non-printable: alternating 'a' and a control char 0x01.
      content = (['a', "\x01"] * 200).join
      write_file('ctrl.dat', content)

      result = described_class.read(workspace: workspace, path: 'ctrl.dat', offset: 1, limit: 2000).to_s

      assert_equal 'Error: cannot read binary file: ctrl.dat', result
    end

    it 'allows UTF-8 multi-byte text (continuation bytes are not non-printable)' do
      write_file('utf8.txt', "héllo\nwörld\n")

      result = described_class.read(workspace: workspace, path: 'utf8.txt', offset: 1, limit: 2000).to_s

      assert_includes result, "     1\théllo"
      assert_includes result, "     2\twörld"
    end

    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = described_class.read(workspace: workspace, path: '../escape.txt', offset: 1, limit: 2000).to_s

      assert result.start_with?('Error: path'), "expected workspace error, got #{result.inspect}"
      assert_includes result, 'is outside the workspace'
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a cat-n observation for the LLM' do
      write_file('integ.txt', "one\ntwo\nthree\n")

      result = tool.run('path' => 'integ.txt').to_s

      assert_includes result, "     1\tone"
      assert_includes result, '(End of file - total 3 lines)'
    end

    it 'reports unknown parameters via the Parameters validator' do
      write_file('integ.txt', "x\n")

      result = tool.run('path' => 'integ.txt', 'depth' => 3).to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'depth'
    end

    it 'reports a missing required path' do
      result = tool.run({}).to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'path'
    end
  end

  # PDF reads (page markers, PDF-worded trailers, the scanned-image
  # hint) are exercised end-to-end in pikuri-pdf's specs — the
  # extractor that produces the :pdf kind lives there, and without it
  # registered a .pdf file hits the plain binary refusal below.

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

    it 'answers a Result whose content is a RubyLLM::Content with the file attached' do
      path = write_image('shot.png', PNG_MAGIC)

      result = described_class.read(workspace: workspace, path: 'shot.png', offset: 1, limit: 2000)

      assert result.attachment?, "expected an attachment Result, got #{result.inspect}"
      content = result.content
      assert_kind_of RubyLLM::Content, content
      assert_equal 1, content.attachments.length
      attachment = content.attachments.first
      assert_equal path.to_s, attachment.source.to_s
      assert_equal 'image/png', attachment.mime_type
      assert_includes content.text, 'Read image: shot.png'
      assert_includes content.text, "(#{path.size} bytes, image/png)"
    end

    it 'refuses images larger than MAX_IMAGE_BYTES with an Error string the model can react to' do
      path = root + 'huge.png'
      File.binwrite(path, PNG_MAGIC + ("\x00".b * (Pikuri::Workspace::Read::MAX_IMAGE_BYTES + 1)))

      result = described_class.read(workspace: workspace, path: 'huge.png', offset: 1, limit: 2000).to_s

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

      assert_kind_of RubyLLM::Content, result.content
    end

    it 'leaves non-image binaries (no magic) on the binary refusal path' do
      # Plausible ZIP magic — not an image.
      write_image('thing.zip', "PK\x03\x04".b, 32)

      result = described_class.read(workspace: workspace, path: 'thing.zip', offset: 1, limit: 2000).to_s

      assert_equal 'Error: cannot read binary file: thing.zip', result
    end
  end

  describe 'parameters schema' do
    it 'advertises path as required and offset/limit as optional integers' do
      schema = tool.parameters.to_openai

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

  describe 'read-ledger marking' do
    it 'marks the path read in the workspace ledger on a successful read' do
      path = write_file('seen.txt', "x\n")
      refute workspace.read?(path), 'precondition: not yet read'

      described_class.read(workspace: workspace, path: 'seen.txt', offset: 1, limit: 2000)

      assert workspace.read?(path), 'expected a successful read to mark the ledger'
    end

    it 'does not mark the path read when the file is missing' do
      result = described_class.read(workspace: workspace, path: 'absent.txt', offset: 1, limit: 2000).to_s

      assert result.start_with?('Error: file not found'), result
      refute workspace.read?(root + 'absent.txt')
    end
  end
end
