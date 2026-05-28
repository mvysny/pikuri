# frozen_string_literal: true

require 'spec_helper'

describe Pikuri::VectorDb::Backend::InMemory do
  let(:backend) { Pikuri::VectorDb::Backend::InMemory.new }

  # Three orthogonal unit vectors in R^3 — easy to reason about
  # cosine values: v1·v2 = 0 (orthogonal), v1·v1 = 1 (identical),
  # v1·v_diag = sqrt(0.5) (45° between).
  let(:c_a) { Pikuri::VectorDb::Chunk.new(id: 'a', source: 'a.txt', text: 'apple',  metadata: {}) }
  let(:c_b) { Pikuri::VectorDb::Chunk.new(id: 'b', source: 'b.txt', text: 'banana', metadata: {}) }
  let(:c_c) { Pikuri::VectorDb::Chunk.new(id: 'c', source: 'c.txt', text: 'cherry', metadata: {}) }
  let(:v_a) { [1.0, 0.0, 0.0] }
  let(:v_b) { [0.0, 1.0, 0.0] }
  let(:v_c) { [0.0, 0.0, 1.0] }
  let(:v_diag) { [1.0, 1.0, 0.0] } # 45° from both v_a and v_b

  describe 'an empty store' do
    it 'reports count 0' do
      assert_equal 0, backend.count
    end

    it 'returns [] from #query (does not raise)' do
      assert_equal [], backend.query(vector: v_a, top_k: 5)
    end
  end

  describe '#upsert' do
    it 'stores chunks and increments count' do
      backend.upsert(chunks: [c_a, c_b], vectors: [v_a, v_b])
      assert_equal 2, backend.count
    end

    it 'replaces by id rather than appending' do
      backend.upsert(chunks: [c_a], vectors: [v_a])
      replacement = Pikuri::VectorDb::Chunk.new(
        id: 'a', source: 'a-renamed.txt', text: 'apricot', metadata: {}
      )
      backend.upsert(chunks: [replacement], vectors: [v_b])

      assert_equal 1, backend.count
      result = backend.query(vector: v_b, top_k: 1).first
      assert_equal 'apricot', result.chunk.text
      assert_equal 'a-renamed.txt', result.chunk.source
    end

    it 'raises on empty input' do
      assert_raises(ArgumentError) { backend.upsert(chunks: [], vectors: []) }
    end

    it 'raises on length mismatch' do
      assert_raises(ArgumentError) { backend.upsert(chunks: [c_a], vectors: [v_a, v_b]) }
      assert_raises(ArgumentError) { backend.upsert(chunks: [c_a, c_b], vectors: [v_a]) }
    end

    it 'raises when a subsequent upsert has a different vector dim' do
      backend.upsert(chunks: [c_a], vectors: [v_a]) # locks dim = 3
      assert_raises(ArgumentError) do
        backend.upsert(chunks: [c_b], vectors: [[1.0, 0.0]]) # dim 2
      end
    end

    it 'raises when a single upsert mixes vector dims' do
      assert_raises(ArgumentError) do
        backend.upsert(chunks: [c_a, c_b], vectors: [v_a, [1.0, 0.0]])
      end
    end
  end

  describe '#query' do
    before do
      backend.upsert(chunks: [c_a, c_b, c_c], vectors: [v_a, v_b, v_c])
    end

    it 'returns Result objects descending by cosine score' do
      results = backend.query(vector: v_a, top_k: 3)
      assert_equal 3, results.size
      results.each { |r| assert_kind_of Pikuri::VectorDb::Backend::Result, r }
      assert_equal %w[a b c].sort, results.map { |r| r.chunk.id }.sort
      # First hit is exact match against v_a; remaining two are orthogonal.
      assert_equal 'a', results.first.chunk.id
      assert_in_delta 1.0, results.first.score, 0.0001
      assert_in_delta 0.0, results.last.score, 0.0001
    end

    it 'honors top_k' do
      results = backend.query(vector: v_a, top_k: 1)
      assert_equal 1, results.size
      assert_equal 'a', results.first.chunk.id
    end

    it 'computes cosine correctly for an in-between query' do
      # v_diag = [1, 1, 0]; |v_diag| = sqrt(2); cosine with v_a = 1/sqrt(2)
      results = backend.query(vector: v_diag, top_k: 3)
      # v_a and v_b should tie; v_c orthogonal.
      assert_in_delta Math.sqrt(0.5), results[0].score, 0.0001
      assert_in_delta Math.sqrt(0.5), results[1].score, 0.0001
      assert_in_delta 0.0, results[2].score, 0.0001
      assert_equal 'c', results[2].chunk.id
    end

    it 'raises on non-positive top_k' do
      assert_raises(ArgumentError) { backend.query(vector: v_a, top_k: 0) }
      assert_raises(ArgumentError) { backend.query(vector: v_a, top_k: -5) }
    end

    it 'raises when the query vector dim differs from the stored dim' do
      assert_raises(ArgumentError) { backend.query(vector: [1.0, 0.0], top_k: 1) }
    end

    it 'returns 0.0 score for a zero query vector (degenerate but valid)' do
      results = backend.query(vector: [0.0, 0.0, 0.0], top_k: 3)
      assert_equal 3, results.size
      results.each { |r| assert_in_delta 0.0, r.score, 0.0001 }
    end
  end

  describe '#delete_all' do
    it 'empties the store' do
      backend.upsert(chunks: [c_a, c_b], vectors: [v_a, v_b])
      backend.delete_all
      assert_equal 0, backend.count
      assert_equal [], backend.query(vector: v_a, top_k: 5)
    end

    it 'releases the dim lock so a re-index with a new embedder dim starts clean' do
      backend.upsert(chunks: [c_a], vectors: [v_a]) # locks dim = 3
      backend.delete_all
      # Now a different dim is allowed:
      backend.upsert(chunks: [c_b], vectors: [[1.0, 0.0]])
      assert_equal 1, backend.count
    end
  end
end
