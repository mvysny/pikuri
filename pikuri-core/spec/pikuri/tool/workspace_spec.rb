# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Tool::Workspace do
  describe 'abstract base' do
    let(:abstract) { described_class.new }

    it '#cwd raises NotImplementedError' do
      assert_raises(NotImplementedError) { abstract.cwd }
    end

    it '#resolve_for_read raises NotImplementedError' do
      assert_raises(NotImplementedError) { abstract.resolve_for_read('foo') }
    end

    it '#resolve_for_write raises NotImplementedError' do
      assert_raises(NotImplementedError) { abstract.resolve_for_write('foo') }
    end
  end

  describe Pikuri::Tool::Workspace::Cwd do
    let(:outside) { Pathname.new(Dir.mktmpdir('pikuri-ws-outside-')).realpath }
    let(:root)    { Pathname.new(Dir.mktmpdir('pikuri-ws-root-')).realpath }
    let(:workspace) { described_class.new(root: root) }

    after do
      FileUtils.rm_rf(outside)
      FileUtils.rm_rf(root)
    end

    describe '#cwd' do
      it 'returns the realpath of the configured root' do
        assert_equal root, workspace.cwd
      end
    end

    describe '#resolve_for_read / #resolve_for_write (same impl in v1)' do
      it 'resolves an existing file under the root' do
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

      it 'accepts an absolute path inside the workspace' do
        FileUtils.mkdir_p(root + 'lib')
        File.write(root + 'lib/foo.rb', 'x')

        result = workspace.resolve_for_read((root + 'lib/foo.rb').to_s)
        assert_equal root + 'lib/foo.rb', result
      end

      it 'transparently resolves a symlink that stays inside the workspace' do
        FileUtils.mkdir_p(root + 'sub')
        File.write(root + 'sub/target.rb', 'x')
        File.symlink((root + 'sub').to_s, (root + 'link').to_s)

        result = workspace.resolve_for_read('link/target.rb')
        # realpath of link/target.rb resolves through the symlink:
        assert_equal root + 'sub/target.rb', result
      end
    end

    describe 'containment errors' do
      it 'raises on .. escape (lexical traversal)' do
        err = assert_raises(Pikuri::Tool::Workspace::Error) do
          workspace.resolve_for_read('lib/../../../etc/passwd')
        end
        assert_includes err.message, 'outside the workspace'
      end

      it 'raises on an absolute path outside the root' do
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

    describe 'edge cases' do
      it 'resolves the root itself (no traversal)' do
        # No leaf component → resolves to root. Tools using this should
        # interpret as "the workspace root" rather than a specific file.
        assert_equal root, workspace.resolve_for_read('.')
        assert_equal root, workspace.resolve_for_read('')
      end
    end
  end
end
