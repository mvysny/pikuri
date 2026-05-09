# frozen_string_literal: true

require 'tool'
require 'tool/search/brave'

RSpec.describe Tool::Search::Brave do
  let(:fixture) { File.read(File.expand_path('../../fixtures/brave_ruby_language.json', __dir__)) }

  describe '.parse' do
    it 'renders results in smolagents-style markdown' do
      output = described_class.parse(fixture)
      assert output.start_with?("## Search Results\n\n"), 'missing smolagents header'
      assert_includes output, "[Ruby Programming Language](https://www.ruby-lang.org/en/)\n"
    end

    it 'preserves parentheses in URLs without escaping' do
      output = described_class.parse(fixture)
      assert_includes output,
                      '[Ruby (programming language) - Wikipedia]' \
                      '(https://en.wikipedia.org/wiki/Ruby_(programming_language))'
    end

    it 'strips <strong> highlights from titles and descriptions' do
      output = described_class.parse(fixture)
      refute_includes output, '<strong>'
      assert_includes output, 'Ruby has a simple and intuitive syntax'
    end

    it 'respects max_results' do
      output = described_class.parse(fixture, max_results: 2)
      assert_equal 2, output.scan(/^\[/).size
    end

    it 'raises with body snippet when no results are present' do
      err = assert_raises(RuntimeError) do
        described_class.parse('{"web":{"results":[]}}')
      end
      assert_includes err.message, 'no results'
    end

    it 'returns a no-results stub for a recognized empty Brave payload' do
      json = JSON.dump(
        type: 'search',
        query: { original: 'unmatched query', bad_results: true },
        mixed: { type: 'mixed', main: [], top: [], side: [] }
      )
      output = described_class.parse(json)
      assert_equal "## Search Results\n\nNo results found.", output
    end

    it 'surfaces a structured Brave error payload' do
      json = '{"error":{"code":"VALIDATION","detail":"Query too short"}}'
      err = assert_raises(RuntimeError) { described_class.parse(json) }
      assert_includes err.message, 'VALIDATION'
      assert_includes err.message, 'Query too short'
    end
  end

  describe '.search' do
    it 'rejects a missing api key' do
      err = assert_raises(ArgumentError) { described_class.search('ruby', api_key: '') }
      assert_includes err.message, described_class::ENV_KEY
    end
  end
end
