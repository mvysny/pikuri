# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Pikuri::Web::Fetch, '.fetch' do
  # +Scraper.fetch+ is the unit boundary here: stub it per-test
  # so we can drive Fetch's content-type/truncation/error/cache behavior
  # without any HTTP. The +around+ hook restores the original method
  # afterwards so the stub cannot leak across examples.
  around do |example|
    original = Pikuri::Web::Scraper.method(:fetch)
    begin
      example.run
    ensure
      Pikuri::Web::Scraper.singleton_class.define_method(:fetch, original)
    end
  end

  # Replace +Scraper.fetch+ with +block+. The block runs as a singleton-
  # class method on +Scraper+, so it cannot call other example-group
  # helpers (different +self+) — but it does close over local variables,
  # which is enough to drive every test case below.
  def stub_fetch(&block)
    Pikuri::Web::Scraper.singleton_class.define_method(:fetch, &block)
  end

  # Convenience wrapper for the common "respond with this Fetched" case
  # — keeps +Pikuri::Web::Scraper::Fetched.new(...)+ out of every test.
  def stub_fetched(body:, content_type:)
    fetched_class = Pikuri::Web::Scraper::Fetched
    stub_fetch do |url, **|
      fetched_class.new(body: body, content_type: content_type, url: url)
    end
  end

  def with_real_cache
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::Web::UrlCache::OnDisk.new(ttl: 60, dir: dir)
      original_cache = described_class.method(:cache)
      described_class.singleton_class.define_method(:cache) { cache }
      begin
        yield
      ensure
        described_class.singleton_class.define_method(:cache, original_cache)
      end
    end
  end

  it 'returns the body verbatim for text/plain' do
    stub_fetched(body: 'hello world', content_type: 'text/plain')
    assert_equal 'hello world', described_class.fetch('https://example.com/x.txt').to_s
  end

  it 'returns the body verbatim for text/html (no Markdown extraction)' do
    stub_fetched(body: '<html><body>hi</body></html>', content_type: 'text/html')
    assert_equal '<html><body>hi</body></html>', described_class.fetch('https://example.com').to_s
  end

  it 'accepts application/json' do
    stub_fetched(body: '{"k":"v"}', content_type: 'application/json')
    assert_equal '{"k":"v"}', described_class.fetch('https://example.com/api').to_s
  end

  it 'accepts application/xml' do
    stub_fetched(body: '<root/>', content_type: 'application/xml')
    assert_equal '<root/>', described_class.fetch('https://example.com/feed').to_s
  end

  it 'refuses application/pdf with an error string' do
    stub_fetched(body: '%PDF-1.4...', content_type: 'application/pdf')
    result = described_class.fetch('https://example.com/doc.pdf').to_s
    assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    assert_includes result, 'application/pdf'
    assert_includes result, 'web_scrape'
  end

  it 'refuses image/png with an error string' do
    stub_fetched(body: "\x89PNG\r\n", content_type: 'image/png')
    result = described_class.fetch('https://example.com/x.png').to_s
    assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    assert_includes result, 'image/png'
  end

  it 'refuses application/octet-stream with an error string' do
    stub_fetched(body: 'binary', content_type: 'application/octet-stream')
    result = described_class.fetch('https://example.com/blob').to_s
    assert result.start_with?('Error:')
    assert_includes result, 'application/octet-stream'
  end

  it 'truncates output above max_chars and appends a marker noting the original length' do
    stub_fetched(body: 'a' * 100, content_type: 'text/plain')
    result = described_class.fetch('https://example.com', max_chars: 10).to_s
    assert result.start_with?('aaaaaaaaaa')
    assert_includes result, 'truncated at 10 of 100'
  end

  it 'clamps max_chars to MAX_MAX_CHARS' do
    stub_fetched(body: 'a' * 200_000, content_type: 'text/plain')
    result = described_class.fetch('https://example.com', max_chars: 10_000_000).to_s
    assert_includes result, "truncated at #{Pikuri::Web::Fetch::MAX_MAX_CHARS} of 200000"
  end

  it 'answers Result.error when Scraper.fetch raises FetchError' do
    stub_fetch { |url, **| raise Pikuri::Web::Scraper::FetchError, "HTTP 404 fetching #{url}: not found" }
    result = described_class.fetch('https://example.com/missing').to_s
    assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    assert_includes result, 'HTTP 404'
    assert_includes result, 'https://example.com/missing'
  end

  it 'lets non-FetchError exceptions bubble up so bugs stay visible' do
    stub_fetch { |_url, **| raise 'parser regression' }
    err = assert_raises(RuntimeError) { described_class.fetch('https://example.com').to_s }
    assert_equal 'parser regression', err.message
  end

  it 'does not cache a refused content-type, so a retry hits the network again' do
    with_real_cache do
      calls = 0
      fetched_class = Pikuri::Web::Scraper::Fetched
      stub_fetch do |url, **|
        calls += 1
        fetched_class.new(body: '%PDF', content_type: 'application/pdf', url: url)
      end
      described_class.fetch('https://example.com/doc.pdf')
      described_class.fetch('https://example.com/doc.pdf')
      assert_equal 2, calls,
                   'second call must re-invoke Scraper.fetch — refusals must not be cached'
    end
  end

  it 'does not cache a FetchError, so a retry hits the network again' do
    with_real_cache do
      calls = 0
      stub_fetch do |_url, **|
        calls += 1
        raise Pikuri::Web::Scraper::FetchError, 'HTTP 503 service unavailable'
      end
      described_class.fetch('https://example.com')
      described_class.fetch('https://example.com')
      assert_equal 2, calls,
                   'second call must re-invoke Scraper.fetch — failures must not be cached for the TTL'
    end
  end

  it 'caches a successful fetch so a subsequent call skips the network' do
    with_real_cache do
      calls = 0
      fetched_class = Pikuri::Web::Scraper::Fetched
      stub_fetch do |url, **|
        calls += 1
        fetched_class.new(body: 'cached body', content_type: 'text/plain', url: url)
      end
      assert_equal 'cached body', described_class.fetch('https://example.com').to_s
      assert_equal 'cached body', described_class.fetch('https://example.com').to_s
      assert_equal 1, calls, 'second call should be served from cache'
    end
  end
