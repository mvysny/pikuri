# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'

# No vector backend anywhere in this file — the point of the keyword store
# being its own class is that it answers on its own.
describe Pikuri::Rag::Backend::Fts5 do
  let(:fts) { Pikuri::Rag::Backend::Fts5.new }

  def chunk(id, source, text, hash: 'h1', offset: 0)
    Pikuri::VectorDb::Chunk.new(id: id, source: source, text: text,
                                metadata: { offset: offset, hash: hash })
  end

  def populate
    fts.upsert(chunks: [
                 chunk('acme.md:0', 'acme.md', 'Acme agreed to hold list pricing through Q1.'),
                 chunk('acme.md:1', 'acme.md', 'Their meetings run long; invoice 4471 outstanding.',
                       offset: 1),
                 chunk('initech.md:0', 'initech.md', 'Initech pricing discussion deferred.',
                       hash: 'h2')
               ])
  end

  after { fts.close }

  describe 'the write half of the backend protocol' do
    it 'counts what it stored' do
      populate
      assert_equal 3, fts.count
    end

    it 'replaces by chunk id rather than duplicating the row' do
      populate
      fts.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing frozen.')])
      assert_equal 3, fts.count
      assert_equal [['acme.md', 1]], fts.find(terms: ['"frozen"'])
    end

    it 'replaces every chunk of one document' do
      populate
      fts.replace_source(source: 'acme.md',
                         chunks: [chunk('acme.md:0', 'acme.md', 'Acme renewed.', hash: 'h9')])
      assert_equal 2, fts.count
      assert_equal [], fts.find(terms: ['"invoice"'])
      assert_equal({ 'acme.md' => 'h9', 'initech.md' => 'h2' }, fts.sources_with_hashes)
    end

    it 'deletes one document, and all of them' do
      populate
      fts.delete_by_source('acme.md')
      assert_equal 1, fts.count
      fts.delete_all
      assert_equal 0, fts.count
    end

    it 'is a no-op deleting a source it never held' do
      populate
      fts.delete_by_source('nope.md')
      assert_equal 3, fts.count
    end
  end

  describe 'the bookkeeping reads' do
    it 'reports one hash per source, for the reconcile sweep' do
      populate
      assert_equal({ 'acme.md' => 'h1', 'initech.md' => 'h2' }, fts.sources_with_hashes)
    end

    it 'answers membership per source' do
      populate
      assert fts.source_indexed?('acme.md')
      refute fts.source_indexed?('nope.md')
    end
  end

  describe '#keyword_query' do
    it 'ranks by bm25, best first' do
      populate
      hits = fts.keyword_query(match: '"pricing"', top_k: 5)
      # initech.md is the shorter document, so bm25's length normalization
      # puts it first for the same single match.
      assert_equal %w[initech.md acme.md], hits.map { |h| h.chunk.source }
      assert hits.first.score >= hits.last.score, 'scores must be descending'
    end

    it 'rebuilds the chunk, so hits fuse with a vector leg by id' do
      populate
      hit = fts.keyword_query(match: '"invoice"', top_k: 1).first
      assert_equal 'acme.md:1', hit.chunk.id
      assert_equal 'h1', hit.chunk.metadata[:hash]
      assert_includes hit.chunk.text, '4471'
    end

    it 'honours top_k' do
      populate
      assert_equal 1, fts.keyword_query(match: '"pricing"', top_k: 1).length
    end

    it 'stems English with porter' do
      populate
      assert_equal 1, fts.keyword_query(match: '"meeting"', top_k: 5).length
    end

    it 'does not match a word that only appears in the filename' do
      populate
      assert_equal [], fts.keyword_query(match: '"md"', top_k: 5)
    end

    it 'refuses a non-positive top_k' do
      assert_raises(ArgumentError) { fts.keyword_query(match: '"x"', top_k: 0) }
    end
  end

  describe '#find' do
    it 'lists every source holding the term, with its matching-chunk count' do
      populate
      assert_equal [['acme.md', 1]], fts.find(terms: ['"invoice"'])
      assert_equal [['acme.md', 1], ['initech.md', 1]], fts.find(terms: ['"pricing"']).sort
    end

    # The regression: FTS5's own implicit AND is row-scoped, and a row is a
    # chunk — so a juxtaposed MATCH would answer "no such document" about
    # acme.md, whose "Acme" is in chunk 0 and whose "invoice" is in chunk 1.
    it 'ANDs across the whole document, not within one chunk' do
      populate
      assert_equal [['acme.md', 2]], fts.find(terms: ['"acme"', '"invoice"'])
    end

    it 'counts a chunk once however many terms it holds' do
      populate
      # Both words are in acme.md:0 alone, so the union is that one chunk.
      assert_equal [['acme.md', 1]], fts.find(terms: ['"agreed"', '"pricing"'])
    end

    it 'excludes a source missing any one term' do
      populate
      assert_equal [], fts.find(terms: ['"acme"', '"kubernetes"'])
      assert_equal [], fts.find(terms: ['"initech"', '"invoice"'])
    end

    it 'is empty when nothing matches' do
      populate
      assert_equal [], fts.find(terms: ['"kubernetes"'])
    end

    it 'refuses an empty term list rather than matching everything' do
      populate
      assert_raises(ArgumentError) { fts.find(terms: []) }
    end
  end

  describe 'the store' do
    it 'defaults to an in-process index' do
      assert_equal ':memory:', fts.store
    end

    it 'reloads a file-backed index without re-indexing' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'fts.sqlite3')
        first = Pikuri::Rag::Backend::Fts5.new(store: path)
        first.upsert(chunks: [chunk('acme.md:0', 'acme.md', 'Acme pricing.')])
        first.close

        second = Pikuri::Rag::Backend::Fts5.new(store: path)
        assert_equal path, second.store
        assert_equal [['acme.md', 1]], second.find(terms: ['"pricing"'])
        second.close
      end
    end
  end
end
