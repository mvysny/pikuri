# frozen_string_literal: true

require 'tool'
require 'tool/search/duckduckgo'

RSpec.describe Tool::Search::DuckDuckGo do
  let(:fixture) { File.read(File.expand_path('../../fixtures/ddg_ruby_language.html', __dir__)) }

  describe '.parse' do
    it 'renders results in smolagents-style markdown' do
      output = described_class.parse(fixture)
      assert output.start_with?("## Search Results\n\n"), 'missing smolagents header'
      assert_includes output, "[Ruby Programming Language](https://www.ruby-lang.org/en/)\n"
    end

    it 'decodes the uddg redirect to the real URL, parens preserved' do
      output = described_class.parse(fixture)
      assert_includes output,
                      '[Ruby (programming language) - Wikipedia]' \
                      '(https://en.wikipedia.org/wiki/Ruby_(programming_language))'
    end

    it 'strips <b> highlights from the snippet body' do
      output = described_class.parse(fixture)
      refute_includes output, '<b>'
      assert_includes output, 'Ruby has a simple and intuitive syntax'
    end

    it 'respects max_results' do
      output = described_class.parse(fixture, max_results: 3)
      assert_equal 3, output.scan(/^\[/).size
    end

    it 'defaults to 10 results' do
      output = described_class.parse(fixture)
      assert_equal 10, output.scan(/^\[/).size
    end

    it 'raises with the page text when no results are present' do
      err = assert_raises(RuntimeError) do
        described_class.parse('<html><body>service is currently unavailable</body></html>')
      end
      assert_includes err.message, 'service is currently unavailable'
    end

    it 'recognizes the DDG anomaly/CAPTCHA modal and surfaces its text' do
      html = <<~HTML
        <html><body>
          <div class="anomaly-modal__title">Unfortunately, bots use DuckDuckGo too.</div>
          <div class="anomaly-modal__description">Please complete the following challenge to confirm this search was made by a human.</div>
        </body></html>
      HTML
      err = assert_raises(RuntimeError) { described_class.parse(html) }
      assert_includes err.message, 'anomaly check'
      assert_includes err.message, 'Unfortunately, bots use DuckDuckGo too.'
    end
  end
end
