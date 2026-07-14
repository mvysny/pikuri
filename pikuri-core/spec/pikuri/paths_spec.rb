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

  describe '.new_temp' do
    around do |example|
      @sandbox = Dir.mktmpdir('paths-new-temp-spec-')
      ENV['XDG_CACHE_HOME'] = @sandbox
      example.run
    ensure
      FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
    end

    it 'makes a fresh dir under Paths.cache with the temp- prefix' do
      dir = Pikuri::Paths.new_temp
      assert dir.directory?, "expected #{dir} to exist"
      assert dir.to_s.start_with?(Pikuri::Paths.cache.realpath.to_s + File::SEPARATOR),
             "expected #{dir} under #{Pikuri::Paths.cache}"
      assert dir.basename.to_s.start_with?('temp-'),
             "expected basename to start with 'temp-', got #{dir.basename}"
    end

    it 'returns a different dir on each call (a factory, not a memoized accessor)' do
      refute_equal Pikuri::Paths.new_temp, Pikuri::Paths.new_temp
    end
  end

  describe '.sweep_stale_temps!' do
    around do |example|
      @sandbox = Dir.mktmpdir('paths-sweep-spec-')
      ENV['XDG_CACHE_HOME'] = @sandbox
      example.run
    ensure
      FileUtils.remove_entry(@sandbox) if @sandbox && File.directory?(@sandbox)
    end

    it 'reaps a temp-* dir whose mtime is older than the cutoff' do
      cache = Pikuri::Paths.cache
      FileUtils.mkdir_p(cache)
      stale = cache + 'temp-stale'
      FileUtils.mkdir_p(stale)
      FileUtils.touch(stale.to_s, mtime: Time.now - Pikuri::Paths::TEMP_STALE_SECONDS - 60)

      Pikuri::Paths.sweep_stale_temps!

      refute stale.exist?, "expected #{stale} to be swept"
    end

    it 'leaves a recent temp-* dir alone' do
      cache = Pikuri::Paths.cache
      FileUtils.mkdir_p(cache)
      fresh = cache + 'temp-fresh'
      FileUtils.mkdir_p(fresh)

      Pikuri::Paths.sweep_stale_temps!

      assert fresh.exist?, "expected #{fresh} to survive the sweep"
    end

    it 'ignores non-temp-* entries (persistent caches like url_cache/mem0 are untouched)' do
      cache = Pikuri::Paths.cache
      FileUtils.mkdir_p(cache)
      foreign = cache + 'url_cache'
      FileUtils.mkdir_p(foreign)
      FileUtils.touch(foreign.to_s, mtime: Time.now - Pikuri::Paths::TEMP_STALE_SECONDS - 60)

      Pikuri::Paths.sweep_stale_temps!

      assert foreign.exist?, 'sweep must only touch temp-* dirs'
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
