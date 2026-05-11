# frozen_string_literal: true

require 'tmpdir'

require 'tool'
require 'tool/search/engines'
require 'url_cache'

RSpec.describe Tool::Search::Engines, '.providers' do
  before do
    @saved_brave = ENV[Tool::Search::Brave::ENV_KEY]
    @saved_exa = ENV[Tool::Search::Exa::ENV_KEY]
    ENV.delete(Tool::Search::Brave::ENV_KEY)
    ENV.delete(Tool::Search::Exa::ENV_KEY)
  end
  after do
    ENV[Tool::Search::Brave::ENV_KEY] = @saved_brave
    ENV[Tool::Search::Exa::ENV_KEY] = @saved_exa
  end

  it 'lists only DuckDuckGo when no provider keys are set' do
    assert_equal [Tool::Search::DuckDuckGo], described_class.providers
  end

  it 'treats a blank Brave key as unset' do
    ENV[Tool::Search::Brave::ENV_KEY] = '   '
    assert_equal [Tool::Search::DuckDuckGo], described_class.providers
  end

  it 'treats a blank Exa key as unset' do
    ENV[Tool::Search::Exa::ENV_KEY] = '   '
    assert_equal [Tool::Search::DuckDuckGo], described_class.providers
  end

  it 'includes Brave when its key is set' do
    ENV[Tool::Search::Brave::ENV_KEY] = 'fake-key'
    assert_equal [Tool::Search::DuckDuckGo, Tool::Search::Brave].sort_by(&:name),
                 described_class.providers.sort_by(&:name)
  end

  it 'includes Exa when its key is set' do
    ENV[Tool::Search::Exa::ENV_KEY] = 'fake-key'
    assert_equal [Tool::Search::DuckDuckGo, Tool::Search::Exa].sort_by(&:name),
                 described_class.providers.sort_by(&:name)
  end

  it 'includes Brave and Exa together when both keys are set' do
    ENV[Tool::Search::Brave::ENV_KEY] = 'fake-brave'
    ENV[Tool::Search::Exa::ENV_KEY] = 'fake-exa'
    assert_equal [Tool::Search::Brave, Tool::Search::DuckDuckGo, Tool::Search::Exa].sort_by(&:name),
                 described_class.providers.sort_by(&:name)
  end
end

RSpec.describe Tool::Search::Engines, '.search' do
  # Single-row helper so the test providers can describe what they
  # received in their one synthetic Result without repetition.
  def good_result(query, max_results)
    [Tool::Search::Result.new(
      url: 'https://example.com/ok',
      title: "ok: #{query} (#{max_results})",
      body: ''
    )]
  end

  let(:good) do
    parent = self
    Module.new do
      define_singleton_method(:name) { 'Tool::Search::Good' }
      define_singleton_method(:search) do |query, max_results:|
        parent.good_result(query, max_results)
      end
    end
  end

  let(:bad) do
    Module.new do
      def self.name = 'Tool::Search::Bad'

      def self.search(_query, max_results:)
        _ = max_results
        raise Tool::Search::Engines::Unavailable, 'rate-limited'
      end
    end
  end

  # Markdown-rendered output for what +good_result+ produces, so the
  # +Engines.search+ contract (String back to the caller) stays
  # readable in the assertions below.
  def good_markdown(query, max_results)
    "## Search Results\n\n[ok: #{query} (#{max_results})](https://example.com/ok)\n"
  end

  # Save and restore +.providers+ around each example so +stub_providers+
  # cannot leak across +it+ blocks. The cache is +UrlCache::NULL+ globally
  # (see +spec_helper.rb+); the two examples that actually exercise
  # caching opt back into a real tmpdir cache themselves.
  around do |example|
    original_providers = Tool::Search::Engines.method(:providers)
    begin
      example.run
    ensure
      Tool::Search::Engines.singleton_class.define_method(:providers, original_providers)
    end
  end

  def stub_providers(list)
    Tool::Search::Engines.singleton_class.define_method(:providers) { list }
  end

  def with_real_cache
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = UrlCache.new(ttl: 60, dir: dir)
      original_cache = Tool::Search::Engines.method(:cache)
      Tool::Search::Engines.singleton_class.define_method(:cache) { cache }
      begin
        yield
      ensure
        Tool::Search::Engines.singleton_class.define_method(:cache, original_cache)
      end
    end
  end

  it 'returns the first successful provider output rendered as Markdown' do
    stub_providers([good])
    assert_equal good_markdown('ruby', 10), described_class.search('ruby', max_results: 10)
  end

  it 'falls back past an Unavailable provider to one that succeeds' do
    stub_providers([bad, good])
    assert_equal good_markdown('ruby', 5), described_class.search('ruby', max_results: 5)
  end

  it 'renders an empty result list as the standard no-results stub' do
    empty = Module.new do
      def self.name = 'Tool::Search::Empty'
      def self.search(_q, max_results:) = (_ = max_results; [])
    end
    stub_providers([empty])
    assert_equal "## Search Results\n\nNo results found.", described_class.search('ruby', max_results: 10)
  end

  it 'returns an "Error: ..." string when every provider is unavailable' do
    stub_providers([bad, bad])
    result = described_class.search('ruby', max_results: 10)
    assert_match(/\AError: all search providers temporarily unavailable/, result)
    assert_includes result, 'Bad (rate-limited)'
  end

  it 'lets non-Unavailable exceptions bubble up' do
    boom = Module.new do
      def self.name = 'Tool::Search::Boom'

      def self.search(_query, max_results:)
        _ = max_results
        raise 'network kaboom'
      end
    end
    # Single provider — the cascade shuffles its provider list, so a
    # multi-provider stub would non-deterministically pick a different one
    # first and never trigger boom.
    stub_providers([boom])
    assert_raises(RuntimeError) { described_class.search('ruby', max_results: 10) }
  end

  it 'normalizes the query (trim + collapse whitespace) before dispatch' do
    seen = nil
    spy = Module.new
    spy.define_singleton_method(:name) { 'Tool::Search::Spy' }
    spy.define_singleton_method(:search) do |q, max_results:|
      seen = q
      [Tool::Search::Result.new(url: 'https://example.com', title: "ok (#{max_results})", body: '')]
    end
    stub_providers([spy])

    described_class.search("  ruby \n  on   rails  ", max_results: 10)
    assert_equal 'ruby on rails', seen
  end

  it 'rejects an empty query' do
    stub_providers([good])
    assert_raises(ArgumentError) { described_class.search('   ', max_results: 10) }
  end

  it 'caches the answer so a subsequent call with the same query skips providers' do
    with_real_cache do
      calls = 0
      once = Module.new
      once.define_singleton_method(:name) { 'Tool::Search::Once' }
      once.define_singleton_method(:search) do |q, max_results:|
        calls += 1
        [Tool::Search::Result.new(url: 'https://example.com', title: "ok: #{q} (#{max_results})", body: '')]
      end
      stub_providers([once])

      expected = "## Search Results\n\n[ok: ruby (10)](https://example.com)\n"
      assert_equal expected, described_class.search('ruby', max_results: 10)
      assert_equal expected, described_class.search('ruby', max_results: 10)
      assert_equal 1, calls, 'second call should be served from cache'
    end
  end

  it 'does not cache the all-unavailable error string' do
    with_real_cache do
      stub_providers([bad, bad])
      described_class.search('ruby', max_results: 10)
      # Now flip to a working provider — if the error had been cached, this
      # would still return the previous "Error: ..." string.
      stub_providers([good])
      assert_equal good_markdown('ruby', 10), described_class.search('ruby', max_results: 10)
    end
  end
