# frozen_string_literal: true

RSpec.describe Pikuri::Paths do
  around do |example|
    original = ENV['XDG_CACHE_HOME']
    example.run
  ensure
    if original.nil?
      ENV.delete('XDG_CACHE_HOME')
    else
      ENV['XDG_CACHE_HOME'] = original
    end
  end

  describe '.cache' do
    it 'is <XDG_CACHE_HOME>/pikuri when XDG_CACHE_HOME is set' do
      ENV['XDG_CACHE_HOME'] = '/tmp/some-cache'
      assert_equal '/tmp/some-cache/pikuri', Pikuri::Paths.cache.to_s
    end

    it 'falls back to ~/.cache/pikuri when XDG_CACHE_HOME is unset' do
      ENV.delete('XDG_CACHE_HOME')
      assert_equal File.expand_path('~/.cache/pikuri'), Pikuri::Paths.cache.to_s
    end

    it 'falls back to ~/.cache/pikuri when XDG_CACHE_HOME is empty' do
      ENV['XDG_CACHE_HOME'] = ''
      assert_equal File.expand_path('~/.cache/pikuri'), Pikuri::Paths.cache.to_s
    end

    it 'returns a Pathname so callers can chain #join' do
      ENV['XDG_CACHE_HOME'] = '/tmp/c'
      assert_kind_of Pathname, Pikuri::Paths.cache
      assert_equal '/tmp/c/pikuri/mem0', Pikuri::Paths.cache.join('mem0').to_s
    end
  end
end
