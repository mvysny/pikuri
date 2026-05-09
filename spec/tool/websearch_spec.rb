# frozen_string_literal: true

require 'tool'
require 'tool/websearch'

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

  def stub_providers(list)
    original = Tool::Search.method(:providers)
    Tool::Search.singleton_class.define_method(:providers) { list }
    yield
  ensure
    Tool::Search.singleton_class.define_method(:providers, original)
  end

  it 'returns the first successful provider output' do
    stub_providers([good]) do
      assert_equal 'ok: ruby (10)', described_class.search('ruby', max_results: 10)
    end
  end

  it 'falls back past an Unavailable provider to one that succeeds' do
    stub_providers([bad, good]) do
      assert_equal 'ok: ruby (5)', described_class.search('ruby', max_results: 5)
    end
  end

  it 'returns an "Error: ..." string when every provider is unavailable' do
    stub_providers([bad, bad]) do
      result = described_class.search('ruby', max_results: 10)
      assert_match(/\AError: all search providers temporarily unavailable/, result)
      assert_includes result, 'Bad (rate-limited)'
    end
  end

  it 'lets non-Unavailable exceptions bubble up' do
    boom = Module.new do
      def self.name = 'Tool::Search::Boom'

      def self.search(_query, max_results:)
        _ = max_results
        raise 'network kaboom'
      end
    end
    stub_providers([boom, good]) do
      assert_raises(RuntimeError) { described_class.search('ruby', max_results: 10) }
    end
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
      original = Tool::Search.method(:providers)
      provider = fake_provider
      Tool::Search.singleton_class.define_method(:providers) { [provider] }
      begin
        example.run
      ensure
        Tool::Search.singleton_class.define_method(:providers, original)
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
