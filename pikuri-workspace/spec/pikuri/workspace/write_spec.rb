# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Write do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-write-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { Pikuri::Workspace::Workspace.new(filesystem: filesystem) }
  let(:confirmer)  { build_confirmer }
  let(:tool)       { described_class.new(workspace: workspace, confirmer: confirmer) }

  after { FileUtils.rm_rf(root) }

  # Inline confirmer double: records every request it sees, returns
  # successive elements of +answers+ as {Confirmer::Approved} (for +true+)
  # or {Confirmer::Rejected} (for +false+) — Write reaches the confirmer
  # only through {WriteGate}, which calls +#ask+. Calling +#ask+ when no
  # answer is queued raises — surfaces "test silently consumed a
  # confirmation" bugs rather than letting nil flow through as an answer.
  def build_confirmer(*answers)
    queue    = answers.dup
    requests = []
    confirmer = Object.new
    confirmer.define_singleton_method(:ask) do |request:|
      requests << request
      raise "build_confirmer received an unexpected #ask call (request: #{request.inspect})" if queue.empty?

      if queue.shift
        Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
      else
        Pikuri::Workspace::Confirmer::Rejected.new(reason: nil)
      end
    end
    confirmer.define_singleton_method(:requests) { requests }
    confirmer
  end

  # Create a file AND mark it read in the ledger — the common overwrite
  # fixture is "a file the model has already read", so it clears the
  # read-before-overwrite gate. Tests that exercise the gate itself use
  # +create_unread+.
  def write_file(rel, content)
    path = create_unread(rel, content)
    workspace.mark_read(path)
    path
  end

  def create_unread(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  describe '.write new-file path' do
    it 'creates the file and returns a Created observation' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'hello.txt', content: "alpha\nbeta\n").to_s

      assert_equal 'Created hello.txt (11 bytes)', result
      assert_equal "alpha\nbeta\n", (root + 'hello.txt').read
    end

    it 'creates missing parent directories' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'lib/new/dir/foo.rb', content: "x\n").to_s

      assert_equal 'Created lib/new/dir/foo.rb (2 bytes)', result
      assert_equal "x\n", (root + 'lib/new/dir/foo.rb').read
    end

    it 'allows empty content' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'empty.txt', content: '').to_s

      assert_equal 'Created empty.txt (0 bytes)', result
      assert (root + 'empty.txt').exist?
      assert_equal '', (root + 'empty.txt').read
    end

    it 'does not consult the confirmer for a new file' do
      described_class.write(workspace: workspace, confirmer: confirmer,
                            path: 'fresh.txt', content: 'hi')

      assert_equal [], confirmer.requests
    end
  end

  describe '.write overwrite — identical content' do
    it 'returns a no-op error before consulting the confirmer' do
      write_file('same.txt', "exact bytes\n")

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'same.txt', content: "exact bytes\n").to_s

      assert_equal(
        'Error: same.txt already contains exactly this content — no write needed. ' \
        'If you intended a change, re-read the file and try again.',
        result
      )
      assert_equal [], confirmer.requests
      assert_equal "exact bytes\n", (root + 'same.txt').read
    end
  end

  describe '.write overwrite — content differs' do
    it 'prompts the confirmer and overwrites on approve' do
      write_file('target.txt', "old\n")
      cf = build_confirmer(true)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'target.txt', content: "new content\n").to_s

      assert_equal 'Updated target.txt (4 → 12 bytes)', result
      assert_equal "new content\n", (root + 'target.txt').read
      assert_equal 1, cf.requests.size
    end

    it 'asks with the byte-delta question and no detail' do
      write_file('target.txt', 'abcd')
      cf = build_confirmer(true)

      described_class.write(workspace: workspace, confirmer: cf,
                            path: 'target.txt', content: 'abcdef')

      assert_equal 'OK to overwrite target.txt: 4 → 6 bytes?', cf.requests.first.question
      assert_nil cf.requests.first.detail
    end

    it 'returns a decline error and leaves the file untouched on reject' do
      write_file('target.txt', "original\n")
      cf = build_confirmer(false)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'target.txt', content: "replacement\n").to_s

      assert_equal 'Error: user declined the write to target.txt.', result
      assert_equal "original\n", (root + 'target.txt').read
    end

    it 'treats trailing-newline-only differences as a real overwrite (strict bytes)' do
      write_file('trail.txt', "line\n")
      cf = build_confirmer(true)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'trail.txt', content: 'line').to_s

      assert_equal 'Updated trail.txt (5 → 4 bytes)', result
      assert_equal 'line', (root + 'trail.txt').read
      assert_equal 1, cf.requests.size
    end

    it 'reports identical content for byte-for-byte UTF-8 matches regardless of encoding tags' do
      write_file('utf.txt', "héllo\n")
      bytes_equal_content = +"héllo\n"
      bytes_equal_content.force_encoding(Encoding::BINARY)

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'utf.txt', content: bytes_equal_content).to_s

      assert result.start_with?('Error: utf.txt already contains'),
             "expected identical-content error, got #{result.inspect}"
      assert_equal [], confirmer.requests
    end
  end

  describe '.write read-before-overwrite gate' do
    it 'refuses overwriting an existing file that has not been read, before confirming' do
      create_unread('unread.txt', "old\n")

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'unread.txt', content: "new\n").to_s

      assert result.start_with?('Error: unread.txt exists but has not been read this conversation'),
             "expected read-first error, got #{result.inspect}"
      assert_equal [], confirmer.requests
      assert_equal "old\n", (root + 'unread.txt').read
    end

    it 'allows the overwrite once the file has been read via the read tool' do
      create_unread('viaread.txt', "old\n")
      Pikuri::Workspace::Read.read(workspace: workspace, path: 'viaread.txt', offset: 1, limit: 2000)
      cf = build_confirmer(true)

      result = described_class.write(workspace: workspace, confirmer: cf,
                                     path: 'viaread.txt', content: "new\n").to_s

      assert_equal 'Updated viaread.txt (4 → 4 bytes)', result
      assert_equal "new\n", (root + 'viaread.txt').read
    end

    it 'does not gate a new file (nothing to read)' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'brand-new.txt', content: "hi\n").to_s

      assert_equal 'Created brand-new.txt (3 bytes)', result
    end
  end

  describe '.write refusals' do
    it 'converts workspace-boundary violations to "Error: ..." strings' do
      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: '../escape.txt', content: 'x').to_s

      assert result.start_with?('Error: path'), "expected workspace error, got #{result.inspect}"
      assert_includes result, 'is outside the workspace'
      assert_equal [], confirmer.requests
    end

    it 'refuses directories' do
      FileUtils.mkdir_p(root + 'subdir')

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     path: 'subdir', content: 'x').to_s

      assert_equal 'Error: subdir is a directory', result
      assert_equal [], confirmer.requests
    end

    it 'reports a read-side error specifically when the existing file is unreadable' do
      path = write_file('locked.txt', "secret\n")
      File.chmod(0o000, path)

      begin
        result = described_class.write(workspace: workspace, confirmer: confirmer,
                                       path: 'locked.txt', content: 'replacement').to_s

        assert result.start_with?('Error: cannot read locked.txt for overwrite check:'),
               "expected read-side error, got #{result.inspect}"
        assert_equal [], confirmer.requests
      ensure
        File.chmod(0o644, path)
      end
    end

    it 'reports a write-side error when the target directory denies writes' do
      FileUtils.mkdir_p(root + 'ro')
      File.chmod(0o500, root + 'ro')

      begin
        result = described_class.write(workspace: workspace, confirmer: confirmer,
                                       path: 'ro/new.txt', content: 'x').to_s

        assert result.start_with?('Error: cannot write ro/new.txt:'),
               "expected write-side error, got #{result.inspect}"
      ensure
        File.chmod(0o700, root + 'ro')
      end
    end
  end

  describe 'tool integration (via #run)' do
    it 'validates args and produces a Created observation for the LLM' do
      result = tool.run('path' => 'integ.txt', 'content' => "hi\n").to_s

      assert_equal 'Created integ.txt (3 bytes)', result
      assert_equal "hi\n", (root + 'integ.txt').read
    end

    it 'reports a missing required path via the Parameters validator' do
      result = tool.run('content' => 'x').to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'path'
    end

    it 'reports a missing required content via the Parameters validator' do
      result = tool.run('path' => 'foo.txt').to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'content'
    end

    it 'reports unknown parameters via the Parameters validator' do
      result = tool.run('path' => 'foo.txt', 'content' => 'x', 'mode' => '0644').to_s

      assert result.start_with?('Error:'), "expected validator error, got #{result.inspect}"
      assert_includes result, 'mode'
    end
  end

  describe 'parameters schema' do
    it 'advertises path and content as required strings' do
      schema = tool.parameters.to_openai

      assert_equal %w[path content], schema[:required]
      assert_equal 'string', schema[:properties][:path][:type]
      assert_equal 'string', schema[:properties][:content][:type]
    end

    it 'wires through to_ruby_llm_tool under the "write" name' do
      klass = tool.to_ruby_llm_tool

      assert_equal 'write', klass.name
    end
  end

  describe 'read-only gate' do
    let(:read_only) { Pikuri::Workspace::ReadOnly.new }

    it 'refuses a new-file write while read-only is active, touching nothing' do
      read_only.activate!

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     read_only: read_only, path: 'hello.txt',
                                     content: "alpha\n").to_s

      assert_match(/read-only/, result)
      refute (root + 'hello.txt').exist?
    end

    it 'refuses before consulting the confirmer on an overwrite' do
      write_file('foo.rb', "old\n")
      read_only.activate!
      # confirmer with no queued answers raises if consulted
      guard = build_confirmer

      result = described_class.write(workspace: workspace, confirmer: guard,
                                     read_only: read_only, path: 'foo.rb',
                                     content: "new\n").to_s

      assert_match(/read-only/, result)
      assert_empty guard.requests
      assert_equal "old\n", (root + 'foo.rb').read
    end

    it 'writes normally once read-only is deactivated' do
      read_only.activate!
      read_only.deactivate!

      result = described_class.write(workspace: workspace, confirmer: confirmer,
                                     read_only: read_only, path: 'hello.txt',
                                     content: "alpha\n").to_s

      assert_equal 'Created hello.txt (6 bytes)', result
    end
  end

  describe '.write confirm_all_writes' do
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

    it 'confirms a NEW file (change.old is nil) and writes on approve' do
      cf = deciding(:approve)
      result = described_class.write(workspace: workspace, confirmer: cf, confirm_all_writes: true,
                                     path: 'new.txt', content: "hi\n").to_s
      assert_equal 'Created new.txt (3 bytes)', result
      assert_equal "hi\n", File.read(root + 'new.txt')
      change = cf.requests.first.change
      assert_equal 'new.txt', change.path
      assert_nil change.old
    end

    it 'confirms an overwrite carrying old+new bytes and writes on approve' do
      write_file('a.txt', "old\n")
      cf = deciding(:approve)
      described_class.write(workspace: workspace, confirmer: cf, confirm_all_writes: true,
                            path: 'a.txt', content: "new\n")
      assert_equal "new\n", File.read(root + 'a.txt')
      change = cf.requests.first.change
      assert_equal "old\n", change.old
      assert_equal "new\n", change.new
    end

    it 'declines with a reason and leaves the file unchanged' do
      write_file('a.txt', "old\n")
      cf = deciding('use the other config')
      result = described_class.write(workspace: workspace, confirmer: cf, confirm_all_writes: true,
                                     path: 'a.txt', content: "new\n").to_s
      assert_includes result, 'use the other config'
      assert_equal "old\n", File.read(root + 'a.txt')
    end

    it 'still no-ops identical content before consulting the confirmer' do
      write_file('a.txt', "same\n")
      cf = deciding(:approve)
      result = described_class.write(workspace: workspace, confirmer: cf, confirm_all_writes: true,
                                     path: 'a.txt', content: "same\n").to_s
      assert_match(/already contains/, result)
      assert_equal [], cf.requests
    end
  end
end
