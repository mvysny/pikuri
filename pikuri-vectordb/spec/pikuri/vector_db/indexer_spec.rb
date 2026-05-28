# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'pathname'

describe Pikuri::VectorDb::Indexer do
  let(:root) { Pathname.new(Dir.mktmpdir('pikuri-vectordb-indexer-')).realpath }
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Deterministic fakes. The chunker word-splits (one chunk per
  # word); the embedder returns a 3-dim vector whose first
  # component is the text length, second/third are constants —
  # ensures vectors are distinct per chunk while staying easy
  # to read in failure messages.
  let(:fake_chunker) do
    obj = Object.new
    def obj.chunk(text)
      text.split(' ')
    end
    obj
  end

  let(:fake_embedder) do
    obj = Object.new
    def obj.embed(texts)
      texts.map { |t| [t.length.to_f, 0.5, 0.5] }
    end
    obj
  end

  def write(rel, content)
    path = root + rel
    FileUtils.mkdir_p(path.dirname)
    File.write(path, content)
    path
  end

  def build_indexer(source: root.to_s)
    Pikuri::VectorDb::Indexer.new(
      backend: backend, source: source,
      embedder: fake_embedder, chunker: fake_chunker
    )
  end

  after { FileUtils.rm_rf(root) }

  describe '#index_all!' do
    it 'walks a directory, indexes files, returns total chunks' do
      write('a.md', 'one two three')
      write('b.md', 'four five')

      total = build_indexer.index_all!

      assert_equal 5, total
      assert_equal 5, backend.count
    end

    it 'sets Chunk.source to the path relative to the source root' do
      write('notes/cooking/risotto.md', 'rice butter wine')

      build_indexer.index_all!

      hits = backend.query(vector: [3.0, 0.5, 0.5], top_k: 5)
      sources = hits.map { |r| r.chunk.source }.uniq
      assert_equal ['notes/cooking/risotto.md'], sources
    end

    it 'formats Chunk.id as "source:index"' do
      write('doc.md', 'alpha beta gamma')

      build_indexer.index_all!

      hits = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).sort_by { |h| h.chunk.id }
      assert_equal %w[doc.md:0 doc.md:1 doc.md:2], hits.map { |h| h.chunk.id }
    end

    it 'stores the chunk offset in metadata' do
      write('doc.md', 'alpha beta gamma')

      build_indexer.index_all!

      hits = backend.query(vector: [5.0, 0.5, 0.5], top_k: 5).sort_by { |h| h.chunk.metadata[:offset] }
      assert_equal [0, 1, 2], hits.map { |h| h.chunk.metadata[:offset] }
    end

    it 'skips dot-files and dot-directories' do
      write('visible.md', 'foo bar')
      write('.env', 'SECRET=hunter2')
      write('.obsidian/config.json', '{}')

      total = build_indexer.index_all!

      assert_equal 2, total
      sources = backend.query(vector: [3.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['visible.md'], sources
    end

    it 'skips DENYLIST directories (.git, node_modules, target, ...)' do
      write('doc.md', 'kept')
      write('node_modules/foo/bar.js', 'should not')
      write('target/build.log', 'should not')
      write('venv/lib/python3.10/site-packages/foo.py', 'should not')

      total = build_indexer.index_all!

      assert_equal 1, total
    end

    it 'WARNs and skips images / binary files via FileType refusal' do
      write('readable.md', 'kept content')
      # PNG magic — caught by FileType.read_as_text and surfaced as ArgumentError
      File.binwrite(root + 'photo.png', "\x89PNG\r\n\x1a\n".b + ('x' * 32).b)

      total = build_indexer.index_all!

      assert_equal 2, total # "kept" + "content"
      sources = backend.query(vector: [4.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['readable.md'], sources
    end

    it 'WARNs and skips files with no extractable text' do
      write('empty.md', '')
      write('present.md', 'real content')

      total = build_indexer.index_all!

      assert_equal 2, total # "real" + "content"
    end

    it 'accepts a source that points at a single file' do
      write('docs/b.md', 'two three')
      indexer = build_indexer(source: (root + 'docs/b.md').to_s)

      total = indexer.index_all!

      assert_equal 2, total # "two" + "three"
      # Single-file source uses the parent dir as the root, so
      # +Chunk.source+ is the file basename.
      sources = backend.query(vector: [3.0, 0.5, 0.5], top_k: 10).map { |r| r.chunk.source }.uniq
      assert_equal ['b.md'], sources
    end

    it 'WARNs when the source path does not exist' do
      indexer = build_indexer(source: (root + 'phantom').to_s)

      total = indexer.index_all!

      assert_equal 0, total
    end

    it 'returns 0 when no indexable files are found' do
      total = build_indexer.index_all!
      assert_equal 0, total
    end

    it 'visits files in deterministic (sorted) order' do
      write('z.md', 'last')
      write('a.md', 'first')
      write('m.md', 'middle')

      build_indexer.index_all!

      ids = backend.query(vector: [4.0, 0.5, 0.5], top_k: 10).map { |h| h.chunk.id }.sort
      # Sources sorted alphabetically: a, m, z. Each has one chunk (one word) so id is "name.md:0".
      assert_equal ['a.md:0', 'm.md:0', 'z.md:0'], ids
    end
  end

  describe '#reindex!' do
    it 'nukes the backend then indexes everything' do
      write('a.md', 'foo bar')
      indexer = build_indexer
      indexer.index_all!
      assert_equal 2, backend.count

      # Add a second file after the first indexing and reindex.
      write('b.md', 'baz')
      indexer.reindex!

      # If reindex weren't nuking first, we'd see 2 (from first) + 3 (from second) = 5.
      assert_equal 3, backend.count
    end
  end

  describe '#index_if_empty!' do
    it 'runs index_all! when the backend is empty' do
      write('a.md', 'word')

      total = build_indexer.index_if_empty!

      assert_equal 1, total
    end

    it 'skips when the backend already has entries' do
      # Pre-populate the backend so its count is positive
      chunk = Pikuri::VectorDb::Chunk.new(id: 'preexisting:0', source: 'preexisting', text: 'old', metadata: {})
      backend.upsert(chunks: [chunk], vectors: [[1.0, 0.0, 0.0]])
      write('a.md', 'new content')

      total = build_indexer.index_if_empty!

      assert_equal 0, total
      assert_equal 1, backend.count # unchanged
    end
  end
end
