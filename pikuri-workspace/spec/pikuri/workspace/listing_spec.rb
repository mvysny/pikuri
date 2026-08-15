# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

RSpec.describe Pikuri::Workspace::Listing do
  let(:root)       { Pathname.new(Dir.mktmpdir('pikuri-listing-')).realpath }
  let(:filesystem) { Pikuri::Workspace::Filesystem.new(project_root: root) }

  after { FileUtils.rm_rf(root) }

  def mkdir(rel)  = FileUtils.mkdir_p(root + rel)
  def write(rel, content = 'x')
    FileUtils.mkdir_p((root + rel).dirname)
    File.write(root + rel, content)
  end

  def render(dir = root, depth: 1, fs: filesystem)
    described_class.render(dir, filesystem: fs, depth: depth)
  end

  describe 'depth 1' do
    it 'lists directories first (slash-suffixed) then files, each group sorted' do
      mkdir('zeta')
      mkdir('alpha')
      write('b.txt')
      write('a.txt')

      rows = render(root).split("\n")

      assert_equal ['alpha/', 'zeta/', 'a.txt', 'b.txt'],
                   rows.map { |r| r.split('  ').first }
    end

    it 'includes dotfiles, as ls -a does' do
      write('.bashrc')
      mkdir('.config')

      result = render(root)

      assert_includes result, '.config/'
      assert_includes result, '.bashrc'
    end

    it 'never lists .git' do
      mkdir('.git/objects')
      write('README.md')

      refute_includes render(root), '.git'
    end

    it 'summarises each directory with its immediate child counts' do
      mkdir('lib/one')
      mkdir('lib/two')
      write('lib/a.rb')

      assert_includes render(root), 'lib/  [2 dirs, 1 file]'
    end

    it 'marks an empty directory rather than counting it as zero of each' do
      mkdir('empty')

      assert_equal 'empty/  [empty]', render(root)
    end

    it 'gives each file a human-readable size' do
      write('small.txt', 'x' * 512)
      write('big.txt', 'x' * 4300)

      result = render(root)

      assert_includes result, 'small.txt  512B'
      assert_includes result, 'big.txt  4.2K'
    end

    it 'returns "" for a directory with no entries' do
      assert_equal '', render(root)
    end

    it 'raises when the root itself cannot be opened' do
      assert_raises(Errno::ENOENT) { render(root + 'nope') }
    end
  end

  describe 'degradation' do
    it 'prints the errno class instead of a fake size for a dangling symlink' do
      File.symlink(root + 'gone.txt', root + 'link.txt')

      assert_equal 'link.txt  [Errno::ENOENT]', render(root)
    end

    it 'prints the errno class for a self-referential symlink' do
      File.symlink(root + 'loop', root + 'loop')

      assert_equal 'loop  [Errno::ELOOP]', render(root)
    end

    it 'prints the errno class for a directory it cannot open' do
      skip 'running as root — chmod 000 does not deny access' if Process.uid.zero?
      mkdir('locked')
      File.chmod(0o000, root + 'locked')

      begin
        assert_equal 'locked/  [Errno::EACCES]', render(root)
      ensure
        File.chmod(0o700, root + 'locked')
      end
    end
  end

  describe 'depth' do
    it 'indents children and drops the summary from an expanded directory' do
      mkdir('lib/pikuri/inner')
      write('lib/a.rb', 'x' * 2048)
      write('top.md')

      result = render(root, depth: 2)

      assert_equal "lib/\n  pikuri/  [1 dir, 0 files]\n  a.rb  2.0K\ntop.md  1B", result
    end

    it 'keeps the summary on directories at the deepest rendered level' do
      mkdir('a/b/c')

      assert_equal "a/\n  b/  [1 dir, 0 files]", render(root, depth: 2)
    end

    it 'marks an expanded directory that turns out to be empty' do
      mkdir('a/empty')

      assert_equal "a/\n  empty/  [empty]", render(root, depth: 2)
    end

    it 'clamps depth to the 1..MAX_DEPTH range' do
      mkdir('a/b/c/d/e')

      deep = render(root, depth: 99)
      flat = render(root, depth: 0)

      assert_equal render(root, depth: described_class::MAX_DEPTH), deep
      assert_equal render(root, depth: 1), flat
    end
  end

  describe 'truncation' do
    it 'head-truncates at MAX_BYTES with a marker and no partial row' do
      name = 'a' * 180
      300.times { |i| write(format('%s%03d.txt', name, i)) }

      result = render(root)
      rows = result.split("\n")

      assert_operator result.bytesize, :<, described_class::MAX_BYTES + 200
      assert_includes result, 'bytes omitted'
      assert_includes result, 'list a subdirectory instead'
      # every surviving row is whole — the cut lands on a newline
      rows.reject { |r| r.empty? || r.include?('omitted') }
          .each { |r| assert_match(/\Aa{180}\d{3}\.txt {2}1B\z/, r) }
    end
  end
end
