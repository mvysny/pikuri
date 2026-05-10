# frozen_string_literal: true

require 'tool'
require 'tool/web_search'

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
      original_providers = Tool::Search.method(:providers)
      provider = fake_provider
      Tool::Search.singleton_class.define_method(:providers) { [provider] }
      begin
        example.run
      ensure
        Tool::Search.singleton_class.define_method(:providers, original_providers)
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
