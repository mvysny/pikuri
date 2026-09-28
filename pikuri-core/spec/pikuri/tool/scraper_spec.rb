# frozen_string_literal: true

require 'faraday'
require 'faraday/adapter/test'

# Drive +Scraper.fetch+ against an in-memory Faraday test adapter so we
# can exercise the HTTP→FetchError mapping (status code, redirect-loop,
# missing +Location+, +Faraday::Error+) without hitting the network.
# +Scraper.fetch+ calls +Faraday.new+ itself, so the +around+ hook stubs
# +Faraday.new+ to hand back a connection wired to the test stubs;
# +after+ restores the original method.
RSpec.describe Pikuri::Tool::Scraper, '.fetch' do
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
    assert_kind_of Pikuri::Tool::Scraper::Fetched, result
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
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'HTTP 403'
    assert_includes err.message, 'https://example.com/page'
    assert err.message.length < 500,
           "expected trimmed message, got #{err.message.length} chars: #{err.message[0, 80]}..."
    assert_includes err.message, '...', 'expected truncation marker on long body'
  end

  it 'collapses whitespace in the body excerpt so it stays a single readable line' do
    stubs.get('https://example.com/page') { [500, {}, "line1\n\n\n   line2\tline3"] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'line1 line2 line3'
    refute_includes err.message, "\n", 'newlines must be collapsed'
  end

  it 'raises FetchError on HTTP 5xx' do
    stubs.get('https://example.com/page') { [503, {}, 'overloaded'] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'HTTP 503'
  end

  it 'raises FetchError when the redirect budget is exhausted' do
    stubs.get('https://example.com/a') { [302, { 'location' => 'https://example.com/b' }, ''] }
    stubs.get('https://example.com/b') { [302, { 'location' => 'https://example.com/a' }, ''] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/a') }
    assert_includes err.message, 'too many redirects'
  end

  it 'raises FetchError on a 3xx without a Location header' do
    stubs.get('https://example.com/page') { [302, {}, ''] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'no Location header'
    assert_includes err.message, '302'
  end

  it 'wraps Faraday network errors as FetchError' do
    stubs.get('https://example.com/page') { raise Faraday::ConnectionFailed, 'getaddrinfo: Name does not resolve' }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'ConnectionFailed'
    assert_includes err.message, 'getaddrinfo'
    assert_includes err.message, 'https://example.com/page'
  end

  it 'wraps Faraday timeout errors as FetchError' do
    stubs.get('https://example.com/page') { raise Faraday::TimeoutError, 'execution expired' }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.fetch('https://example.com/page') }
    assert_includes err.message, 'TimeoutError'
  end
end

# The request as it leaves the socket, through Faraday's real net_http
# adapter: header order is decided there, so the test adapter can't see it.
RSpec.describe Pikuri::Tool::Scraper, '.fetch on the wire' do
  before do
    @server = TCPServer.new('127.0.0.1', 0)
    @request_lines = Queue.new
    @thread = Thread.new do
      client = @server.accept
      lines = []
      while (line = client.gets) && line != "\r\n"
        lines << line.chomp
      end
      @request_lines << lines
      client.write "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
      client.close
    end
  end

  after do
    @thread.kill
    @server.close
  end

  it 'sends Host as the first header, with the port, then the Firefox User-Agent, then Accept' do
    port = @server.addr[1]
    described_class.fetch("http://127.0.0.1:#{port}/page")
    headers = @request_lines.pop.drop(1)
    assert_equal "Host: 127.0.0.1:#{port}", headers[0]
    assert_equal "User-Agent: #{Pikuri::Tool::Scraper::USER_AGENT}", headers[1]
    assert_equal "Accept: #{Pikuri::Tool::Scraper::ACCEPT}", headers[2]
    assert_includes Pikuri::Tool::Scraper::USER_AGENT, 'Firefox/'
  end
end

# End-to-end +.visit+ tests covering behavior layered on top of
# +fetch+ — the trailing-whitespace strip and the
# +Pikuri::Extractor+ → +FetchError+ mapping. Which extractor renders
# what is the registry's business (see extractor_spec.rb); here we
# only verify the wiring and the error conversion.
RSpec.describe Pikuri::Tool::Scraper, '.visit' do
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

  it 'strips leading and trailing whitespace from the extracted body but preserves interior structure' do
    body = "\n\n  # Title\n\nparagraph one\n\n    indented line\n\n\n"
    stubs.get('https://example.com/doc.md') { [200, { 'content-type' => 'text/markdown' }, body] }
    out = described_class.visit('https://example.com/doc.md')
    assert_equal "# Title\n\nparagraph one\n\n    indented line", out
  end

  it 'renders a text/html response through the HTML extractor' do
    stubs.get('https://example.com/page') do
      [200, { 'content-type' => 'text/html' },
       '<html><body><h1>Hi</h1><p>hello world</p></body></html>']
    end
    out = described_class.visit('https://example.com/page')
    assert_includes out, 'hello world'
    refute_includes out, '<p>'
  end

  it 'hands the response content-type to the extractor registry' do
    # Stub the registry front door to observe the hint; the routing
    # itself is extractor_spec.rb's business.
    original = Pikuri::Extractor.method(:extract)
    seen = nil
    Pikuri::Extractor.define_singleton_method(:extract) do |io, content_type:|
      seen = [io.read, content_type]
      'rendered'
    end
    begin
      stubs.get('https://example.com/doc.pdf') { [200, { 'content-type' => 'application/pdf' }, 'pdf-bytes'] }
      assert_equal 'rendered', described_class.visit('https://example.com/doc.pdf')
      assert_equal ['pdf-bytes', 'application/pdf'], seen
    ensure
      Pikuri::Extractor.define_singleton_method(:extract, original)
    end
  end

  it 'raises FetchError for an unsupported content-type' do
    stubs.get('https://example.com/blob') { [200, { 'content-type' => 'application/json' }, '{}'] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.visit('https://example.com/blob') }
    assert_includes err.message, 'unsupported content-type'
    assert_includes err.message, 'application/json'
    assert_includes err.message, 'https://example.com/blob'
  end

  it 'raises FetchError when the content-type is missing' do
    stubs.get('https://example.com/blob') { [200, {}, 'whatever'] }
    err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.visit('https://example.com/blob') }
    assert_includes err.message, 'unsupported content-type'
  end

  it 'maps extraction failures to FetchError so the web tools rescue one type' do
    # A plugged-in extractor that claims the content but cannot parse
    # it — the registry path a malformed PDF takes with pikuri-pdf
    # registered (whose own specs cover the real thing).
    broken = Module.new do
      def self.kind = :broken

      def self.matches?(sample:, content_type:)
        content_type == 'application/x-broken'
      end

      def self.extract(_io)
        raise Pikuri::Extractor::Error, 'rendering failed: bad content'
      end
    end

    Pikuri::Extractor.registry.unshift(broken)
    begin
      stubs.get('https://example.com/doc.bin') do
        [200, { 'content-type' => 'application/x-broken' }, 'not parseable']
      end
      err = assert_raises(Pikuri::Tool::Scraper::FetchError) { described_class.visit('https://example.com/doc.bin') }
      assert_includes err.message, 'rendering failed'
    ensure
      Pikuri::Extractor.registry.delete(broken)
    end
  end
end
