# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Tool::Workspace do
  let(:outside) { Pathname.new(Dir.mktmpdir('pikuri-ws-outside-')).realpath }
  let(:root)    { Pathname.new(Dir.mktmpdir('pikuri-ws-root-')).realpath }
  let(:extra_read)  { Pathname.new(Dir.mktmpdir('pikuri-ws-read-')).realpath }
  let(:extra_write) { Pathname.new(Dir.mktmpdir('pikuri-ws-write-')).realpath }
  let(:workspace)   { described_class.new(anchor: root) }

  after do
    FileUtils.rm_rf(outside)
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(extra_read)
    FileUtils.rm_rf(extra_write)
  end

  describe '#cwd' do
    it 'returns the realpath of the configured anchor' do
      assert_equal root, workspace.cwd
    end
  end

  describe '#readable / #writable' do
    it 'always includes the anchor in both lists' do
      assert_includes workspace.readable, root
      assert_includes workspace.writable, root
    end

    it 'extra writable roots are also readable' do
      ws = described_class.new(anchor: root, writable: [extra_write])
      assert_includes ws.writable, extra_write
      assert_includes ws.readable, extra_write
    end

    it 'extra readable roots are NOT in the writable set' do
      ws = described_class.new(anchor: root, readable: [extra_read])
      assert_includes ws.readable, extra_read
      refute_includes ws.writable, extra_read
    end
  end

  describe '#temp' do
    it 'returns nil by default' do
      assert_nil workspace.temp
    end

    it 'mints an ephemeral writable dir when temp: true' do
      ws = described_class.new(anchor: root, temp: true)
      assert ws.temp.exist?
      assert ws.temp.directory?
      assert_includes ws.writable, ws.temp
      assert_includes ws.readable, ws.temp
    ensure
      FileUtils.remove_entry(ws.temp.to_s) if ws&.temp&.exist?
    end

    it 'two workspaces with temp: true get distinct temp dirs' do
      a = described_class.new(anchor: root, temp: true)
      b = described_class.new(anchor: root, temp: true)
      refute_equal a.temp, b.temp
    ensure
      [a, b].each { |w| FileUtils.remove_entry(w.temp.to_s) if w&.temp&.exist? }
    end
  end

  describe '#resolve_for_read / #resolve_for_write under the anchor' do
    it 'resolves an existing file under the anchor' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'lib/foo.rb', 'x')

      assert_equal root + 'lib/foo.rb', workspace.resolve_for_read('lib/foo.rb')
      assert_equal root + 'lib/foo.rb', workspace.resolve_for_write('lib/foo.rb')
    end

    it 'resolves a path whose leaf does not exist (write-create case)' do
      FileUtils.mkdir_p(root + 'lib')

      result = workspace.resolve_for_write('lib/new_file.rb')
      assert_equal root + 'lib/new_file.rb', result
      refute result.exist?
    end

    it 'resolves a path whose intermediate directories do not exist' do
      result = workspace.resolve_for_write('a/b/c/d.rb')
      assert_equal root + 'a/b/c/d.rb', result
    end

    it 'accepts an absolute path inside the anchor' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'lib/foo.rb', 'x')

      result = workspace.resolve_for_read((root + 'lib/foo.rb').to_s)
      assert_equal root + 'lib/foo.rb', result
    end

    it 'transparently resolves a symlink that stays inside the anchor' do
      FileUtils.mkdir_p(root + 'sub')
      File.write(root + 'sub/target.rb', 'x')
      File.symlink((root + 'sub').to_s, (root + 'link').to_s)

      result = workspace.resolve_for_read('link/target.rb')
      assert_equal root + 'sub/target.rb', result
    end
  end

  describe 'multi-root behavior' do
    let(:ws) { described_class.new(anchor: root, readable: [extra_read], writable: [extra_write]) }

    it 'resolves reads into the extra readable root' do
      File.write(extra_read + 'data.txt', 'x')
      assert_equal extra_read + 'data.txt', ws.resolve_for_read((extra_read + 'data.txt').to_s)
    end

    it 'rejects writes into the read-only extra root' do
      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        ws.resolve_for_write((extra_read + 'newfile.txt').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'resolves both reads and writes into the extra writable root' do
      assert_equal extra_write + 'a.rb', ws.resolve_for_write((extra_write + 'a.rb').to_s)
      assert_equal extra_write + 'a.rb', ws.resolve_for_read((extra_write + 'a.rb').to_s)
    end

    it 'still rejects paths outside every root' do
      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        ws.resolve_for_read((outside + 'secret').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end
  end

  describe 'containment errors' do
    it 'raises on .. escape (lexical traversal)' do
      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        workspace.resolve_for_read('lib/../../../etc/passwd')
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on an absolute path outside the anchor' do
      File.write(outside + 'secret', 'x')

      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        workspace.resolve_for_read((outside + 'secret').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on a symlink that escapes the workspace' do
      FileUtils.mkdir_p(outside + 'leaked')
      File.write(outside + 'leaked/secret', 'x')
      File.symlink(outside.to_s, (root + 'evil_link').to_s)

      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        workspace.resolve_for_read('evil_link/leaked/secret')
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on a symlink even when the target path does not yet exist (write case)' do
      File.symlink(outside.to_s, (root + 'evil_link').to_s)

      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        workspace.resolve_for_write('evil_link/new_file.rb')
      end
      assert_includes err.message, 'outside the workspace'
    end
  end

  describe 'anchor denylist' do
    it 'rejects /' do
      err = assert_raises(Pikuri::Tool::Workspace::Error) { described_class.new(anchor: '/') }
      assert_includes err.message, 'system or home root'
    end

    it 'rejects /etc, /var, /proc, /usr, /tmp, /opt' do
      %w[/etc /var /proc /usr /tmp /opt].each do |p|
        err = assert_raises(Pikuri::Tool::Workspace::Error) { described_class.new(anchor: p) }
        assert_includes err.message, 'system or home root'
      end
    end

    it 'rejects any direct child of /home' do
      # Build a path like /home/<bogus_user> that resolves cleanly without
      # actually existing. Use the realpath of an existing /home subdir if
      # one's present, else skip — the parent-is-/home check needs a real
      # path to canonicalize.
      home_root = Pathname.new('/home')
      skip 'no /home present on this system' unless home_root.directory?
      candidate = home_root.children.find(&:directory?)
      skip 'no /home/* dir present' unless candidate

      err = assert_raises(Pikuri::Tool::Workspace::Error) do
        described_class.new(anchor: candidate.to_s)
      end
      assert_includes err.message, 'system or home root'
    end

    it 'accepts a normal project dir under /home/<user>/...' do
      # Build a nested dir under root (which itself is in /tmp/...). Verifies
      # the denylist doesn't false-positive on deep paths.
      project = root + 'project'
      FileUtils.mkdir_p(project)
      ws = described_class.new(anchor: project.to_s)
      assert_equal project.realpath, ws.cwd
    end
  end

  describe 'edge cases' do
    it 'resolves the anchor itself (no traversal)' do
      assert_equal root, workspace.resolve_for_read('.')
      assert_equal root, workspace.resolve_for_read('')
    end
  end
end
