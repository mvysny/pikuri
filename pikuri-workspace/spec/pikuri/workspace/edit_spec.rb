# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Edit do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-edit-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
  let(:tool)       { described_class.new(workspace: workspace) }

  after { FileUtils.rm_rf(root) }

  # Create a file AND mark it read in the workspace ledger — the common
  # fixture is "a file the model has already read", so it clears the
  # read-before-edit gate. Tests that exercise the gate itself use
  # +create_unread+ instead.
  def write_file(rel, content)
    path = create_unread(rel, content)
    workspace.mark_read(path)
    path
  end

  def create_unread(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, content)
    path
  end

  describe '.edit single replacement' do
    it 'replaces the unique occurrence and returns an observation with the count' do
      write_file('foo.rb', "alpha\nbeta\ngamma\n")

      result = described_class.edit(workspace: workspace, path: 'foo.rb',
                                    old_string: 'beta', new_string: 'BETA',
                                    replace_all: false)

      assert_equal 'Edited foo.rb: replaced 1 occurrence.', result
      assert_equal "alpha\nBETA\ngamma\n", (root + 'foo.rb').binread
    end

    it 'matches multi-line old_string exactly' do
      write_file('m.rb', "def foo\n  bar\nend\n")

      result = described_class.edit(workspace: workspace, path: 'm.rb',
                                    old_string: "def foo\n  bar\nend",
                                    new_string: "def foo\n  baz\nend",
                                    replace_all: false)

      assert_equal 'Edited m.rb: replaced 1 occurrence.', result
      assert_equal "def foo\n  baz\nend\n", (root + 'm.rb').binread
    end

    it 'fails when old_string differs by interior whitespace (no fuzz fallback)' do
      write_file('w.rb', "foo  bar\n") # two spaces between foo and bar on disk

      result = described_class.edit(workspace: workspace, path: 'w.rb',
                                    old_string: 'foo bar', # one space
                                    new_string: 'FOO BAR',
                                    replace_all: false)

      assert result.start_with?('Error: old_string not found'), "expected not-found, got #{result.inspect}"
      assert_equal "foo  bar\n", (root + 'w.rb').binread
    end

    it 'fails on multiple matches without replace_all' do
      write_file('many.txt', "foo\nfoo\nfoo\n")

      result = described_class.edit(workspace: workspace, path: 'many.txt',
                                    old_string: 'foo', new_string: 'bar',
                                    replace_all: false)

      assert result.start_with?('Error: old_string matches 3 times'),
             "expected multi-match error, got #{result.inspect}"
      assert_equal "foo\nfoo\nfoo\n", (root + 'many.txt').binread
    end
  end

  describe '.edit replace_all' do
    it 'replaces every occurrence and counts them' do
      write_file('many.txt', "foo\nfoo\nfoo\n")

      result = described_class.edit(workspace: workspace, path: 'many.txt',
                                    old_string: 'foo', new_string: 'bar',
                                    replace_all: true)

      assert_equal 'Edited many.txt: replaced 3 occurrences.', result
      assert_equal "bar\nbar\nbar\n", (root + 'many.txt').binread
    end

    it 'still works with a single occurrence (reports 1)' do
      write_file('once.txt', 'just once')

      result = described_class.edit(workspace: workspace, path: 'once.txt',
                                    old_string: 'once', new_string: 'twice',
                                    replace_all: true)

      assert_equal 'Edited once.txt: replaced 1 occurrence.', result
      assert_equal 'just twice', (root + 'once.txt').binread
    end
  end

  describe '.edit literal replacement (no gsub interpolation)' do
    it 'writes "\\1" literally rather than treating it as a backreference' do
      write_file('br.txt', 'a Q b')

      described_class.edit(workspace: workspace, path: 'br.txt',
                           old_string: 'Q', new_string: '\\1',
                           replace_all: false)

      assert_equal 'a \\1 b', (root + 'br.txt').binread
    end

    it 'writes "\\&" literally rather than as the matched text' do
      write_file('amp.txt', 'a Q b')

      described_class.edit(workspace: workspace, path: 'amp.txt',
                           old_string: 'Q', new_string: '\\&',
                           replace_all: true)

      assert_equal 'a \\& b', (root + 'amp.txt').binread
    end
  end

  describe '.edit CRLF handling' do
    it 'matches LF old_string against a CRLF file and preserves CRLF on write' do
      write_file('crlf.txt', "line one\r\nline two\r\nline three\r\n")

      result = described_class.edit(workspace: workspace, path: 'crlf.txt',
                                    old_string: 'line two', new_string: 'LINE TWO',
                                    replace_all: false)

      assert_equal 'Edited crlf.txt: replaced 1 occurrence.', result
      assert_equal "line one\r\nLINE TWO\r\nline three\r\n", (root + 'crlf.txt').binread
    end

    it 'matches multi-line LF old_string against a CRLF file and keeps CRLF' do
      write_file('crlf2.txt', "a\r\nb\r\nc\r\n")

      result = described_class.edit(workspace: workspace, path: 'crlf2.txt',
                                    old_string: "a\nb",
                                    new_string: "A\nB",
                                    replace_all: false)

      assert_equal 'Edited crlf2.txt: replaced 1 occurrence.', result
      assert_equal "A\r\nB\r\nc\r\n", (root + 'crlf2.txt').binread
    end

    it 'leaves LF files as LF' do
      write_file('lf.txt', "a\nb\nc\n")

      described_class.edit(workspace: workspace, path: 'lf.txt',
                           old_string: 'b', new_string: 'B',
                           replace_all: false)

      assert_equal "a\nB\nc\n", (root + 'lf.txt').binread
    end

    it 'accepts CRLF in old_string against a CRLF file (symmetric normalization)' do
      write_file('sym.txt', "x\r\ny\r\nz\r\n")

      described_class.edit(workspace: workspace, path: 'sym.txt',
                           old_string: "x\r\ny",
                           new_string: "X\r\nY",
                           replace_all: false)

      assert_equal "X\r\nY\r\nz\r\n", (root + 'sym.txt').binread
    end
  end

  describe '.edit refusals' do
    it 'rejects empty old_string and points at the write tool' do
      write_file('any.txt', 'hi')

      result = described_class.edit(workspace: workspace, path: 'any.txt',
                                    old_string: '', new_string: 'new',
                                    replace_all: false)

      assert_equal 'Error: old_string is empty; use the write tool to create or overwrite a file.', result
      assert_equal 'hi', (root + 'any.txt').binread
    end

    it 'rejects identical old_string and new_string' do
      write_file('any.txt', 'hi')

      result = described_class.edit(workspace: workspace, path: 'any.txt',
                                    old_string: 'hi', new_string: 'hi',
                                    replace_all: false)

      assert_equal 'Error: old_string and new_string are identical — this edit is a no-op.', result
    end

    it 'rejects a missing file' do
      result = described_class.edit(workspace: workspace, path: 'nope.txt',
                                    old_string: 'a', new_string: 'b',
                                    replace_all: false)

      assert_equal 'Error: file not found: nope.txt', result
    end

    it 'rejects directories' do
      FileUtils.mkdir_p(root + 'subdir')

      result = described_class.edit(workspace: workspace, path: 'subdir',
                                    old_string: 'a', new_string: 'b',
                                    replace_all: false)

      assert_equal 'Error: subdir is a directory', result
    end

    it 'rejects binary files (NUL byte in sample)' do
      write_file('bin.dat', "abc\x00def\x00ghi")

      result = described_class.edit(workspace: workspace, path: 'bin.dat',
                                    old_string: 'abc', new_string: 'xyz',
                                    replace_all: false)

      assert_equal 'Error: cannot edit binary file: bin.dat', result
      assert_equal "abc\x00def\x00ghi", (root + 'bin.dat').binread
    end

    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = described_class.edit(workspace: workspace, path: '../escape.txt',
                                    old_string: 'a', new_string: 'b',
                                    replace_all: false)

      assert result.start_with?('Error: path'), "expected workspace error, got #{result.inspect}"
      assert_includes result, 'is outside the workspace'
    end

    it 'returns an EACCES error when the file is unreadable' do
      path = write_file('locked.txt', 'secret')
      File.chmod(0o000, path)

      begin
        result = described_class.edit(workspace: workspace, path: 'locked.txt',
                                      old_string: 'a', new_string: 'b',
                                      replace_all: false)

        assert result.start_with?('Error: cannot edit locked.txt:'),
               "expected EACCES error, got #{result.inspect}"
      ensure
        File.chmod(0o644, path)
      end
    end
  end

  describe '.edit read-before-edit gate' do
    it 'refuses an existing file that has not been read this conversation' do
      create_unread('unread.rb', "alpha\nbeta\n")

      result = described_class.edit(workspace: workspace, path: 'unread.rb',
                                    old_string: 'beta', new_string: 'BETA',
                                    replace_all: false)

      assert result.start_with?('Error: unread.rb has not been read this conversation'),
             "expected read-first error, got #{result.inspect}"
      assert_equal "alpha\nbeta\n", (root + 'unread.rb').binread
    end

    it 'allows the edit once the file has been read via the read tool' do
      create_unread('via_read.rb', "alpha\nbeta\n")
      Pikuri::Workspace::Read.read(workspace: workspace, path: 'via_read.rb', offset: 1, limit: 2000)

      result = described_class.edit(workspace: workspace, path: 'via_read.rb',
                                    old_string: 'beta', new_string: 'BETA',
                                    replace_all: false)

      assert_equal 'Edited via_read.rb: replaced 1 occurrence.', result
    end

    it 'stays marked after an edit so a consecutive edit needs no re-read' do
      create_unread('refresh.rb', "a\nb\nc\n")
      Pikuri::Workspace::Read.read(workspace: workspace, path: 'refresh.rb', offset: 1, limit: 2000)

      first = described_class.edit(workspace: workspace, path: 'refresh.rb',
                                   old_string: 'a', new_string: 'A', replace_all: false)
      second = described_class.edit(workspace: workspace, path: 'refresh.rb',
                                    old_string: 'b', new_string: 'B', replace_all: false)

      assert_equal 'Edited refresh.rb: replaced 1 occurrence.', first
      assert_equal 'Edited refresh.rb: replaced 1 occurrence.', second
      assert_equal "A\nB\nc\n", (root + 'refresh.rb').binread
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces an observation for the LLM' do
      write_file('integ.txt', "alpha\nbeta\n")

      result = tool.run('path' => 'integ.txt', 'old_string' => 'alpha', 'new_string' => 'A')

      assert_equal 'Edited integ.txt: replaced 1 occurrence.', result
      assert_equal "A\nbeta\n", (root + 'integ.txt').binread
    end

    it 'accepts replace_all as a JSON boolean' do
      write_file('ra.txt', "x\nx\n")

      result = tool.run('path' => 'ra.txt', 'old_string' => 'x',
                        'new_string' => 'y', 'replace_all' => true)

      assert_equal 'Edited ra.txt: replaced 2 occurrences.', result
    end

    it 'accepts replace_all as the literal String "true"' do
      write_file('ra2.txt', "x\nx\n")

      result = tool.run('path' => 'ra2.txt', 'old_string' => 'x',
                        'new_string' => 'y', 'replace_all' => 'true')

      assert_equal 'Edited ra2.txt: replaced 2 occurrences.', result
    end

    it 'reports missing required fields via the Parameters validator' do
      result = tool.run('path' => 'foo.txt', 'old_string' => 'a')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'new_string'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('path' => 'foo.txt', 'old_string' => 'a',
                        'new_string' => 'b', 'regex' => true)

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'regex'
    end
  end

  describe 'parameters schema' do
    it 'advertises path/old_string/new_string as required and replace_all as optional' do
      schema = tool.parameters.to_openai

      assert_equal %w[path old_string new_string], schema[:required]
      assert_equal 'string',  schema[:properties][:path][:type]
      assert_equal 'string',  schema[:properties][:old_string][:type]
      assert_equal 'string',  schema[:properties][:new_string][:type]
      assert_equal 'boolean', schema[:properties][:replace_all][:type]
    end

    it 'wires through to_ruby_llm_tool under the "edit" name' do
      assert_equal 'edit', tool.to_ruby_llm_tool.name
    end
  end

  describe 'read-only gate' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }

    it 'refuses an edit while read-only is active, leaving the file untouched' do
      write_file('foo.rb', "alpha\nbeta\n")
      read_only.activate!

      result = described_class.edit(workspace: workspace, read_only: read_only,
                                    path: 'foo.rb', old_string: 'beta',
                                    new_string: 'BETA', replace_all: false)

      assert_match(/read-only/, result)
      assert_equal "alpha\nbeta\n", (root + 'foo.rb').binread
    end

    it "surfaces the flag's custom reason in the refusal" do
      write_file('foo.rb', "alpha\nbeta\n")
      custom = Pikuri::Workspace::ReadOnly.new(message: 'plan mode is on; call exit_plan_mode')
      custom.activate!

      result = described_class.edit(workspace: workspace, read_only: custom,
                                    path: 'foo.rb', old_string: 'beta',
                                    new_string: 'BETA', replace_all: false)

      assert_match(/cannot edit foo\.rb — plan mode is on; call exit_plan_mode/, result)
    end

    it 'edits normally once read-only is deactivated' do
      write_file('foo.rb', "alpha\nbeta\n")
      read_only.activate!
      read_only.deactivate!

      result = described_class.edit(workspace: workspace, read_only: read_only,
                                    path: 'foo.rb', old_string: 'beta',
                                    new_string: 'BETA', replace_all: false)

      assert_equal 'Edited foo.rb: replaced 1 occurrence.', result
    end
  end

  describe '.edit with a confirmer (confirm-all-writes posture)' do
    def deciding(decision)
      requests = []
      c = Object.new
      c.define_singleton_method(:ask) do |request:|
        requests << request
        if decision == :approve
          Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
        else
          Pikuri::Workspace::Confirmer::Rejected.new(reason: decision)
        end
      end
      c.define_singleton_method(:requests) { requests }
      c
    end

    it 'confirms with a diff payload (old=file, new=result) and writes on approve' do
      write_file('a.txt', "one\ntwo\n")
      cf = deciding(:approve)
      result = described_class.edit(workspace: workspace, confirmer: cf,
                                    path: 'a.txt', old_string: 'two', new_string: 'TWO',
                                    replace_all: false)
      assert_equal 'Edited a.txt: replaced 1 occurrence.', result
      assert_equal "one\nTWO\n", (root + 'a.txt').binread
      change = cf.requests.first.change
      assert_equal "one\ntwo\n", change.old
      assert_equal "one\nTWO\n", change.new
    end

    it 'declines with a reason and leaves the file unchanged' do
      write_file('a.txt', "one\ntwo\n")
      cf = deciding('leave it as is')
      result = described_class.edit(workspace: workspace, confirmer: cf,
                                    path: 'a.txt', old_string: 'two', new_string: 'TWO',
                                    replace_all: false)
      assert_includes result, 'leave it as is'
      assert_equal "one\ntwo\n", (root + 'a.txt').binread
    end
  end
end
