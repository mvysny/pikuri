# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Search::Brave do
  let(:fixture) { File.read(File.expand_path('../../../fixtures/brave_ruby_language.json', __dir__)) }

  describe '.parse' do
    it 'returns Result rows with title, url, and body' do
      results = described_class.parse(fixture)
      assert results.is_a?(Array)
      assert(results.all? { |r| r.is_a?(Pikuri::Tool::Search::Result) })

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
end
