# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Tool::Read do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-read-root-')).realpath }
  let(:workspace) { Pikuri::Tool::Workspace::Cwd.new(root: root) }
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
      long = 'x' * (Pikuri::Tool::Read::MAX_LINE_LENGTH + 50)
      write_file('long.txt', "#{long}\nshort\n")

      result = described_class.read(workspace: workspace, path: 'long.txt', offset: 1, limit: 2000)

      assert_includes result, Pikuri::Tool::Read::LINE_TRUNCATION_MARKER
      # The truncated payload should be exactly MAX_LINE_LENGTH x's followed
      # by the marker (no x's bleed past the cap).
      assert_includes result, 'x' * Pikuri::Tool::Read::MAX_LINE_LENGTH + Pikuri::Tool::Read::LINE_TRUNCATION_MARKER
      refute_includes result, 'x' * (Pikuri::Tool::Read::MAX_LINE_LENGTH + 1) + '.'
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

      assert_includes result, "Output capped at #{Pikuri::Tool::Read::MAX_BYTES_LABEL}."
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
