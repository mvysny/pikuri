# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Workspace do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-ws-root-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }
  let(:workspace)  { described_class.new(filesystem: filesystem) }

  after { FileUtils.rm_rf(root) }

  describe 'Filesystem facade' do
    it 'delegates resolve_for_read/resolve_for_write/project_root to the filesystem' do
      assert_equal filesystem.project_root, workspace.project_root
      assert_equal filesystem.resolve_for_read('a.txt'), workspace.resolve_for_read('a.txt')
      assert_equal filesystem.resolve_for_write('a.txt'), workspace.resolve_for_write('a.txt')
    end

    it 'exposes the wrapped filesystem' do
      assert_same filesystem, workspace.filesystem
    end
  end

  describe '#mark_read / #read?' do
    it 'reports false until a path is marked, true after' do
      resolved = workspace.resolve_for_read('lib/foo.rb')

      refute workspace.read?(resolved)
      workspace.mark_read(resolved)
      assert workspace.read?(resolved)
    end

    it 'keys on the resolved path regardless of how the same file was addressed' do
      FileUtils.mkdir_p(root + 'lib')
      File.write(root + 'lib/foo.rb', "x\n")

      workspace.mark_read(workspace.resolve_for_read('lib/foo.rb'))

      # An absolute path and a relative path to the same file resolve
      # equal, so the read record recognizes both.
      assert workspace.read?(workspace.resolve_for_read((root + 'lib/foo.rb').to_s))
    end

    it 'is idempotent' do
      resolved = workspace.resolve_for_write('foo.rb')
      workspace.mark_read(resolved)
      workspace.mark_read(resolved)

      assert workspace.read?(resolved)
    end
  end

  describe 'read-record isolation' do
    it 'does not share its record with another workspace over the same filesystem' do
      other = described_class.new(filesystem: filesystem)
      resolved = workspace.resolve_for_read('shared.rb')

      workspace.mark_read(resolved)

      assert workspace.read?(resolved)
      refute other.read?(other.resolve_for_read('shared.rb')),
             'each workspace owns its own read record'
    end
  end
end
