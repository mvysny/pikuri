# frozen_string_literal: true

RSpec.describe Pikuri::Web::Search::Brave do
  let(:fixture) { File.read(File.expand_path('../../../fixtures/brave_ruby_language.json', __dir__)) }

  describe '.parse' do
    it 'returns Result rows with title, url, and body' do
      results = described_class.parse(fixture)
      assert results.is_a?(Array)
      assert(results.all? { |r| r.is_a?(Pikuri::Web::Search::Result) })

      ruby_lang = results.find { |r| r.url == 'https://www.ruby-lang.org/en/' }
      refute_nil ruby_lang, 'expected the ruby-lang.org result row'
      assert_equal 'Ruby Programming Language', ruby_lang.title
    end

    it 'preserves parentheses in URLs without escaping' do
      results = described_class.parse(fixture)
      wiki = results.find { |r| r.title.include?('Wikipedia') }
      refute_nil wiki
      assert_equal 'https://en.wikipedia.org/wiki/Ruby_(programming_language)', wiki.url
    end

    it 'strips <strong> highlights from titles and descriptions' do
      results = described_class.parse(fixture)
      refute(results.any? { |r| r.title.include?('<strong>') || r.body.include?('<strong>') })
      assert(results.any? { |r| r.body.include?('Ruby has a simple and intuitive syntax') })
    end

    it 'respects max_results' do
      assert_equal 2, described_class.parse(fixture, max_results: 2).size
    end

    it 'raises with body snippet when no results are present' do
      err = assert_raises(RuntimeError) do
        described_class.parse('{"web":{"results":[]}}')
      end
      assert_includes err.message, 'no results'
    end

    it 'returns an empty array for a recognized empty Brave payload' do
      json = JSON.dump(
        type: 'search',
        query: { original: 'unmatched query', bad_results: true },
        mixed: { type: 'mixed', main: [], top: [], side: [] }
      )
      assert_equal [], described_class.parse(json)
    end

    it 'surfaces a structured Brave error payload' do
      json = '{"error":{"code":"VALIDATION","detail":"Query too short"}}'
      err = assert_raises(RuntimeError) { described_class.parse(json) }
      assert_includes err.message, 'VALIDATION'
      assert_includes err.message, 'Query too short'
    end
  end

  describe '.new' do
    it 'rejects a blank api key' do
      err = assert_raises(ArgumentError) { described_class.new(api_key: '') }
      assert_includes err.message, 'Brave Search API key is blank'
    end
  end

  it 'keeps its results off disk, per the API terms' do
    refute described_class.new(api_key: 'k').disk_cacheable?
  end

  describe 'page text (LLM Context)' do
    let(:json) do
      JSON.generate(
        'grounding' => { 'generic' => [
          { 'url' => 'https://example.com/a', 'title' => 'A <strong>page</strong>', 'snippets' => ['chunk one', 'chunk two'] },
          { 'url' => 'https://example.com/b', 'title' => 'B', 'snippets' => ["#{'word ' * 100}"] }
        ], 'map' => [] },
        'sources' => {
          'https://example.com/a' => { 'title' => 'A page', 'description' => 'The meta description.',
                                       'fetched_content_timestamp' => 1_794_460_934 },
          'https://example.com/b' => { 'title' => 'B', 'description' => '' }
        }
      )
    end

    it 'asks for every chunk: thresholds off, token budgets at their ceilings' do
      params = described_class.llm_context_params('ruby', max_results: 5)
      assert_equal 'disabled', params[:context_threshold_mode]
      assert_equal 32_768, params[:maximum_number_of_tokens]
      assert_equal 8_192, params[:maximum_number_of_tokens_per_url]
      assert_equal 5, params[:maximum_number_of_urls]
      assert params[:enable_source_metadata]
    end

    it 'joins a page\'s chunks with a visible gap and keeps the index time' do
      a = described_class.parse_llm_context(json).first
      assert_equal 'A page', a.title
      assert_equal "chunk one\n\n…\n\nchunk two", a.text
      assert_equal Time.at(1_794_460_934).utc, a.indexed_at
    end

    it 'takes the meta description as the snippet, else the start of the first chunk' do
      a, b = described_class.parse_llm_context(json)
      assert_equal 'The meta description.', a.body
      assert b.body.end_with?('…')
      assert_equal described_class::SNIPPET_CHARS + 1, b.body.length
      assert_nil b.indexed_at
    end

    it 'returns [] for an empty grounding and raises on an unknown shape' do
      assert_equal [], described_class.parse_llm_context('{"grounding":{"generic":[]},"sources":{}}')
      assert_raises(RuntimeError) { described_class.parse_llm_context('{"weird":true}') }
    end
  end
end
