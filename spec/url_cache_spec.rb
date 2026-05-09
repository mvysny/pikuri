# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tmpdir'
require 'url_cache'

RSpec.describe UrlCache do
  let(:tmp) { Dir.mktmpdir('url_cache_spec') }
  after { FileUtils.remove_entry(tmp) }

  let(:cache) { UrlCache.new(ttl: 60, dir: tmp) }

  describe '#fetch' do
    it 'yields and stores on miss' do
      calls = 0
      result = cache.fetch('https://example.com') do
        calls += 1
        'payload'
      end
      assert_equal 'payload', result
      assert_equal 1, calls
      assert_equal 'payload', File.read(cache.path_for('https://example.com'))
    end

    it 'returns the stored value on hit without yielding' do
      cache.fetch('https://example.com') { 'first' }
      result = cache.fetch('https://example.com') { raise 'should not be called' }
      assert_equal 'first', result
    end

    it 're-yields when the entry is older than the TTL' do
      cache.fetch('https://example.com') { 'first' }
      old = Time.now - 120
      File.utime(old, old, cache.path_for('https://example.com'))

      result = cache.fetch('https://example.com') { 'second' }
      assert_equal 'second', result
    end

    it 'does not write a file when the block raises' do
      assert_raises(RuntimeError) do
        cache.fetch('https://example.com') { raise 'boom' }
      end
      refute File.exist?(cache.path_for('https://example.com'))
    end

    it 'isolates entries by key' do
      cache.fetch('a') { 'A' }
      cache.fetch('b') { 'B' }
      assert_equal 'A', cache.fetch('a') { raise 'should not be called' }
      assert_equal 'B', cache.fetch('b') { raise 'should not be called' }
    end

    it 'creates the cache directory lazily on first write' do
      sub  = File.join(tmp, 'nested', 'cache')
      lazy = UrlCache.new(ttl: 60, dir: sub)
      refute File.directory?(sub)

      lazy.fetch('x') { 'y' }
      assert File.directory?(sub)
    end
  end

  describe '#path_for' do
    it 'names files by SHA-256 hex digest of the key' do
      key    = 'https://example.com'
      digest = Digest::SHA256.hexdigest(key)
      assert_equal File.join(tmp, "#{digest}.txt"), cache.path_for(key)
    end
  end
end
