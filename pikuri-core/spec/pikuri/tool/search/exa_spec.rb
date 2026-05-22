# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Search::Exa do
  let(:fixture) { File.read(File.expand_path('../../../fixtures/exa_ruby_language.json', __dir__)) }

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

    it 'uses the top highlight as the result body' do
      results = described_class.parse(fixture)
      assert(results.any? { |r| r.body.include?('Ruby is a dynamic, open source programming language') })
    end

    it 'collapses whitespace inside highlights' do
      results = described_class.parse(fixture)
      assert(results.any? { |r| r.body.include?('Ruby is a general-purpose programming language.') })
      refute(results.any? { |r| r.body.include?('Ruby is a   general-purpose') })
    end

    it 'leaves body empty for results with no highlights' do
      results = described_class.parse(fixture)
      rubygems = results.find { |r| r.url == 'https://rubygems.org' }
      refute_nil rubygems, 'expected the rubygems.org result row'
      assert_equal '', rubygems.body
    end

    it 'respects max_results' do
      assert_equal 2, described_class.parse(fixture, max_results: 2).size
    end

    it 'returns an empty array for a recognized empty Exa payload' do
      json = JSON.dump(requestId: 'fixture-empty-001', searchType: 'auto', results: [])
      assert_equal [], described_class.parse(json)
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
