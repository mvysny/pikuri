# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Tool::Write do
  let(:root)      { Pathname.new(Dir.mktmpdir('pikuri-write-root-')).realpath }
  let(:workspace) { Pikuri::Tool::Workspace::Cwd.new(root: root) }
  let(:confirmer) { build_confirmer }
  let(:tool)      { described_class.new(workspace: workspace, confirmer: confirmer) }

  after { FileUtils.rm_rf(root) }

  # Inline confirmer double: records every prompt it sees, returns
  # successive elements of +answers+. Calling +confirm?+ when no answer
  # is queued raises — surfaces "test silently consumed a confirmation"
  # bugs rather than letting nil flow through as a false answer.
  def build_confirmer(*answers)
    queue   = answers.dup
    prompts = []
    confirmer = Object.new
    confirmer.define_singleton_method(:confirm?) do |prompt:|
      prompts << prompt
      raise "build_confirmer received an unexpected #confirm? call (prompt: #{prompt.inspect})" if queue.empty?

      queue.shift
    end
    confirmer.define_singleton_method(:prompts) { prompts }
    confirmer
  end

  def write_file(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  describe '.write new-file path' do
    it 'creates the file and returns a Created observation' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'hello.txt', content: "alpha\nbeta\n")

      assert_equal 'Created hello.txt (11 bytes)', result
      assert_equal "alpha\nbeta\n", (root + 'hello.txt').read
    end

    it 'creates missing parent directories' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'lib/new/dir/foo.rb', content: "x\n")

      assert_equal 'Created lib/new/dir/foo.rb (2 bytes)', result
      assert_equal "x\n", (root + 'lib/new/dir/foo.rb').read
    end

    it 'allows empty content' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'empty.txt', content: '')

      assert_equal 'Created empty.txt (0 bytes)', result
      assert (root + 'empty.txt').exist?
      assert_equal '', (root + 'empty.txt').read
    end

    it 'does not consult the confirmer for a new file' do
      described_class.write(workspace: workspace, confirmer: confirmer,
                            path: 'fresh.txt', content: 'hi')

      assert_equal [], confirmer.prompts
    end
  end

  describe '.write overwrite — identical content' do
    it 'returns a no-op error before consulting the confirmer' do
      write_file('same.txt', "exact bytes\n")

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'same.txt', content: "exact bytes\n")

      assert_equal(
        'Error: same.txt already contains exactly this content — no write needed. ' \
        'If you intended a change, re-read the file and try again.',
        result
      )
      assert_equal [], confirmer.prompts
      assert_equal "exact bytes\n", (root + 'same.txt').read
    end
  end

  describe '.write overwrite — content differs' do
    it 'prompts the confirmer and overwrites on approve' do
      write_file('target.txt', "old\n")
      cf = build_confirmer(true)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'target.txt', content: "new content\n")

      assert_equal 'Updated target.txt (4 → 12 bytes)', result
      assert_equal "new content\n", (root + 'target.txt').read
      assert_equal 1, cf.prompts.size
    end

    it 'asks with the byte-delta prompt format' do
      write_file('target.txt', 'abcd')
      cf = build_confirmer(true)

      described_class.write(workspace: workspace, confirmer: cf,
                            path: 'target.txt', content: 'abcdef')

      assert_equal 'OK to overwrite target.txt: 4 → 6 bytes? (y/n)', cf.prompts.first
    end

    it 'returns a decline error and leaves the file untouched on reject' do
      write_file('target.txt', "original\n")
      cf = build_confirmer(false)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'target.txt', content: "replacement\n")

      assert_equal 'Error: user declined the write to target.txt.', result
      assert_equal "original\n", (root + 'target.txt').read
    end

    it 'treats trailing-newline-only differences as a real overwrite (strict bytes)' do
      write_file('trail.txt', "line\n")
      cf = build_confirmer(true)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'trail.txt', content: 'line')

      assert_equal 'Updated trail.txt (5 → 4 bytes)', result
      assert_equal 'line', (root + 'trail.txt').read
      assert_equal 1, cf.prompts.size
    end

    it 'reports identical content for byte-for-byte UTF-8 matches regardless of encoding tags' do
      write_file('utf.txt', "héllo\n")
      bytes_equal_content = +"héllo\n"
      bytes_equal_content.force_encoding(Encoding::BINARY)

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'utf.txt', content: bytes_equal_content)

      assert result.start_with?('Error: utf.txt already contains'),
             "expected identical-content error, got #{result.inspect}"
      assert_equal [], confirmer.prompts
    end
  end

  describe '.write refusals' do
    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: '../escape.txt', content: 'x')

      assert result.start_with?('Error: path'), "expected workspace error, got #{result.inspect}"
      assert_includes result, 'is outside the workspace'
      assert_equal [], confirmer.prompts
    end

    it 'refuses directories' do
      FileUtils.mkdir_p(root + 'subdir')

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'subdir', content: 'x')

      assert_equal 'Error: subdir is a directory', result
      assert_equal [], confirmer.prompts
    end

    it 'reports a read-side error specifically when the existing file is unreadable' do
      path = write_file('locked.txt', "secret\n")
      File.chmod(0o000, path)

      begin
        result = described_class.write(workspace: workspace, confirmer: confirmer,
                                       path: 'locked.txt', content: 'replacement')

        assert result.start_with?('Error: cannot read locked.txt for overwrite check:'),
               "expected read-side error, got #{result.inspect}"
        assert_equal [], confirmer.prompts
      ensure
        File.chmod(0o644, path)
      end
    end

    it 'reports a write-side error when the target directory denies writes' do
      FileUtils.mkdir_p(root + 'ro')
      File.chmod(0o500, root + 'ro')

      begin
        result = described_class.write(workspace: workspace, confirmer: confirmer,
                                       path: 'ro/new.txt', content: 'x')

        assert result.start_with?('Error: cannot write ro/new.txt:'),
               "expected write-side error, got #{result.inspect}"
      ensure
        File.chmod(0o700, root + 'ro')
      end
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a Created observation for the LLM' do
      result = tool.run('path' => 'integ.txt', 'content' => "hi\n")

      assert_equal 'Created integ.txt (3 bytes)', result
      assert_equal "hi\n", (root + 'integ.txt').read
    end

    it 'reports a missing required path via the Parameters validator' do
      result = tool.run('content' => 'x')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'path'
    end

    it 'reports a missing required content via the Parameters validator' do
      result = tool.run('path' => 'foo.txt')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'content'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('path' => 'foo.txt', 'content' => 'x', 'mode' => '0644')

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'mode'
    end
  end

  describe 'parameters schema' do
    it 'advertises path and content as required strings' do
      schema = tool.parameters.to_h

      assert_equal %w[path content], schema[:required]
      assert_equal 'string', schema[:properties][:path][:type]
      assert_equal 'string', schema[:properties][:content][:type]
    end

    it 'wires through to_ruby_llm_tool under the "write" name' do
      klass = tool.to_ruby_llm_tool

      assert_equal 'write', klass.name
    end
  end
end
