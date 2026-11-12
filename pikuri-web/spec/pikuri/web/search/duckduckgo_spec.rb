# frozen_string_literal: true

RSpec.describe Pikuri::Web::Search::DuckDuckGo do
  let(:fixture) { File.read(File.expand_path('../../../fixtures/ddg_ruby_language.html', __dir__)) }

  describe '.parse' do
    it 'returns Result rows with title, url, and body' do
      results = described_class.parse(fixture)
      assert results.is_a?(Array)
      assert(results.all? { |r| r.is_a?(Pikuri::Web::Search::Result) })

      ruby_lang = results.find { |r| r.url == 'https://www.ruby-lang.org/en/' }
      refute_nil ruby_lang, 'expected the ruby-lang.org result row'
      assert_equal 'Ruby Programming Language', ruby_lang.title
    end

    it 'decodes the uddg redirect to the real URL, parens preserved' do
      results = described_class.parse(fixture)
      wiki = results.find { |r| r.title.include?('Wikipedia') }
      refute_nil wiki
      assert_equal 'https://en.wikipedia.org/wiki/Ruby_(programming_language)', wiki.url
    end

    it 'strips <b> highlights from the snippet body' do
      results = described_class.parse(fixture)
      refute(results.any? { |r| r.body.include?('<b>') })
      assert(results.any? { |r| r.body.include?('Ruby has a simple and intuitive syntax') })
    end

    it 'respects max_results' do
      assert_equal 3, described_class.parse(fixture, max_results: 3).size
    end

    it 'defaults to 10 results' do
      assert_equal 10, described_class.parse(fixture).size
    end

    it 'raises with the page text when no results are present' do
      err = assert_raises(RuntimeError) do
        described_class.parse('<html><body>service is currently unavailable</body></html>')
      end
      assert_includes err.message, 'service is currently unavailable'
    end

    it 'returns an empty array on a genuine "No results found" page' do
      html = '<html><body><div class="serp__results">No results found for foobarbaz.</div></body></html>'
      assert_equal [], described_class.parse(html)
    end

    it 'recognizes div.no-results as a genuine empty-results page' do
      html = '<html><body><div class="no-results">Nothing here</div></body></html>'
      assert_equal [], described_class.parse(html)
    end

    it 'still flags the anomaly modal even when "No results found" appears in body text' do
      html = <<~HTML
        <html><body>
          <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
          <p>No results found for anything because the page is a CAPTCHA.</p>
        </body></html>
      HTML
      assert_raises(Pikuri::Web::Search::Engines::Unavailable) { described_class.parse(html) }
    end

    it 'raises Unavailable on the DDG anomaly/CAPTCHA modal so the cascade can fall back' do
      html = <<~HTML
        <html><body>
          <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
          <div class="anomaly-modal__description">Please complete the following challenge to confirm this search was made by a human.</div>
        </body></html>
      HTML
      err = assert_raises(Pikuri::Web::Search::Engines::Unavailable) { described_class.parse(html) }
      assert_includes err.message, 'anomaly check'
      assert_includes err.message, 'Unfortunately, bots use DuckDuckGo too.'
    end
  end

  it 'lets its results be cached on disk' do
    assert described_class.new.disk_cacheable?
  end
end