end

RSpec.describe Tool::Search::Engines, 'logging' do
  let(:log_io) { StringIO.new }

  let(:pair_provider) do
    Module.new do
      def self.name = 'Tool::Search::Pair'

      def self.search(query, max_results:)
        _ = max_results
        [
          Tool::Search::Result.new(url: 'https://example.com/a', title: 'Result A', body: "body a — about #{query}"),
          Tool::Search::Result.new(url: 'https://example.com/b', title: 'Result B', body: 'body b')
        ]
      end
    end
  end

  around do |example|
    original_providers = Tool::Search::Engines.method(:providers)
    original_io = Pikuri.log_io
    original_last = Tool::Search::Engines.instance_variable_get(:@last_logged_providers)

    Pikuri.log_io = log_io
    Tool::Search::Engines.instance_variable_set(:@last_logged_providers, nil)

    begin
      example.run
    ensure
      Tool::Search::Engines.singleton_class.define_method(:providers, original_providers)
      Tool::Search::Engines.instance_variable_set(:@last_logged_providers, original_last)
      Pikuri.log_io = original_io
    end
  end

  def stub_providers(list)
    Tool::Search::Engines.singleton_class.define_method(:providers) { list }
  end

  it 'logs the available engines, tagged with the Engines progname, on first search' do
    stub_providers([pair_provider])
    described_class.search('ruby', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
  end

  it 'logs the chosen engine, query, and result count for a successful search' do
    stub_providers([pair_provider])
    described_class.search('ruby on rails', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engine=Pair query="ruby on rails" results=2'
  end

  it 'does not relog the available-engines line when the provider set is unchanged' do
    stub_providers([pair_provider])
    described_class.search('first', max_results: 10)
    described_class.search('second', max_results: 10)
    assert_equal 1, log_io.string.scan(/engines available:/).count
  end

  it 'logs a cache=hit line when a subsequent search is served from cache' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = UrlCache.new(ttl: 60, dir: dir)
      original_cache = Tool::Search::Engines.method(:cache)
      Tool::Search::Engines.singleton_class.define_method(:cache) { cache }
      begin
        stub_providers([pair_provider])
        described_class.search('ruby', max_results: 10)
        log_io.truncate(0)
        log_io.rewind
        described_class.search('ruby', max_results: 10)
        assert_match(/INFO -- Engines: cache=hit query="ruby" bytes=\d+/, log_io.string)
        refute_match(/engine=Pair/, log_io.string)
      ensure
        Tool::Search::Engines.singleton_class.define_method(:cache, original_cache)
      end
    end
  end

  it 'relogs the available-engines line when the provider set changes' do
    other = Module.new do
      def self.name = 'Tool::Search::Other'

      def self.search(_query, max_results:)
        _ = max_results
        [Tool::Search::Result.new(url: 'https://example.com/only', title: 'Only', body: 'body')]
      end
    end

    stub_providers([pair_provider])
    described_class.search('first', max_results: 10)
    stub_providers([other])
    described_class.search('second', max_results: 10)

    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
    assert_includes log_io.string, 'INFO -- Engines: engines available: Other'
  end
end
