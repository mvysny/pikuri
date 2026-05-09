# frozen_string_literal: true

require 'tool'
require 'tool/websearch'

RSpec.describe Tool::Search, '.provider' do
  before { @saved = ENV[Tool::Search::Brave::ENV_KEY] }
  after  { ENV[Tool::Search::Brave::ENV_KEY] = @saved }

  it 'falls back to DuckDuckGo when no Brave key is set' do
    ENV.delete(Tool::Search::Brave::ENV_KEY)
    assert_equal Tool::Search::DuckDuckGo, described_class.provider
  end

  it 'treats a blank Brave key as unset' do
    ENV[Tool::Search::Brave::ENV_KEY] = '   '
    assert_equal Tool::Search::DuckDuckGo, described_class.provider
  end

  it 'picks Brave when its key is set' do
    ENV[Tool::Search::Brave::ENV_KEY] = 'fake-key'
    assert_equal Tool::Search::Brave, described_class.provider
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

  describe 'dispatch to the selected provider' do
    let(:fake_provider) do
      Module.new do
        class << self
          attr_reader :calls

          def search(query, max_results:)
            @calls ||= []
            @calls << { query: query, max_results: max_results }
            "result for #{query} (#{max_results})"
          end
        end
      end
    end

    around do |example|
      original = Tool::Search.method(:provider)
      provider = fake_provider
      Tool::Search.singleton_class.define_method(:provider) { provider }
      begin
        example.run
      ensure
        Tool::Search.singleton_class.define_method(:provider, original)
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
