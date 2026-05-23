# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Filesystem do
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

    it 'raises on an absolute path outside the anchor' do
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

  describe 'anchor denylist' do
    it 'rejects /' do
      err = assert_raises(Pikuri::Workspace::Filesystem::Error) { described_class.new(anchor: '/') }
      assert_includes err.message, 'system or home root'
    end

    it 'rejects /etc, /var, /proc, /usr, /tmp, /opt' do
      %w[/etc /var /proc /usr /tmp /opt].each do |p|
        err = assert_raises(Pikuri::Workspace::Filesystem::Error) { described_class.new(anchor: p) }
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

RSpec.describe Pikuri::Workspace::Filesystem::AllowAll do
  let(:root)    { Pathname.new(Dir.mktmpdir('pikuri-allowall-root-')).realpath }
  let(:outside) { Pathname.new(Dir.mktmpdir('pikuri-allowall-outside-')).realpath }
  let(:fake_home) { Pathname.new(Dir.mktmpdir('pikuri-allowall-home-')).realpath }
  let(:workspace) { described_class.new(anchor: root) }

  after do
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(outside)
    FileUtils.rm_rf(fake_home)
  end

  describe 'unrestricted resolution' do
    it 'resolves arbitrary paths outside the anchor (read)' do
      File.write(outside + 'data.txt', 'x')
      assert_equal outside + 'data.txt', workspace.resolve_for_read((outside + 'data.txt').to_s)
    end

    it 'resolves arbitrary paths outside the anchor (write)' do
      assert_equal outside + 'new.rb', workspace.resolve_for_write((outside + 'new.rb').to_s)
    end

    it 'resolves a path whose intermediate directories do not exist' do
      assert_equal outside + 'a/b/c.rb', workspace.resolve_for_write((outside + 'a/b/c.rb').to_s)
    end

    it 'resolves relative paths against the anchor' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'lib/foo.rb', 'x')
      assert_equal root + 'lib/foo.rb', workspace.resolve_for_read('lib/foo.rb')
    end

    it 'resolves a symlink that points outside the anchor' do
      File.write(outside + 'target', 'x')
      File.symlink(outside.to_s, (root + 'link').to_s)
      assert_equal outside + 'target', workspace.resolve_for_read('link/target')
    end
  end

  describe 'anchor + temp' do
    it 'accepts a root anchor that the base Filesystem would reject' do
      # Don't actually anchor at /; just verify validate_anchor! is skipped.
      ws = described_class.new(anchor: '/')
      assert_equal Pathname.new('/').realpath, ws.cwd
    end

    it 'mints a temp playground when temp: true' do
      ws = described_class.new(anchor: root, temp: true)
      assert ws.temp.exist?
      assert_includes ws.writable, ws.temp
    ensure
      FileUtils.remove_entry(ws.temp.to_s) if ws&.temp&.exist?
    end

    it 'advertises the whole filesystem via readable / writable' do
      assert_includes workspace.readable, Pathname.new('/').realpath
      assert_includes workspace.writable, Pathname.new('/').realpath
    end
  end

  describe 'credential denylist' do
    # Stub HOME to a tmpdir so we can populate fake credential dirs without
    # touching the developer's real ones. The constant snapshots HOME at
    # class-load time, so override the constant for the duration of these
    # specs.
    before do
      @original_denylist = described_class::CREDENTIAL_DENYLIST
      per_home = %w[.ssh .aws .gnupg .docker .kube .netrc]
      stub_list = per_home.map { |p| Pathname.new(File.join(fake_home, p)) }
                          .push(Pathname.new('/etc/shadow'))
      described_class.send(:remove_const, :CREDENTIAL_DENYLIST)
      described_class.const_set(:CREDENTIAL_DENYLIST, stub_list.freeze)
    end

    after do
      described_class.send(:remove_const, :CREDENTIAL_DENYLIST)
      described_class.const_set(:CREDENTIAL_DENYLIST, @original_denylist)
    end

    it 'rejects reads into a denied directory' do
      FileUtils.mkdir_p(fake_home + '.ssh')
      File.write(fake_home + '.ssh/id_rsa', 'secret')

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read((fake_home + '.ssh/id_rsa').to_s)
      end
      assert_includes err.message, 'denied credential location'
    end

    it 'rejects writes into a denied directory (file does not yet exist)' do
      FileUtils.mkdir_p(fake_home + '.ssh')

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_write((fake_home + '.ssh/new_evil').to_s)
      end
      assert_includes err.message, 'denied credential location'
    end

    it 'rejects writes that would CREATE a denied directory not yet present' do
      # Attack: container has no ~/.gnupg yet; agent plants a keyring
      # there for a later GPG operation to pick up. Lexical fallback
      # blocks this even though +.gnupg+ doesn't realpath.
      refute (fake_home + '.gnupg').exist?

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_write((fake_home + '.gnupg/keyring').to_s)
      end
      assert_includes err.message, 'denied credential location'
    end

    it 'rejects a symlink whose target is a denied path' do
      FileUtils.mkdir_p(fake_home + '.ssh')
      File.write(fake_home + '.ssh/id_rsa', 'secret')
      File.symlink((fake_home + '.ssh/id_rsa').to_s, (root + 'decoy').to_s)

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read('decoy')
      end
      assert_includes err.message, 'denied credential location'
    end

    it 'rejects a symlinked denied directory' do
      # Simulate: ~/.ssh is itself a symlink to a non-conventionally-named
      # location (e.g. /data/keys). Access via the resolved path still
      # gets caught because we realpath the denylist entry.
      real_ssh = Pathname.new(Dir.mktmpdir('pikuri-real-ssh-')).realpath
      File.write(real_ssh + 'id_rsa', 'secret')
      File.symlink(real_ssh.to_s, (fake_home + '.ssh').to_s)

      err = assert_raises(Pikuri::Workspace::Filesystem::Error) do
        workspace.resolve_for_read((real_ssh + 'id_rsa').to_s)
      end
      assert_includes err.message, 'denied credential location'
    ensure
      FileUtils.rm_rf(real_ssh) if real_ssh
    end

    it 'accepts a path that looks like ~/.ssh but lives elsewhere' do
      # /var/cache/.ssh-config-backup is NOT under the user's ~/.ssh —
      # don't false-positive on substring matches.
      decoy_dir = root + 'cache'
      FileUtils.mkdir_p(decoy_dir)
      File.write(decoy_dir + '.ssh-backup', 'x')

      result = workspace.resolve_for_read((decoy_dir + '.ssh-backup').to_s)
      assert_equal decoy_dir + '.ssh-backup', result
    end

    it 'accepts non-credential paths under the home dir' do
      FileUtils.mkdir_p(fake_home + 'projects')
      File.write(fake_home + 'projects/code.rb', 'x')

      result = workspace.resolve_for_read((fake_home + 'projects/code.rb').to_s)
      assert_equal fake_home + 'projects/code.rb', result
    end
  end

  describe 'CREDENTIAL_DENYLIST (default)' do
    it 'covers ~/.ssh / ~/.aws / ~/.gnupg / ~/.docker / ~/.kube / ~/.netrc' do
      basenames = described_class::CREDENTIAL_DENYLIST.map { |p| p.basename.to_s }
      %w[.ssh .aws .gnupg .docker .kube .netrc].each do |b|
        assert_includes basenames, b
      end
    end

    it 'covers /etc/shadow' do
      assert_includes described_class::CREDENTIAL_DENYLIST.map(&:to_s), '/etc/shadow'
    end

    it 'covers /root/.ssh in addition to the current user' do
      assert_includes described_class::CREDENTIAL_DENYLIST.map(&:to_s), '/root/.ssh'
    end
  end
end
