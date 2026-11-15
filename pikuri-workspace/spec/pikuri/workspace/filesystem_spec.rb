# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Filesystem do
  let(:outside) { Pathname.new(Dir.mktmpdir('pikuri-ws-outside-')).realpath }
  let(:root)    { Pathname.new(Dir.mktmpdir('pikuri-ws-root-')).realpath }
  let(:extra_read)  { Pathname.new(Dir.mktmpdir('pikuri-ws-read-')).realpath }
  let(:extra_write) { Pathname.new(Dir.mktmpdir('pikuri-ws-write-')).realpath }
  let(:workspace)   { described_class.new(project_root: root) }

  after do
    FileUtils.rm_rf(outside)
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(extra_read)
    FileUtils.rm_rf(extra_write)
  end

  describe '#project_root' do
    it 'returns the realpath of the configured project_root' do
      assert_equal root, workspace.project_root
    end
  end

  describe '#readable / #writable' do
    it 'always includes the project_root in both lists' do
      assert_includes workspace.readable, root
      assert_includes workspace.writable, root
    end

    it 'extra writable roots are also readable' do
      ws = described_class.new(project_root: root, writable: [extra_write])
      assert_includes ws.writable, extra_write
      assert_includes ws.readable, extra_write
    end

    it 'extra readable roots are NOT in the writable set' do
      ws = described_class.new(project_root: root, readable: [extra_read])
      assert_includes ws.readable, extra_read
      refute_includes ws.writable, extra_read
    end
  end

  describe '#resolve_for_read / #resolve_for_write under the project_root' do
    it 'resolves an existing file under the project_root' do
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

    it 'accepts an absolute path inside the project_root' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'lib/foo.rb', 'x')

      result = workspace.resolve_for_read((root + 'lib/foo.rb').to_s)
      assert_equal root + 'lib/foo.rb', result
    end

    it 'transparently resolves a symlink that stays inside the project_root' do
      FileUtils.mkdir_p(root + 'sub')
      File.write(root + 'sub/target.rb', 'x')
      File.symlink((root + 'sub').to_s, (root + 'link').to_s)

      result = workspace.resolve_for_read('link/target.rb')
      assert_equal root + 'sub/target.rb', result
    end
  end

  describe 'a leading ~' do
    before do
      @original_home = Dir.method(:home)
      fake_home = outside.to_s
      Dir.define_singleton_method(:home) { |*| fake_home }
    end

    after do
      original = @original_home
      Dir.define_singleton_method(:home) { |*args| original.call(*args) }
    end

    it 'expands ~/ to the home folder, so a home path is refused as outside the workspace' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read('~/.bashrc')
      end
      assert_includes err.message, "'#{outside}/.bashrc' is outside the workspace"
    end

    it 'expands ~/ into a home-rooted workspace' do
      ws = described_class.new(project_root: root, readable: [outside])
      assert_equal outside + '.bashrc', ws.resolve_for_read('~/.bashrc')
      assert_equal outside, ws.resolve_for_read('~')
    end

    it 'leaves a ~ that is not leading alone' do
      assert_equal root + 'a/~/b', workspace.resolve_for_write('a/~/b')
    end
  end

  describe 'multi-root behavior' do
    let(:ws) { described_class.new(project_root: root, readable: [extra_read], writable: [extra_write]) }

    it 'resolves reads into the extra readable root' do
      File.write(extra_read + 'data.txt', 'x')
      assert_equal extra_read + 'data.txt', ws.resolve_for_read((extra_read + 'data.txt').to_s)
    end

    it 'resolves anywhere under a / readable root' do
      whole_disk = described_class.new(project_root: root, readable: ['/'])
      File.write(extra_read + 'data.txt', 'x')

      assert_equal extra_read + 'data.txt', whole_disk.resolve_for_read((extra_read + 'data.txt').to_s)
      assert_equal Pathname.new('/'), whole_disk.resolve_for_read('/')
    end

    it 'does not treat a sibling sharing a name prefix as inside a root' do
      sibling = Pathname.new("#{extra_read}-sibling")
      FileUtils.mkdir_p(sibling)
      assert_raises(Pikuri::Workspace::Filesystem::Error) { ws.resolve_for_read((sibling + 'x').to_s) }
    ensure
      FileUtils.rm_rf(sibling)
    end

    it 'rejects writes into the read-only extra root' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        ws.resolve_for_write((extra_read + 'newfile.txt').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'resolves both reads and writes into the extra writable root' do
      assert_equal extra_write + 'a.rb', ws.resolve_for_write((extra_write + 'a.rb').to_s)
      assert_equal extra_write + 'a.rb', ws.resolve_for_read((extra_write + 'a.rb').to_s)
    end

    it 'still rejects paths outside every root' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        ws.resolve_for_read((outside + 'secret').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end
  end

  describe 'containment errors' do
    it 'raises on .. escape (lexical traversal)' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read('lib/../../../etc/passwd')
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on an absolute path outside the project_root' do
      File.write(outside + 'secret', 'x')

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read((outside + 'secret').to_s)
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on a symlink that escapes the workspace' do
      FileUtils.mkdir_p(outside + 'leaked')
      File.write(outside + 'leaked/secret', 'x')
      File.symlink(outside.to_s, (root + 'evil_link').to_s)

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read('evil_link/leaked/secret')
      end
      assert_includes err.message, 'outside the workspace'
    end

    it 'raises on a symlink even when the target path does not yet exist (write case)' do
      File.symlink(outside.to_s, (root + 'evil_link').to_s)

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_write('evil_link/new_file.rb')
      end
      assert_includes err.message, 'outside the workspace'
    end
  end

  describe 'project_root denylist' do
    it 'rejects /' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) { described_class.new(project_root: '/') }
      assert_includes err.message, 'system or home root'
    end

    it 'rejects /etc, /var, /proc, /usr, /tmp, /opt' do
      %w[/etc /var /proc /usr /tmp /opt].each do |p|
        err = assert_raises(Pikuri::Workspace::Filesystem::Error) { described_class.new(project_root: p) }
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

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        described_class.new(project_root: candidate.to_s)
      end
      assert_includes err.message, 'system or home root'
    end

    it 'accepts a normal project dir under /home/<user>/...' do
      # Build a nested dir under root (which itself is in /tmp/...). Verifies
      # the denylist doesn't false-positive on deep paths.
      project = root + 'project'
      FileUtils.mkdir_p(project)
      ws = described_class.new(project_root: project.to_s)
      assert_equal project.realpath, ws.project_root
    end
  end

  describe 'edge cases' do
    it 'resolves the project_root itself (no traversal)' do
      assert_equal root, workspace.resolve_for_read('.')
      assert_equal root, workspace.resolve_for_read('')
    end
  end
end
