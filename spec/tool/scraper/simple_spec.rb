# frozen_string_literal: true

require 'faraday'
require 'faraday/adapter/test'

require 'tool/scraper/simple'

# Drive +Simple.fetch+ against an in-memory Faraday test adapter so we
# can exercise the HTTP→FetchError mapping (status code, redirect-loop,
# missing +Location+, +Faraday::Error+) without hitting the network.
# +Simple.fetch+ calls +Faraday.new+ itself, so the +around+ hook stubs
# +Faraday.new+ to hand back a connection wired to the test stubs;
# +after+ restores the original method.
RSpec.describe Tool::Scraper::Simple, '.fetch' do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  around do |example|
    original_new = Faraday.method(:new)
    test_stubs = stubs
    Faraday.define_singleton_method(:new) do |*_, **_|
      Faraday::Connection.new { |b| b.adapter :test, test_stubs }
    end
    begin
      example.run
    ensure
      Faraday.define_singleton_method(:new, original_new)
    end
  end

  it 'returns a Fetched with the body, normalized content-type, and URL on a 2xx' do
    stubs.get('https://example.com/page') { [200, { 'content-type' => 'text/html; charset=UTF-8' }, '<html>ok</html>'] }
    result = described_class.fetch('https://example.com/page')
    assert_kind_of Tool::Scraper::Simple::Fetched, result
    assert_equal '<html>ok</html>', result.body
    assert_equal 'text/html', result.content_type
    assert_equal 'https://example.com/page', result.url
  end

  it 'normalizes a missing content-type header to an empty string' do
    stubs.get('https://example.com/page') { [200, {}, 'body'] }
    assert_equal '', described_class.fetch('https://example.com/page').content_type
  end

  it 'follows a 3xx redirect that has a Location header and reports the final URL' do
    stubs.get('https://example.com/a') { [302, { 'location' => 'https://example.com/b' }, ''] }
    stubs.get('https://example.com/b') { [200, { 'content-type' => 'text/html' }, 'final'] }
    result = described_class.fetch('https://example.com/a')
    assert_equal 'final', result.body
    assert_equal 'https://example.com/b', result.url
  end

  it 'raises FetchError on HTTP 4xx with a short body excerpt' do
    long_body = "<html><body>#{'x' * 5_000}</body></html>"
    stubs.get('https://example.com/page') { [403, {}, long_body] }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'HTTP 403'
    assert_includes err.message, 'https://example.com/page'
    assert err.message.length < 500,
           "expected trimmed message, got #{err.message.length} chars: #{err.message[0, 80]}..."
    assert_includes err.message, '...', 'expected truncation marker on long body'
  end

  it 'collapses whitespace in the body excerpt so it stays a single readable line' do
    stubs.get('https://example.com/page') { [500, {}, "line1\n\n\n   line2\tline3"] }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'line1 line2 line3'
    refute_includes err.message, "\n", 'newlines must be collapsed'
  end

  it 'raises FetchError on HTTP 5xx' do
    stubs.get('https://example.com/page') { [503, {}, 'overloaded'] }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'HTTP 503'
  end

  it 'raises FetchError when the redirect budget is exhausted' do
    stubs.get('https://example.com/a') { [302, { 'location' => 'https://example.com/b' }, ''] }
    stubs.get('https://example.com/b') { [302, { 'location' => 'https://example.com/a' }, ''] }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/a') }
    assert_includes err.message, 'too many redirects'
  end

  it 'raises FetchError on a 3xx without a Location header' do
    stubs.get('https://example.com/page') { [302, {}, ''] }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'no Location header'
    assert_includes err.message, '302'
  end

  it 'wraps Faraday network errors as FetchError' do
    stubs.get('https://example.com/page') { raise Faraday::ConnectionFailed, 'getaddrinfo: Name does not resolve' }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'ConnectionFailed'
    assert_includes err.message, 'getaddrinfo'
    assert_includes err.message, 'https://example.com/page'
  end

  it 'wraps Faraday timeout errors as FetchError' do
    stubs.get('https://example.com/page') { raise Faraday::TimeoutError, 'execution expired' }
    err = assert_raises(Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'TimeoutError'
  end
end

# Exercise the content-type dispatch in +.dispatch+ directly, against
# hand-built {Fetched} values — no network. The HTML and (future) PDF
# extractors are tested separately; here we only verify that the right
# parser is picked and that unknown types surface as FetchError.
RSpec.describe Tool::Scraper::Simple, '.dispatch' do
  let(:fetched_class) { Tool::Scraper::Simple::Fetched }

  it 'routes text/html through Scraper::HTML.extract' do
    fetched = fetched_class.new(
      body: '<html><body><h1>Hi</h1><p>hello world</p></body></html>',
      content_type: 'text/html',
      url: 'https://example.com/'
    )
    out = described_class.dispatch(fetched)
    assert_includes out, 'hello world'
  end

  it 'routes application/xhtml+xml through Scraper::HTML.extract' do
    fetched = fetched_class.new(
      body: '<html><body><p>xhtml content</p></body></html>',
      content_type: 'application/xhtml+xml',
      url: 'https://example.com/'
    )
    assert_includes described_class.dispatch(fetched), 'xhtml content'
  end

  it 'routes application/pdf through Scraper::PDF.extract' do
    # Don't reach into PDF.extract for real PDF bytes — that path is
    # tested in pdf_spec. Here we just verify the dispatch arm exists by
    # stubbing PDF.extract.
    original = Tool::Scraper::PDF.method(:extract)
    Tool::Scraper::PDF.singleton_class.define_method(:extract) { |bytes| "PDF[#{bytes}]" }
    begin
      fetched = fetched_class.new(body: 'pdf-bytes', content_type: 'application/pdf', url: 'https://example.com/doc.pdf')
      assert_equal 'PDF[pdf-bytes]', described_class.dispatch(fetched)
    ensure
      Tool::Scraper::PDF.singleton_class.define_method(:extract, original)
    end
  end

  it 'raises FetchError for an unsupported content-type' do
    fetched = fetched_class.new(body: '{}', content_type: 'application/json', url: 'https://example.com/')
    err = assert_raises(Tool::Scraper::FetchError) { described_class.dispatch(fetched) }
    assert_includes err.message, 'unsupported content-type'
    assert_includes err.message, 'application/json'
    assert_includes err.message, 'https://example.com/'
  end

  it 'raises FetchError when the content-type is missing' do
    fetched = fetched_class.new(body: 'whatever', content_type: '', url: 'https://example.com/')
    err = assert_raises(Tool::Scraper::FetchError) { described_class.dispatch(fetched) }
    assert_includes err.message, 'unsupported content-type'
  end
end
