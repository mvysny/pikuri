# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Pikuri::Web::Scrape, '.visit' do
  # +Scraper.visit+ is the unit boundary here: stub it per-test
  # so we can drive Scrape's truncation/error/cache behavior without
  # any HTTP. The +around+ hook restores the original method afterwards
  # so the stub cannot leak across examples.
  around do |example|
    original = Pikuri::Web::Scraper.method(:visit)
    begin
      example.run
    ensure
      Pikuri::Web::Scraper.singleton_class.define_method(:visit, original)
    end
  end

  def stub_visit(&block)
    Pikuri::Web::Scraper.singleton_class.define_method(:visit, &block)
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

  it 'returns the rendered Markdown for a fetched page' do
    stub_visit { |_url| '# hello' }
    assert_equal '# hello', described_class.visit('https://example.com').to_s
  end

  it 'truncates output above max_chars and appends a marker noting the original length' do
    stub_visit { |_url| 'a' * 100 }
    result = described_class.visit('https://example.com', max_chars: 10).to_s
    assert result.start_with?('aaaaaaaaaa')
    assert_includes result, 'truncated at 10 of 100'
  end

  it 'answers Result.error when Scraper raises FetchError' do
    stub_visit { |url| raise Pikuri::Web::Scraper::FetchError, "HTTP 403 fetching #{url}: forbidden" }
    result = described_class.visit('https://example.com/page').to_s
    assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
    assert_includes result, 'HTTP 403'
    assert_includes result, 'https://example.com/page'
  end

  it 'lets non-FetchError exceptions bubble up so bugs stay visible' do
    stub_visit { |_url| raise 'parser regression' }
    err = assert_raises(RuntimeError) { described_class.visit('https://example.com').to_s }
    assert_equal 'parser regression', err.message
  end

  it 'does not cache a FetchError, so a retry hits the scraper again' do
    with_real_cache do
      calls = 0
      stub_visit do |_url|
        calls += 1
        raise Pikuri::Web::Scraper::FetchError, 'HTTP 503 service unavailable'
      end
      described_class.visit('https://example.com')
      described_class.visit('https://example.com')
      assert_equal 2, calls,
                   'second call must re-invoke the scraper — failures must not be cached for the TTL'
    end
  end

  it 'caches a successful fetch so a subsequent visit skips the scraper' do
    with_real_cache do
      calls = 0
      stub_visit do |_url|
        calls += 1
        '# cached page'
      end
      assert_equal '# cached page', described_class.visit('https://example.com').to_s
      assert_equal '# cached page', described_class.visit('https://example.com').to_s
      assert_equal 1, calls, 'second call should be served from cache'
    end
  end
end

RSpec.describe 'Pikuri::Web::SCRAPE' do
  it 'is advertised to the LLM as `web_scrape`' do
    assert_equal 'web_scrape', Pikuri::Web::SCRAPE.name
  end

  it 'answers Result.error when Scraper raises FetchError, instead of crashing the agent loop' do
    original = Pikuri::Web::Scraper.method(:visit)
    Pikuri::Web::Scraper.singleton_class.define_method(:visit) do |url|
      raise Pikuri::Web::Scraper::FetchError, "HTTP 404 fetching #{url}: not found"
    end
    begin
      result = Pikuri::Web::SCRAPE.run('url' => 'https://example.com/missing')
      assert result.error?, "expected a Result.error, got #{result.inspect}"
      assert_includes result.content, 'HTTP 404'
    ensure
      Pikuri::Web::Scraper.singleton_class.define_method(:visit, original)
    end
  end
end
