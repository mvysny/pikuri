# frozen_string_literal: true

require 'tmpdir'

require 'tool'
require 'tool/websearch'
require 'url_cache'

RSpec.describe Tool::Search, '.providers' do
  before { @saved = ENV[Tool::Search::Brave::ENV_KEY] }
  after  { ENV[Tool::Search::Brave::ENV_KEY] = @saved }

  it 'lists only DuckDuckGo when no Brave key is set' do
    ENV.delete(Tool::Search::Brave::ENV_KEY)
    assert_equal [Tool::Search::DuckDuckGo], described_class.providers
  end

  it 'treats a blank Brave key as unset' do
    ENV[Tool::Search::Brave::ENV_KEY] = '   '
    assert_equal [Tool::Search::DuckDuckGo], described_class.providers
  end

  it 'includes Brave when its key is set' do
    ENV[Tool::Search::Brave::ENV_KEY] = 'fake-key'
    assert_equal [Tool::Search::DuckDuckGo, Tool::Search::Brave].sort_by(&:name),
                 described_class.providers.sort_by(&:name)
  end
end

RSpec.describe Tool::Search, '.search' do
  let(:good) do
    Module.new do
      def self.name = 'Tool::Search::Good'

      def self.search(query, max_results:)
        "ok: #{query} (#{max_results})"
      end
    end
  end

  let(:bad) do
    Module.new do
      def self.name = 'Tool::Search::Bad'

      def self.search(_query, max_results:)
        _ = max_results
        raise Tool::Search::Unavailable, 'rate-limited'
      end
    end
  end

  # Per-test isolated cache + provider list, so neither a previous run's
  # +/tmp/pikuri+ entries nor a previous +it+ block's cached output can
  # leak into the current example.
  around do |example|
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = UrlCache.new(ttl: 60, dir: dir)
      original_cache = Tool::Search.method(:cache)
      original_providers = Tool::Search.method(:providers)
      Tool::Search.singleton_class.define_method(:cache) { cache }
      begin
        example.run
      ensure
        Tool::Search.singleton_class.define_method(:cache, original_cache)
        Tool::Search.singleton_class.define_method(:providers, original_providers)
      end
    end
  end

  def stub_providers(list)
    Tool::Search.singleton_class.define_method(:providers) { list }
  end

  it 'returns the first successful provider output' do
    stub_providers([good])
    assert_equal 'ok: ruby (10)', described_class.search('ruby', max_results: 10)
  end

  it 'falls back past an Unavailable provider to one that succeeds' do
    stub_providers([bad, good])
    assert_equal 'ok: ruby (5)', described_class.search('ruby', max_results: 5)
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
    stub_providers([boom, good])
    assert_raises(RuntimeError) { described_class.search('ruby', max_results: 10) }
  end

  it 'normalizes the query (trim + collapse whitespace) before dispatch' do
    seen = nil
    spy = Module.new
    spy.define_singleton_method(:name) { 'Tool::Search::Spy' }
    spy.define_singleton_method(:search) { |q, max_results:| seen = q; "ok (#{max_results})" }
    stub_providers([spy])

    described_class.search("  ruby \n  on   rails  ", max_results: 10)
    assert_equal 'ruby on rails', seen
  end

  it 'rejects an empty query' do
    stub_providers([good])
    assert_raises(ArgumentError) { described_class.search('   ', max_results: 10) }
  end

  it 'caches the answer so a subsequent call with the same query skips providers' do
    calls = 0
    once = Module.new
    once.define_singleton_method(:name) { 'Tool::Search::Once' }
    once.define_singleton_method(:search) { |q, max_results:| calls += 1; "ok: #{q} (#{max_results})" }
    stub_providers([once])

    assert_equal 'ok: ruby (10)', described_class.search('ruby', max_results: 10)
    assert_equal 'ok: ruby (10)', described_class.search('ruby', max_results: 10)
    assert_equal 1, calls, 'second call should be served from cache'
  end

  it 'does not cache the all-unavailable error string' do
    stub_providers([bad, bad])
    described_class.search('ruby', max_results: 10)
    # Now flip to a working provider — if the error had been cached, this
    # would still return the previous "Error: ..." string.
    stub_providers([good])
    assert_equal 'ok: ruby (10)', described_class.search('ruby', max_results: 10)
  end
end

RSpec.describe 'Tool::WEB_SEARCH' do
  it 'is advertised to the LLM as `web_search`' do
    assert_equal 'web_search', Tool::WEB_SEARCH.name
  end

  it 'declares a required string `query` parameter' do
    schema = Tool::WEB_SEARCH.parameters.to_h
    assert_equal({ type: 'string', description: 'The search query to perform.' },
                 schema[:properties][:query])
    assert_includes schema[:required], 'query'
  end

  it 'declares an optional integer `max_results` parameter' do
    schema = Tool::WEB_SEARCH.parameters.to_h
    assert_equal 'integer', schema[:properties][:max_results][:type]
    refute_includes schema[:required], 'max_results'
  end

  describe 'dispatch through the cascade' do
    let(:fake_provider) do
      Module.new do
        class << self
          attr_reader :calls

          def name = 'Tool::Search::Fake'

          def search(query, max_results:)
            @calls ||= []
            @calls << { query: query, max_results: max_results }
            "result for #{query} (#{max_results})"
          end
        end
      end
    end

    around do |example|
      Dir.mktmpdir('pikuri-cache-test-') do |dir|
        cache = UrlCache.new(ttl: 60, dir: dir)
        original_providers = Tool::Search.method(:providers)
        original_cache = Tool::Search.method(:cache)
        provider = fake_provider
        Tool::Search.singleton_class.define_method(:providers) { [provider] }
        Tool::Search.singleton_class.define_method(:cache) { cache }
        begin
          example.run
        ensure
          Tool::Search.singleton_class.define_method(:providers, original_providers)
          Tool::Search.singleton_class.define_method(:cache, original_cache)
        end
      end
    end

    it 'forwards a custom max_results to the provider' do
      Tool::WEB_SEARCH.run('query' => 'ruby', 'max_results' => 5)
      assert_equal [{ query: 'ruby', max_results: 5 }], fake_provider.calls
    end

    it 'defaults max_results to 10 when omitted' do
      Tool::WEB_SEARCH.run('query' => 'ruby')
      assert_equal [{ query: 'ruby', max_results: 10 }], fake_provider.calls
    end
  end
end
