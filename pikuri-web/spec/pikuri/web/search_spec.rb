# frozen_string_literal: true

RSpec.describe 'Pikuri::Web::Search.build' do
  let(:tool) { Pikuri::Web::Search.build }

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
      originals = [Pikuri::Web::Search::DuckDuckGo, Pikuri::Web::Search::Brave, Pikuri::Web::Search::Exa]
                  .to_h { |provider| [provider, provider.instance_method(:search)] }
      originals.each_key do |provider|
        provider.define_method(:search) do |_query, max_results:, cancellable: nil|
          _ = [max_results, cancellable]
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
      Pikuri::Web::Search.build(engines: [:brave], brave_key: 'fake-key').run('query' => 'ruby')
      assert_equal %w[Brave], @calls
    end

    it 'ignores a key whose engine the selection leaves out' do
      Pikuri::Web::Search.build(engines: %w[duckduckgo], exa_key: 'fake-key').run('query' => 'ruby')
      assert_equal %w[DuckDuckGo], @calls
    end

    it 'selects DuckDuckGo alone when no selection is given' do
      Pikuri::Web::Search.build.run('query' => 'ruby')
      assert_equal %w[DuckDuckGo], @calls
    end

    # The refusal must come from build itself, not only from the cascade it
    # constructs — see the note in web_search.rb.
    it 'refuses an unusable selection' do
      error = assert_raises(ArgumentError) { Pikuri::Web::Search.build(engines: [:exa]) }
      assert_match(/exa needs exa_key/, error.message)
      assert_raises(ArgumentError) { Pikuri::Web::Search.build(engines: []) }
      assert_raises(ArgumentError) { Pikuri::Web::Search.build(engines: %w[bing]) }
    end
  end

  describe '.from_h' do
    it 'builds from a config block' do
      tool = Pikuri::Web::Search.from_h('engines' => %w[brave], 'brave_key' => 'fake-key')
      assert_equal 'web_search', tool.name
    end

    it 'builds the DuckDuckGo-only default from an absent block' do
      assert_equal 'web_search', Pikuri::Web::Search.from_h(nil).name
    end

    it 'refuses a malformed block' do
      assert_raises(ArgumentError) { Pikuri::Web::Search.from_h('brave_api_key' => 'k') }
    end
  end

  describe 'dispatch through the cascade' do
    # With no keys, only DuckDuckGo is configured; stub its +#search+
    # instance method to record what the engine the builder wired up
    # forwarded to it.
    around do |example|
      original = Pikuri::Web::Search::DuckDuckGo.instance_method(:search)
      @calls = []
      calls = @calls
      Pikuri::Web::Search::DuckDuckGo.define_method(:search) do |query, max_results:, cancellable: nil|
        _ = cancellable
        calls << { query: query, max_results: max_results }
        [Pikuri::Web::Search::Result.new(
          url: 'https://example.com',
          title: "result for #{query} (#{max_results})",
          body: ''
        )]
      end
      begin
        example.run
      ensure
        Pikuri::Web::Search::DuckDuckGo.define_method(:search, original)
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

  describe 'confirmer' do
    # A scripted confirmer: answers each ask with the next decision and
    # records the request it was shown.
    let(:asked) { [] }
    let(:decisions) { [] }
    let(:confirmer) do
      asked = self.asked
      decisions = self.decisions
      Class.new(Pikuri::Workspace::Confirmer) do
        define_method(:ask) do |request:|
          asked << request
          decisions.shift
        end
      end.new
    end
    let(:gated) { Pikuri::Web::Search.build(confirmer: confirmer) }

    around do |example|
      original = Pikuri::Web::Search::DuckDuckGo.instance_method(:search)
      @calls = []
      calls = @calls
      Pikuri::Web::Search::DuckDuckGo.define_method(:search) do |query, max_results:, cancellable: nil|
        _ = cancellable
        calls << query
        [Pikuri::Web::Search::Result.new(url: 'https://example.com', title: "about #{query}", body: '')]
      end
      begin
        example.run
      ensure
        Pikuri::Web::Search::DuckDuckGo.define_method(:search, original)
      end
    end

    it 'shows the query, editable, before searching it' do
      decisions << Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: 'ruby')
      result = gated.run('query' => 'ruby')
      assert_equal ['ruby'], asked.map(&:detail)
      assert asked.first.editable
      assert_equal ['ruby'], @calls
      refute_includes result.content, 'changed the query'
    end

    it 'searches the edited query and tells the model it changed' do
      decisions << Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: 'ruby 3.4')
      result = gated.run('query' => 'ruby Jan Novák')
      assert_equal ['ruby 3.4'], @calls
      assert_includes result.content, 'The user changed the query to: ruby 3.4'
      assert_includes result.content, 'about ruby 3.4'
    end

    it 'sends nothing on a decline' do
      decisions << Pikuri::Workspace::Confirmer::Rejected.new
      result = gated.run('query' => 'ruby')
      assert_empty @calls
      assert_includes result.content, 'user declined the web search'
    end

    it 'passes the human\'s words back on a redirect' do
      decisions << Pikuri::Workspace::Confirmer::Redirected.new(message: 'leave the name out')
      result = gated.run('query' => 'Jan Novák')
      assert_empty @calls
      assert_includes result.content, 'leave the name out'
    end

    it 'grades the query human-reviewed only when the confirmer blocks on a human' do
      assert_equal :human_reviewed, gated.trifecta_legs.egress_payload_review
      yolo = Pikuri::Web::Search.build(confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE)
      assert_equal :unreviewed, yolo.trifecta_legs.egress_payload_review
      assert_equal :tool_vouched, gated.trifecta_legs.egress_destination
    end
  end

  describe 'snippets_only' do
    it 'tells the model the snippets are all it gets, naming no page reader' do
      snippy = Pikuri::Web::Search.build(snippets_only: true)
      assert_includes snippy.description, 'snippets are all you get'
      refute_includes snippy.description, 'web_scrape'
      refute_includes snippy.description, 'web_read_cached'
    end

    it 'refuses to combine with page_text' do
      assert_raises(ArgumentError) do
        Pikuri::Web::Search.build(engines: [:exa], exa_key: 'k', page_text: true, snippets_only: true)
      end
    end
  end

  describe 'page_text' do
    it 'points the model at web_read_cached instead of web_scrape' do
      texty = Pikuri::Web::Search.build(engines: [:exa], exa_key: 'k', page_text: true)
      assert_includes texty.description, 'web_read_cached'
      refute_includes texty.description, 'web_scrape'
      assert_includes tool.description, 'web_scrape'
    end

    it 'keeps the vouched egress grade' do
      texty = Pikuri::Web::Search.build(engines: [:brave], brave_key: 'k', page_text: true)
      assert_equal :tool_vouched, texty.trifecta_legs.egress_destination
    end

    it 'refuses page_text when no engine can bring text back' do
      assert_raises(ArgumentError) { Pikuri::Web::Search.build(page_text: true) }
    end
  end
end
