# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Pikuri::Tool::Search::Engines, '#providers' do
  it 'lists only DuckDuckGo when no provider keys are given' do
    assert_equal %w[DuckDuckGo], described_class.new.providers.map(&:label)
  end

  it 'treats a blank brave_key as unset' do
    assert_equal %w[DuckDuckGo], described_class.new(brave_key: '   ').providers.map(&:label)
  end

  it 'treats a blank exa_key as unset' do
    assert_equal %w[DuckDuckGo], described_class.new(exa_key: '   ').providers.map(&:label)
  end

  it 'includes Brave when its key is given' do
    assert_equal %w[DuckDuckGo Brave], described_class.new(brave_key: 'fake-key').providers.map(&:label)
  end

  it 'includes Exa when its key is given' do
    assert_equal %w[DuckDuckGo Exa], described_class.new(exa_key: 'fake-key').providers.map(&:label)
  end

  it 'includes Brave and Exa together when both keys are given' do
    assert_equal %w[DuckDuckGo Brave Exa],
                 described_class.new(brave_key: 'fake-brave', exa_key: 'fake-exa').providers.map(&:label)
  end

  it 'binds each key to its own provider (no key swap)' do
    by_label = described_class.new(brave_key: 'B-key', exa_key: 'E-key').providers.to_h { |p| [p.label, p] }
    assert_equal 'B-key', by_label['Brave'].instance_variable_get(:@api_key)
    assert_equal 'E-key', by_label['Exa'].instance_variable_get(:@api_key)
  end
end

RSpec.describe Pikuri::Tool::Search::Engines, '#search' do
  # Single-row helper so the test providers can describe what they
  # received in their one synthetic Result without repetition.
  def good_result(query, max_results)
    [Pikuri::Tool::Search::Result.new(
      url: 'https://example.com/ok',
      title: "ok: #{query} (#{max_results})",
      body: ''
    )]
  end

  # Synthetic providers are plain modules exposing the same duck type the
  # real provider instances do — +.search(query, max_results:)+ + +.label+ —
  # so the cascade drives them identically.
  let(:good) do
    parent = self
    Module.new do
      define_singleton_method(:label) { 'Good' }
      define_singleton_method(:search) do |query, max_results:|
        parent.good_result(query, max_results)
      end
    end
  end

  let(:bad) do
    Module.new do
      def self.label = 'Bad'

      def self.search(_query, max_results:)
        _ = max_results
        raise Pikuri::Tool::Search::Engines::Unavailable, 'rate-limited'
      end
    end
  end

  # Markdown-rendered output for what +good_result+ produces, so the
  # +#search+ contract (String back to the caller) stays readable in the
  # assertions below.
  def good_markdown(query, max_results)
    "## Search Results\n\n[ok: #{query} (#{max_results})](https://example.com/ok)\n"
  end

  # Build an engine whose provider cascade is the given synthetic list.
  # The cache defaults to NULL (no disk) — caching examples pass a real
  # tmpdir cache instead. Provider selection is normally derived from the
  # keys; here we override it directly on the instance so the cascade can
  # be exercised with synthetic providers.
  def engine_with(providers, cache: Pikuri::UrlCache::NULL)
    e = described_class.new(cache: cache)
    e.define_singleton_method(:providers) { providers }
    e
  end

  it 'returns the first successful provider output rendered as Markdown' do
    assert_equal good_markdown('ruby', 10), engine_with([good]).search('ruby', max_results: 10)
  end

  it 'falls back past an Unavailable provider to one that succeeds' do
    assert_equal good_markdown('ruby', 5), engine_with([bad, good]).search('ruby', max_results: 5)
  end

  it 'renders an empty result list as the standard no-results stub' do
    empty = Module.new do
      def self.label = 'Empty'
      def self.search(_q, max_results:) = (_ = max_results; [])
    end
    assert_equal "## Search Results\n\nNo results found.", engine_with([empty]).search('ruby', max_results: 10)
  end

  it 'returns an "Error: ..." string when every provider is unavailable' do
    result = engine_with([bad, bad]).search('ruby', max_results: 10)
    assert_match(/\AError: all search providers temporarily unavailable/, result)
    assert_includes result, 'Bad (rate-limited)'
  end

  it 'lets non-Unavailable exceptions bubble up' do
    boom = Module.new do
      def self.label = 'Boom'

      def self.search(_query, max_results:)
        _ = max_results
        raise 'network kaboom'
      end
    end
    # Single provider — the cascade shuffles its provider list, so a
    # multi-provider stub would non-deterministically pick a different one
    # first and never trigger boom.
    assert_raises(RuntimeError) { engine_with([boom]).search('ruby', max_results: 10) }
  end

  it 'normalizes the query (trim + collapse whitespace) before dispatch' do
    seen = nil
    spy = Module.new
    spy.define_singleton_method(:label) { 'Spy' }
    spy.define_singleton_method(:search) do |q, max_results:|
      seen = q
      [Pikuri::Tool::Search::Result.new(url: 'https://example.com', title: "ok (#{max_results})", body: '')]
    end

    engine_with([spy]).search("  ruby \n  on   rails  ", max_results: 10)
    assert_equal 'ruby on rails', seen
  end

  it 'rejects an empty query' do
    assert_raises(ArgumentError) { engine_with([good]).search('   ', max_results: 10) }
  end

  it 'caches the answer so a subsequent call with the same query skips providers' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::UrlCache.new(ttl: 60, dir: dir)
      calls = 0
      once = Module.new
      once.define_singleton_method(:label) { 'Once' }
      once.define_singleton_method(:search) do |q, max_results:|
        calls += 1
        [Pikuri::Tool::Search::Result.new(url: 'https://example.com', title: "ok: #{q} (#{max_results})", body: '')]
      end
      engine = engine_with([once], cache: cache)

      expected = "## Search Results\n\n[ok: ruby (10)](https://example.com)\n"
      assert_equal expected, engine.search('ruby', max_results: 10)
      assert_equal expected, engine.search('ruby', max_results: 10)
      assert_equal 1, calls, 'second call should be served from cache'
    end
  end

  it 'does not cache the all-unavailable error string' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::UrlCache.new(ttl: 60, dir: dir)
      engine = engine_with([bad, bad], cache: cache)
      engine.search('ruby', max_results: 10)
      # Now flip to a working provider on the same cache — if the error had
      # been cached, this would still return the previous "Error: ..." string.
      working = good
      engine.define_singleton_method(:providers) { [working] }
      assert_equal good_markdown('ruby', 10), engine.search('ruby', max_results: 10)
    end
  end
