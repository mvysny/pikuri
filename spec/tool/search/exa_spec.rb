# frozen_string_literal: true

require 'tool'
require 'tool/search/exa'

RSpec.describe Tool::Search::Exa do
  let(:fixture) { File.read(File.expand_path('../../fixtures/exa_ruby_language.json', __dir__)) }

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

    it 'renders the top highlight as the result body' do
      output = described_class.parse(fixture)
      assert_includes output, 'Ruby is a dynamic, open source programming language'
    end

    it 'collapses whitespace inside highlights' do
      output = described_class.parse(fixture)
      assert_includes output, 'Ruby is a general-purpose programming language.'
      refute_includes output, 'Ruby is a   general-purpose'
    end

    it 'renders results with empty highlights as title + url only' do
      output = described_class.parse(fixture)
      # RubyGems entry has highlights: []; the entry is still rendered as
      # [title](href) followed by an empty body line, not omitted entirely.
      assert output.end_with?("[RubyGems.org](https://rubygems.org)\n"),
             "expected trailing entry to render without a highlight, got:\n#{output.lines.last(3).join}"
    end

    it 'respects max_results' do
      output = described_class.parse(fixture, max_results: 2)
      assert_equal 2, output.scan(/^\[/).size
    end

    it 'returns a no-results stub for a recognized empty Exa payload' do
      json = JSON.dump(requestId: 'fixture-empty-001', searchType: 'auto', results: [])
      output = described_class.parse(json)
      assert_equal "## Search Results\n\nNo results found.", output
    end

    it 'raises with body snippet when no results are present and no requestId' do
      err = assert_raises(RuntimeError) do
        described_class.parse('{"results":[]}')
      end
      assert_includes err.message, 'no results'
    end

    it 'surfaces a structured Exa error payload' do
      json = '{"statusCode":400,"message":"query is required","error":"Bad Request"}'
      err = assert_raises(RuntimeError) { described_class.parse(json) }
      assert_includes err.message, 'Bad Request'
    end
  end

  describe '.search' do
    it 'rejects a missing api key' do
      err = assert_raises(ArgumentError) { described_class.search('ruby', api_key: '') }
      assert_includes err.message, described_class::ENV_KEY
    end
  end
end
