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

  it 'returns the response body on a 2xx' do
    stubs.get('https://example.com/page') { [200, {}, '<html>ok</html>'] }
    assert_equal '<html>ok</html>', described_class.fetch('https://example.com/page')
  end

  it 'follows a 3xx redirect that has a Location header' do
    stubs.get('https://example.com/a') { [302, { 'location' => 'https://example.com/b' }, ''] }
    stubs.get('https://example.com/b') { [200, {}, 'final'] }
    assert_equal 'final', described_class.fetch('https://example.com/a')
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

# Exercise the JSON-LD vs. readability decision in +.extract+ directly,
# without going through the network. Each example feeds a small HTML
# fixture and asserts which path won.
RSpec.describe Tool::Scraper::Simple, '.extract' do
  it 'falls through to readability when JSON-LD has no content fields (Wikipedia-shape)' do
    # Wikipedia ships an Article JSON-LD block with only metadata —
    # name, author, datePublished, dateModified — and the actual page
    # content lives in the HTML body. Without the content-field gate
    # in best_jsonld_node, the scraper would emit a few lines of
    # metadata and drop the article.
    html = <<~HTML
      <html>
        <head>
          <title>X86 - Wikipedia</title>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "name": "X86",
              "author": { "@type": "Organization", "name": "Contributors to Wikimedia projects" },
              "datePublished": "2001-10-31T13:12:04Z"
            }
          </script>
        </head>
        <body>
          <article>
            <h1>x86</h1>
            <p>x86 is a family of complex instruction set computer instruction set architectures
            initially developed by Intel based on the Intel 8086 microprocessor and its 8088 variant.</p>
            <p>The 8086 was introduced in 1978 as a fully 16-bit extension of Intel's 8-bit 8080
            microprocessor, with memory segmentation as a solution for addressing more memory than
            can be covered by a plain 16-bit address.</p>
          </article>
        </body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, 'x86 is a family of complex instruction set computer'
    assert_includes out, '8086 was introduced in 1978'
    refute_includes out, '**Author:**',
                    'JSON-LD path should not have fired — that block has no description/articleBody'
  end

  it 'uses the JSON-LD fast path when an Article carries a description' do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Article",
              "name": "Hello",
              "description": "Short article summary that the LLM actually wants.",
              "author": "Jane Doe"
            }
          </script>
        </head>
        <body><p>chrome and ads</p></body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Hello'
    assert_includes out, 'Short article summary that the LLM actually wants.'
    assert_includes out, '**Author:** Jane Doe'
  end

  it 'uses the JSON-LD fast path when a Product carries offers (no description needed)' do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {
              "@context": "https://schema.org",
              "@type": "Product",
              "name": "Widget",
              "sku": "W-1",
              "offers": { "@type": "Offer", "price": "9.99", "priceCurrency": "USD" }
            }
          </script>
        </head>
        <body><p>chrome and ads</p></body>
      </html>
    HTML

    out = described_class.extract(html)
    assert_includes out, '# Widget'
    assert_includes out, '**Price:** 9.99 USD'
    assert_includes out, '**SKU:** W-1'
  end
end