end

RSpec.describe Pikuri::Tool::Search::Engines, 'logging' do
  let(:log_io) { StringIO.new }

  let(:pair_provider) do
    Module.new do
      def self.label = 'Pair'

      def self.search(query, max_results:)
        _ = max_results
        [
          Pikuri::Tool::Search::Result.new(url: 'https://example.com/a', title: 'Result A', body: "body a — about #{query}"),
          Pikuri::Tool::Search::Result.new(url: 'https://example.com/b', title: 'Result B', body: 'body b')
        ]
      end
    end
  end

  around do |example|
    original_io = Pikuri.log_io
    Pikuri.log_io = log_io
    begin
      example.run
    ensure
      Pikuri.log_io = original_io
    end
  end

  # Each engine has its own @last_logged_providers memo, so a fresh engine
  # per example starts unlogged — no global reset needed.
  def engine_with(providers)
    e = Pikuri::Tool::Search::Engines.new(cache: Pikuri::UrlCache::NULL)
    e.define_singleton_method(:providers) { providers }
    e
  end

  it 'logs the available engines, tagged with the Engines progname, on first search' do
    engine_with([pair_provider]).search('ruby', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
  end

  it 'logs the chosen engine, query, and result count for a successful search' do
    engine_with([pair_provider]).search('ruby on rails', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engine=Pair query="ruby on rails" results=2'
  end

  it 'does not relog the available-engines line when the provider set is unchanged' do
    engine = engine_with([pair_provider])
    engine.search('first', max_results: 10)
    engine.search('second', max_results: 10)
    assert_equal 1, log_io.string.scan(/engines available:/).count
  end

  it 'logs a cache=hit line when a subsequent search is served from cache' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::UrlCache.new(ttl: 60, dir: dir)
      engine = Pikuri::Tool::Search::Engines.new(cache: cache)
      provider = pair_provider
      engine.define_singleton_method(:providers) { [provider] }
      engine.search('ruby', max_results: 10)
      log_io.truncate(0)
      log_io.rewind
      engine.search('ruby', max_results: 10)
      assert_match(/INFO -- Engines: cache=hit query="ruby" bytes=\d+/, log_io.string)
      refute_match(/engine=Pair/, log_io.string)
    end
  end

  it 'relogs the available-engines line when the provider set changes' do
    other = Module.new do
      def self.label = 'Other'

      def self.search(_query, max_results:)
        _ = max_results
        [Pikuri::Tool::Search::Result.new(url: 'https://example.com/only', title: 'Only', body: 'body')]
      end
    end

    engine = engine_with([pair_provider])
    engine.search('first', max_results: 10)
    engine.define_singleton_method(:providers) { [other] }
    engine.search('second', max_results: 10)

    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
    assert_includes log_io.string, 'INFO -- Engines: engines available: Other'
  end
end
