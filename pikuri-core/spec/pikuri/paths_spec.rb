# frozen_string_literal: true

RSpec.describe Pikuri::Paths do
  around do |example|
    saved = ENV.values_at('XDG_CACHE_HOME', 'XDG_CONFIG_HOME')
    example.run
  ensure
    %w[XDG_CACHE_HOME XDG_CONFIG_HOME].each_with_index do |key, i|
      saved[i].nil? ? ENV.delete(key) : ENV[key] = saved[i]
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

  describe '.config' do
    it 'is <XDG_CONFIG_HOME>/pikuri when XDG_CONFIG_HOME is set' do
      ENV['XDG_CONFIG_HOME'] = '/tmp/some-cfg'
      assert_equal '/tmp/some-cfg/pikuri', Pikuri::Paths.config.to_s
    end

    it 'falls back to ~/.config/pikuri when XDG_CONFIG_HOME is unset' do
      ENV.delete('XDG_CONFIG_HOME')
      assert_equal File.expand_path('~/.config/pikuri'), Pikuri::Paths.config.to_s
    end

    it 'falls back to ~/.config/pikuri when XDG_CONFIG_HOME is empty' do
      ENV['XDG_CONFIG_HOME'] = ''
      assert_equal File.expand_path('~/.config/pikuri'), Pikuri::Paths.config.to_s
    end

    it 'returns a Pathname so callers can chain #join' do
      ENV['XDG_CONFIG_HOME'] = '/tmp/cfg'
      assert_kind_of Pathname, Pikuri::Paths.config
      assert_equal '/tmp/cfg/pikuri/MACHINE.md', Pikuri::Paths.config.join('MACHINE.md').to_s
    end
  end
end
