# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Search::PageStore do
  let(:store) { described_class.new }

  def put(url, text: "text of #{url}", indexed_at: nil)
    store.store(url: url, title: "T #{url}", text: text, indexed_at: indexed_at)
  end

  it 'reads back a stored page by its 8-hex-digit handle' do
    handle = put('https://example.com/a', indexed_at: Time.utc(2026, 11, 10, 5, 22, 14))
    assert_match(/\A\h{8}\z/, handle)
    page = store.read(handle)
    assert_equal 'https://example.com/a', page.url
    assert_equal 'T https://example.com/a', page.title
    assert_equal 'text of https://example.com/a', page.text
    assert_equal Time.utc(2026, 11, 10, 5, 22, 14), page.indexed_at
  end

  it 'gives a URL the same handle on every store, the latest text winning' do
    first = put('https://example.com/a', text: 'old')
    assert_equal first, put('https://example.com/a', text: 'new')
    assert_equal 'new', store.read(first).text
  end

  it 'keys handles by a per-store secret, so two stores disagree' do
    other = described_class.new
    refute_equal put('https://example.com/a'),
                 other.store(url: 'https://example.com/a', title: 'A', text: 'x', indexed_at: nil)
  end

  it 'gives a URL whose 8-digit handle is taken by another URL a 12-digit one' do
    store.define_singleton_method(:digest) { |url| "aaaaaaaa#{url.end_with?('a') ? '1111' : '2222'}" + ('0' * 52) }
    first = put('https://example.com/a')
    second = put('https://example.com/b')
    assert_equal 'aaaaaaaa', first
    assert_equal 'aaaaaaaa2222', second
    assert_equal 'https://example.com/a', store.read(first).url
    assert_equal 'https://example.com/b', store.read(second).url
    assert_equal second, store.handle_for('https://example.com/b')
  end

  it 'answers handle_for with nil for a URL it never stored' do
    assert_nil store.handle_for('https://example.com/nope')
  end

  it 'forgives brackets, whitespace and case in a handle' do
    handle = put('https://example.com/a')
    assert_equal 'https://example.com/a', store.read(" [#{handle.upcase}] ").url
  end

  it 'reads nil for an unknown or malformed handle' do
    put('https://example.com/a')
    assert_nil store.read('00000000')
    assert_nil store.read('https://example.com/a')
    assert_nil store.read('../../etc')
    assert_nil store.read('')
  end

  it 'evicts the least recently used page past its cap' do
    small = described_class.new(cache: Pikuri::UrlCache::InMemory.new(ttl: Float::INFINITY, max_entries: 2))
    a = small.store(url: 'https://example.com/a', title: 'A', text: 'a', indexed_at: nil)
    small.store(url: 'https://example.com/b', title: 'B', text: 'b', indexed_at: nil)
    small.store(url: 'https://example.com/c', title: 'C', text: 'c', indexed_at: nil)
    assert_nil small.read(a)
  end
end
