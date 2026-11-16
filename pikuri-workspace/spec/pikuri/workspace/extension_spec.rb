# frozen_string_literal: true

require 'pikuri/testing'

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Extension do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-ws-ext-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:confirmer)  { Pikuri::Workspace::Confirmer::AUTO_APPROVE }
  let(:configurator) { Pikuri::Testing.configurator }

  after { FileUtils.rm_rf(root) }

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  it 'contributes the confirmation guidance snippet' do
    ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
    assert_equal described_class::PROMPT_SNIPPET, ext.system_prompt_snippets.first
  end

  describe 'boot snapshot' do
    def snapshot(fs = filesystem)
      described_class.new(filesystem: fs, confirmer: confirmer).system_prompt_snippets.last
    end

    it 'lists the root one level deep, and points at file_list for the rest' do
      FileUtils.mkdir_p(root / 'lib' / 'nested')
      File.write(root / 'lib' / 'thing.rb', 'x')
      File.write(root / 'README.md', 'y' * 4300)

      out = snapshot
      assert_match(/\A<workspace_snapshot>\n/, out)
      assert_match(/<\/workspace_snapshot>\z/, out)
      assert_includes out, "The workspace root is #{root}."
      assert_includes out, 'lib/  [1 dir, 1 file]'
      assert_includes out, 'README.md  4.2K'
      assert_includes out, '`file_list`'
      # Depth 1: the child directory is summarised, never expanded into a row.
      refute_includes out, 'nested/'
    end

    it 'says so for an empty root rather than emitting a blank block' do
      out = snapshot
      assert_includes out, 'It is empty.'
      refute_includes out, 'as of the start of'
    end

    it 'degrades to one line over the byte cap instead of truncating' do
      entry_count = (described_class::SNAPSHOT_MAX_BYTES / 8) + 50
      entry_count.times { |i| File.write(root / format('f%05d', i), '') }

      out = snapshot
      assert_includes out, 'too many entries to show here'
      assert_includes out, '`file_list`'
      refute_includes out, 'f00000'
      assert out.bytesize < described_class::SNAPSHOT_MAX_BYTES,
             "degraded snippet should be tiny, was #{out.bytesize} B"
    end

    it 'propagates a root it cannot open' do
      FileUtils.chmod(0o000, root)
      assert_raises(SystemCallError) { snapshot }
    ensure
      FileUtils.chmod(0o755, root)
    end

    it 'is re-taken when the prompt is re-assembled' do
      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      assert_includes ext.system_prompt_snippets.last, 'It is empty.'

      File.write(root / 'appeared.txt', 'z')
      assert_includes ext.system_prompt_snippets.last, 'appeared.txt'
    end
  end

  describe '#configure' do
    it 'registers every file tool' do
      described_class.new(filesystem: filesystem, confirmer: confirmer).configure(configurator)

      names = configurator.tools.map(&:name)
      assert_includes names, 'read'
      assert_includes names, 'grep'
      assert_includes names, 'glob'
      assert_includes names, 'edit'
      assert_includes names, 'write'
    end

    it 'leaves only grep out under grep: false' do
      described_class.new(filesystem: filesystem, confirmer: confirmer, grep: false).configure(configurator)

      assert_equal %w[read glob file_list edit write], configurator.tools.map(&:name)
    end

    it 'raises if any of its tools was already registered' do
      configurator.add_tool(Pikuri::Workspace::Read.new(workspace: described_class.new(filesystem: filesystem, confirmer: confirmer).workspace))

      err = assert_raises(RuntimeError) do
        described_class.new(filesystem: filesystem, confirmer: confirmer).configure(configurator)
      end
      assert_match(/Read.*cannot be pre-registered/, err.message)
    end
  end

  describe 'write posture' do
    def counting_confirmer
      asked = []
      c = Object.new
      c.define_singleton_method(:ask) do |request:, cancellable:|
        asked << request.question
        Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
      end
      c.define_singleton_method(:asked) { asked }
      c
    end

    # Creates a file with +write+, then edits it, through the registered tools.
    def write_then_edit(**posture)
      cf = counting_confirmer
      described_class.new(filesystem: filesystem, confirmer: cf, **posture).configure(configurator)
      tools = configurator.tools.to_h { |t| [t.name, t] }
      tools.fetch('write').run('path' => 'new.txt', 'content' => "x\n")
      tools.fetch('edit').run('path' => 'new.txt', 'old_string' => 'x', 'new_string' => 'y')
      assert_equal "y\n", File.read(root + 'new.txt')
      cf.asked
    end

    it 'confirms a new file and an edit by default' do
      assert_equal 2, write_then_edit.size
    end

    it 'confirms neither under confirm_all_writes: false' do
      assert_equal [], write_then_edit(confirm_all_writes: false)
    end
  end

  describe 'shared read record across the registered tools' do
    it 'lets an edit through once the file is read via the registered read tool' do
      File.write(root + 'foo.rb', "alpha\nbeta\n")

      ext = described_class.new(filesystem: filesystem, confirmer: confirmer)
      ext.configure(configurator)
      read = configurator.tools.find { |t| t.name == 'read' }
      edit = configurator.tools.find { |t| t.name == 'edit' }

      # Edit refuses before the shared record knows the file was read.
      refused = edit.run('path' => 'foo.rb', 'old_string' => 'beta', 'new_string' => 'BETA').to_s
      assert refused.start_with?('Error: foo.rb has not been read'), refused

      # Read (same composite) marks it; the edit now clears the gate.
      read.run('path' => 'foo.rb')
      edited = edit.run('path' => 'foo.rb', 'old_string' => 'beta', 'new_string' => 'BETA').to_s
      assert_equal 'Edited foo.rb: replaced 1 occurrence.', edited
    end
  end
end
