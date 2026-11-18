# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Recoll.unavailable_reason against real recoll indexes built in a temp
# config dir; skipped on hosts without recoll, CI included.
RSpec.describe Pikuri::Fileindex::Recoll, 'against a real index' do
  around do |example|
    next skip('no recollq / recollindex on this host') unless PrivateLocalSearch.on_path?('recollindex')

    Dir.mktmpdir do |confdir|
      @confdir = confdir
      original = ENV['RECOLL_CONFDIR']
      ENV['RECOLL_CONFDIR'] = confdir
      begin
        example.run
      ensure
        ENV['RECOLL_CONFDIR'] = original
      end
    end
  end

  def docs = File.join(@confdir, 'docs')

  # Index +files+ (relative path => text) under a fresh topdirs folder.
  def build_index(files)
    files.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(docs, rel)))
      File.write(File.join(docs, rel), text)
    end
    FileUtils.mkdir_p(docs)
    File.write(File.join(@confdir, 'recoll.conf'), "topdirs = #{docs}\n")
    _, status = Open3.capture2e('recollindex', '-c', @confdir)
    raise "recollindex failed in #{@confdir}" unless status.success?
  end

  it 'is ready once the index holds a document under one of the folders' do
    build_index('a/x.txt' => 'hello lease agreement')
    FileUtils.mkdir_p(File.join(docs, 'b'))
    assert_nil described_class.unavailable_reason(folders: ["#{docs}/a", "#{docs}/b"])
  end

  it 'is not ready when no folder holds a document' do
    build_index('a/x.txt' => 'hello')
    FileUtils.mkdir_p(File.join(docs, 'b'))
    assert_includes described_class.unavailable_reason(folders: ["#{docs}/b"]),
                    "nothing under #{docs}/b is in the index in #{@confdir}"
  end

  it 'is not ready before recollindex ever ran' do
    assert_equal "no index in #{@confdir} yet. Build one with `recollindex`.",
                 described_class.unavailable_reason(folders: ['/'])
  end

  it 'searches under any of several folders, and nowhere else' do
    build_index('a/x.txt' => 'zebra one', 'b/y.txt' => 'zebra two', 'c/z.txt' => 'zebra three')
    hits = described_class.search(query: 'zebra', limit: 10, folders: ["#{docs}/a", "#{docs}/b"])
    assert_equal ["#{docs}/a/x.txt", "#{docs}/b/y.txt"], hits.map { |hit| hit[:path] }.sort
  end

  it 'indexes a hidden file, which fileindex_search then neither shows nor counts' do
    build_index('a.txt' => 'zebra shown', 'c.txt' => 'zebra too', '.hid/b.txt' => 'zebra hidden')
    assert_equal 3, described_class.search(query: 'zebra', limit: 10, folders: [docs]).size
    assert_equal 3, described_class.paths(query: 'zebra', folders: [docs]).size

    roots = Pikuri::Fileindex::Roots.new(dirs: [docs])
    result = Pikuri::Fileindex::Search.search(query: 'zebra', backend: described_class, roots: roots)
    assert_includes result.to_s, "#{docs}/a.txt"
    refute_includes result.to_s, '.hid'
    assert_equal 'Found 2 files', result.summary
    assert_equal 'Found 1 of 2 files',
                 Pikuri::Fileindex::Search.search(query: 'zebra', limit: 1, backend: described_class, roots: roots).summary
  end
end
