# frozen_string_literal: true

RSpec.describe Pikuri::Web::UrlCache::InMemory do
  let(:cache) { Pikuri::Web::UrlCache::InMemory.new(ttl: 60, max_entries: 3) }

  describe '#read / #write' do
    it 'reads nil for an absent key' do
      assert_nil cache.read('nope')
    end

    it 'reads back what was written' do
      cache.write('k', 'v')
      assert_equal 'v', cache.read('k')
    end

    it 'replaces an entry' do
      cache.write('k', 'old')
      cache.write('k', 'new')
      assert_equal 'new', cache.read('k')
    end

    it 'stores a frozen copy, leaving the caller\'s string alone' do
      value = +'v'
      stored = cache.write('k', value)
      assert stored.frozen?
      refute value.frozen?
      assert cache.read('k').frozen?
    end

    it 'treats an entry past its TTL as a miss' do
      expired = Pikuri::Web::UrlCache::InMemory.new(ttl: 0, max_entries: 3)
      expired.write('k', 'v')
      assert_nil expired.read('k')
    end

    it 'never expires with an infinite TTL' do
      forever = Pikuri::Web::UrlCache::InMemory.new(ttl: Float::INFINITY, max_entries: 3)
      forever.write('k', 'v')
      assert_equal 'v', forever.read('k')
    end
  end

  describe 'eviction' do
    it 'drops the oldest entry past max_entries' do
      %w[a b c d].each { |k| cache.write(k, k.upcase) }
      assert_nil cache.read('a')
      assert_equal %w[B C D], %w[b c d].map { |k| cache.read(k) }
    end

    it 'counts a hit as a use, so the least recently *used* goes' do
      %w[a b c].each { |k| cache.write(k, k.upcase) }
      cache.read('a')
      cache.write('d', 'D')
      assert_nil cache.read('b')
      assert_equal 'A', cache.read('a')
    end

    it 'counts a rewrite as a use' do
      %w[a b c].each { |k| cache.write(k, k.upcase) }
      cache.write('a', 'A2')
      cache.write('d', 'D')
      assert_nil cache.read('b')
      assert_equal 'A2', cache.read('a')
    end
  end

  describe '#fetch' do
    it 'yields on a miss and serves the stored value after' do
      calls = 0
      2.times { cache.fetch('k') { calls += 1; 'v' } }
      assert_equal 1, calls
      assert_equal 'v', cache.read('k')
    end

    it 'stores nothing when the block raises' do
      assert_raises(RuntimeError) { cache.fetch('k') { raise 'boom' } }
      assert_nil cache.read('k')
    end
  end

  it 'refuses a non-positive max_entries' do
    assert_raises(ArgumentError) { Pikuri::Web::UrlCache::InMemory.new(ttl: 60, max_entries: 0) }
  end
end
