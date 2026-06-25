# frozen_string_literal: true

RSpec.describe 'Pikuri::Tool::WebSearch.build' do
  let(:tool) { Pikuri::Tool::WebSearch.build }

  it 'is advertised to the LLM as `web_search`' do
    assert_equal 'web_search', tool.name
  end

  it 'declares a required string `query` parameter' do
    schema = tool.parameters.to_openai
    assert_equal({ type: 'string', description: 'The search query, e.g. "BigDecimal precision Ruby".' },
                 schema[:properties][:query])
    assert_includes schema[:required], 'query'
  end

  it 'declares an optional integer `max_results` parameter' do
    schema = tool.parameters.to_openai
    assert_equal 'integer', schema[:properties][:max_results][:type]
    refute_includes schema[:required], 'max_results'
  end

  describe 'dispatch through the cascade' do
    # With no keys, only DuckDuckGo is configured; stub its +#search+
    # instance method to record what the engine the builder wired up
    # forwarded to it.
    around do |example|
      original = Pikuri::Tool::Search::DuckDuckGo.instance_method(:search)
      @calls = []
      calls = @calls
      Pikuri::Tool::Search::DuckDuckGo.define_method(:search) do |query, max_results:|
        calls << { query: query, max_results: max_results }
        [Pikuri::Tool::Search::Result.new(
          url: 'https://example.com',
          title: "result for #{query} (#{max_results})",
          body: ''
        )]
      end
      begin
        example.run
      ensure
        Pikuri::Tool::Search::DuckDuckGo.define_method(:search, original)
      end
    end

    it 'forwards a custom max_results to the provider' do
      tool.run('query' => 'ruby', 'max_results' => 5)
      assert_equal [{ query: 'ruby', max_results: 5 }], @calls
    end

    it 'defaults max_results to 10 when omitted' do
      tool.run('query' => 'ruby')
      assert_equal [{ query: 'ruby', max_results: 10 }], @calls
    end
  end
end