end

RSpec.describe Pikuri::Web::Fetch, '.textual?' do
  it 'accepts every text/* type' do
    %w[text/plain text/html text/csv text/markdown text/x-ruby text/css].each do |ct|
      assert described_class.textual?(ct), "expected #{ct} to be textual"
    end
  end

  it 'accepts the application/* allowlist' do
    Pikuri::Web::Fetch::TEXTUAL_APPLICATION_TYPES.each do |ct|
      assert described_class.textual?(ct), "expected #{ct} to be textual"
    end
  end

  it 'rejects application/pdf and image/png' do
    refute described_class.textual?('application/pdf')
    refute described_class.textual?('image/png')
    refute described_class.textual?('application/octet-stream')
  end
end

RSpec.describe 'Pikuri::Web::FETCH' do
  it 'is advertised to the LLM as `fetch`' do
    assert_equal 'fetch', Pikuri::Web::FETCH.name
  end

  it 'answers Result.error when Scraper.fetch raises FetchError, instead of crashing the agent loop' do
    original = Pikuri::Web::Scraper.method(:fetch)
    Pikuri::Web::Scraper.singleton_class.define_method(:fetch) do |url, **|
      raise Pikuri::Web::Scraper::FetchError, "HTTP 404 fetching #{url}: not found"
    end
    begin
      result = Pikuri::Web::FETCH.run('url' => 'https://example.com/missing')
      assert result.error?, "expected a Result.error, got #{result.inspect}"
      assert_includes result.content, 'HTTP 404'
    ensure
      Pikuri::Web::Scraper.singleton_class.define_method(:fetch, original)
    end
  end
end
