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

  describe 'engine selection' do
    # Every real provider's +#search+ is stubbed to record its label, so a
    # wrongly-wired engine shows up as an extra recorded call rather than as a
    # (flaky) live HTTP request from the shuffle.
    around do |example|
      @calls = []
      calls = @calls
      originals = [Pikuri::Tool::Search::DuckDuckGo, Pikuri::Tool::Search::Brave, Pikuri::Tool::Search::Exa]
                  .to_h { |provider| [provider, provider.instance_method(:search)] }
      originals.each_key do |provider|
        provider.define_method(:search) do |_query, max_results:|
          _ = max_results
          calls << label
          []
        end
      end
      begin
        example.run
      ensure
        originals.each { |provider, original| provider.define_method(:search, original) }
      end
    end

    it 'dispatches to the selected engine only' do
      Pikuri::Tool::WebSearch.build(engines: [:brave], brave_key: 'fake-key').run('query' => 'ruby')
      assert_equal %w[Brave], @calls
    end

    it 'ignores a key whose engine the selection leaves out' do
      Pikuri::Tool::WebSearch.build(engines: %w[duckduckgo], exa_key: 'fake-key').run('query' => 'ruby')
      assert_equal %w[DuckDuckGo], @calls
    end

    it 'selects DuckDuckGo alone when no selection is given' do
      Pikuri::Tool::WebSearch.build.run('query' => 'ruby')
      assert_equal %w[DuckDuckGo], @calls
    end

    # The refusal must come from build itself, not only from the cascade it
    # constructs — see the note in web_search.rb.
    it 'refuses an unusable selection' do
      error = assert_raises(ArgumentError) { Pikuri::Tool::WebSearch.build(engines: [:exa]) }
      assert_match(/exa needs exa_key/, error.message)
      assert_raises(ArgumentError) { Pikuri::Tool::WebSearch.build(engines: []) }
      assert_raises(ArgumentError) { Pikuri::Tool::WebSearch.build(engines: %w[bing]) }
    end
  end

  describe '.from_h' do
    it 'builds from a config block' do
      tool = Pikuri::Tool::WebSearch.from_h('engines' => %w[brave], 'brave_key' => 'fake-key')
      assert_equal 'web_search', tool.name
    end

    it 'builds the DuckDuckGo-only default from an absent block' do
      assert_equal 'web_search', Pikuri::Tool::WebSearch.from_h(nil).name
    end

    it 'refuses a malformed block' do
      assert_raises(ArgumentError) { Pikuri::Tool::WebSearch.from_h('brave_api_key' => 'k') }
    end
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
