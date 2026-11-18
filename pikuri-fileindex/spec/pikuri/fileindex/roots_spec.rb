# frozen_string_literal: true

RSpec.describe Pikuri::Fileindex::Roots do
  around { |example| RootTree.with { |tmp| @tmp = tmp; example.run } }

  def docs = "#{@tmp}/docs"
  def roots = described_class.new(dirs: [docs])

  describe '.new' do
    it 'refuses no folders, a relative one, a missing one and a file' do
      { [] => 'at least one folder', ['docs'] => "absolute path, got 'docs'",
        ["#{@tmp}/nope"] => 'does not exist', ["#{docs}/note.txt"] => 'is not a folder' }.each do |dirs, message|
        err = assert_raises(ArgumentError, dirs.inspect) { described_class.new(dirs: dirs) }
        assert_includes err.message, message
      end
    end

    it 'keeps each root as its real path, once' do
      assert_equal ["#{@tmp}/work", docs],
                   described_class.new(dirs: ["#{docs}/link", "#{docs}/tax/..", docs]).dirs
    end

    it 'declares neither leg by default' do
      assert_equal [false, false], [roots.private, roots.trusted]
    end
  end

  describe '#resolve' do
    it 'answers the real path of a path inside a root, or of the root itself' do
      assert_equal "#{docs}/note.txt", roots.resolve("#{docs}/tax/../note.txt")
      assert_equal docs, roots.resolve(docs)
      assert_equal docs, roots.resolve("#{docs}/")
    end

    it 'judges a path that is not on disk by its folder' do
      assert_equal "#{docs}/tax/gone.pdf", roots.resolve("#{docs}/tax/gone.pdf")
      assert_nil roots.resolve("#{docs}/link/gone.pdf"), 'the symlink leads outside'
    end

    it 'refuses a path outside every root, however it gets there' do
      ["#{@tmp}/work/a.txt", "#{docs}/../work/a.txt", "#{docs}/link/a.txt", "#{docs}-old/a.txt", '/etc/passwd',
       '~nosuchuser/a'].each do |path|
        assert_nil roots.resolve(path), path
      end
    end

    it 'refuses a hidden file or folder below a root, but not a hidden folder above it' do
      assert_nil roots.resolve("#{docs}/.hidden")
      assert_nil roots.resolve("#{docs}/tax/.env")
      hidden_parent = File.join(@tmp, '.cache', 'corpus')
      FileUtils.mkdir_p(hidden_parent)
      assert_equal "#{hidden_parent}/a.txt", described_class.new(dirs: [hidden_parent]).resolve("#{hidden_parent}/a.txt")
    end

    it 'covers a path under any of several roots' do
      both = described_class.new(dirs: [docs, "#{@tmp}/work"])
      assert_equal "#{@tmp}/work/a.txt", both.resolve("#{@tmp}/work/a.txt")
      assert_equal "#{docs}/a.txt", both.resolve("#{docs}/a.txt")
    end
  end
end
