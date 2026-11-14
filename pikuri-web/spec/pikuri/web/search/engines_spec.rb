# frozen_string_literal: true

require 'tmpdir'

RSpec.describe Pikuri::Web::Search::Engines, '#providers' do
  it 'lists only DuckDuckGo when no provider keys are given' do
    assert_equal %w[DuckDuckGo], described_class.new.providers.map(&:label)
  end

  it 'treats a blank brave_key as unset' do
    assert_equal %w[DuckDuckGo], described_class.new(brave_key: '   ').providers.map(&:label)
  end

  it 'treats a blank exa_key as unset' do
    assert_equal %w[DuckDuckGo], described_class.new(exa_key: '   ').providers.map(&:label)
  end

  it 'includes Brave when its key is given' do
    assert_equal %w[DuckDuckGo Brave], described_class.new(brave_key: 'fake-key').providers.map(&:label)
  end

  it 'includes Exa when its key is given' do
    assert_equal %w[DuckDuckGo Exa], described_class.new(exa_key: 'fake-key').providers.map(&:label)
  end

  it 'includes Brave and Exa together when both keys are given' do
    assert_equal %w[DuckDuckGo Brave Exa],
                 described_class.new(brave_key: 'fake-brave', exa_key: 'fake-exa').providers.map(&:label)
  end

  it 'binds each key to its own provider (no key swap)' do
    by_label = described_class.new(brave_key: 'B-key', exa_key: 'E-key').providers.to_h { |p| [p.label, p] }
    assert_equal 'B-key', by_label['Brave'].instance_variable_get(:@api_key)
    assert_equal 'E-key', by_label['Exa'].instance_variable_get(:@api_key)
  end

  it 'drops DuckDuckGo when an explicit selection omits it' do
    engines = described_class.new(engines: [:brave], brave_key: 'fake-key')
    assert_equal %w[Brave], engines.providers.map(&:label)
  end

  it 'ignores a supplied key that the selection does not name' do
    engines = described_class.new(engines: %w[duckduckgo], brave_key: 'fake-key', exa_key: 'fake-key')
    assert_equal %w[DuckDuckGo], engines.providers.map(&:label)
  end

  it 'refuses a selection naming an engine whose key is missing' do
    error = assert_raises(ArgumentError) { described_class.new(engines: [:exa], brave_key: 'fake-key') }
    assert_match(/exa needs exa_key/, error.message)
  end
end

RSpec.describe Pikuri::Web::Search::Engines, '.resolve' do
  it 'derives the set from the keys when no selection is given' do
    assert_equal %i[duckduckgo], described_class.resolve(engines: nil)
    assert_equal %i[duckduckgo brave], described_class.resolve(engines: nil, brave_key: 'B')
    assert_equal %i[duckduckgo brave exa], described_class.resolve(engines: nil, brave_key: 'B', exa_key: 'E')
  end

  it 'treats a blank key as absent when deriving the set' do
    assert_equal %i[duckduckgo], described_class.resolve(engines: nil, brave_key: '   ')
  end

  it 'accepts String and Symbol names, case-insensitively' do
    assert_equal %i[duckduckgo brave], described_class.resolve(engines: ['DuckDuckGo', :Brave], brave_key: 'B')
  end

  it 'normalizes an explicit list to canonical order, so it reads as a set' do
    resolved = described_class.resolve(engines: %w[exa brave duckduckgo], brave_key: 'B', exa_key: 'E')
    assert_equal %i[duckduckgo brave exa], resolved
  end

  it 'accepts a keyed engine alone, without DuckDuckGo' do
    assert_equal %i[brave], described_class.resolve(engines: %w[brave], brave_key: 'B')
  end

  it 'refuses an empty selection' do
    error = assert_raises(ArgumentError) { described_class.resolve(engines: []) }
    assert_match(/non-empty list of engine names/, error.message)
  end

  it 'refuses a selection that is not a list, without echoing it' do
    error = assert_raises(ArgumentError) { described_class.resolve(engines: 'BSA-secret') }
    assert_match(/non-empty list of engine names/, error.message)
    assert_match(/got String/, error.message)
    refute_includes error.message, 'BSA-secret'
  end

  it 'refuses an unknown engine name and names the known ones' do
    error = assert_raises(ArgumentError) { described_class.resolve(engines: %w[duckduckgo googel]) }
    assert_match(/unknown engine\(s\) googel/, error.message)
    assert_match(/known engines are duckduckgo, brave, exa/, error.message)
  end

  it 'refuses a repeated engine, which would weight the shuffle' do
    error = assert_raises(ArgumentError) do
      described_class.resolve(engines: %w[brave Brave], brave_key: 'B')
    end
    assert_match(/brave listed more than once/, error.message)
  end

  it 'refuses a keyed engine whose key is blank, naming the keyword to supply' do
    error = assert_raises(ArgumentError) { described_class.resolve(engines: %w[brave exa], brave_key: '  ') }
    assert_match(/brave needs brave_key/, error.message)
    assert_match(/exa needs exa_key/, error.message)
  end

  it 'accepts a key for an engine left out of the selection' do
    assert_equal %i[duckduckgo], described_class.resolve(engines: %w[duckduckgo], exa_key: 'E')
  end
end

RSpec.describe Pikuri::Web::Search::Engines, '.config_from_h' do
  it 'maps a config block onto the constructor keywords' do
    config = { 'brave_key' => 'B', 'exa_key' => 'E', 'engines' => %w[brave] }
    assert_equal({ brave_key: 'B', exa_key: 'E', engines: %w[brave] }, described_class.config_from_h(config))
  end

  it 'accepts Symbol keys too' do
    assert_equal({ engines: %w[brave] }, described_class.config_from_h(engines: %w[brave]))
  end

  it 'maps an absent block to empty keywords, so no caller needs a fallback' do
    assert_equal({}, described_class.config_from_h(nil))
  end

  it 'refuses a block that is not a Hash' do
    error = assert_raises(ArgumentError) { described_class.config_from_h('brave') }
    assert_match(/expected a Hash of engines, brave_key, exa_key/, error.message)
  end

  it 'refuses an unknown field, which a typo would otherwise silently drop' do
    error = assert_raises(ArgumentError) { described_class.config_from_h('brave_api_key' => 'B') }
    assert_match(/unknown field\(s\) brave_api_key/, error.message)
    assert_match(/known fields are engines, brave_key, exa_key/, error.message)
  end

  it 'refuses a key field that is not a String, without echoing its value' do
    error = assert_raises(ArgumentError) { described_class.config_from_h('brave_key' => %w[secret]) }
    assert_match(/brave_key must be a String, got Array/, error.message)
    refute_includes error.message, 'secret'
  end
end

RSpec.describe Pikuri::Web::Search::Engines, '#search' do
  # Single-row helper so the test providers can describe what they
  # received in their one synthetic Result without repetition.
  def good_result(query, max_results)
    [Pikuri::Web::Search::Result.new(
      url: 'https://example.com/ok',
      title: "ok: #{query} (#{max_results})",
      body: ''
    )]
  end

  # Synthetic providers are plain modules exposing the same duck type the
  # real provider instances do — +.search(query, max_results:, cancellable:)+
  # + +.label+ — so the cascade drives them identically.
  let(:good) do
    parent = self
    Module.new do
      define_singleton_method(:label) { 'Good' }
      define_singleton_method(:disk_cacheable?) { true }
      define_singleton_method(:search) do |query, max_results:, cancellable: nil|
        _ = cancellable
        parent.good_result(query, max_results)
      end
    end
  end

  let(:bad) do
    Module.new do
      def self.label = 'Bad'

      def self.search(_query, max_results:, cancellable: nil)
        _ = [max_results, cancellable]
        raise Pikuri::Web::Search::Engines::Unavailable, 'rate-limited'
      end
    end
  end

  # Markdown-rendered output for what +good_result+ produces, so the
  # +#search+ contract (String back to the caller) stays readable in the
  # assertions below.
  def good_markdown(query, max_results)
    "## Search Results\n\n[ok: #{query} (#{max_results})](https://example.com/ok)\n"
  end

  # Build an engine whose provider cascade is the given synthetic list.
  # Both caches default to NULL — caching examples pass a real tmpdir
  # disk cache or a fresh memory cache instead. Provider selection is normally derived from the
  # keys; here we override it directly on the instance so the cascade can
  # be exercised with synthetic providers.
  def engine_with(providers, disk_cache: Pikuri::Web::UrlCache::NULL, memory_cache: Pikuri::Web::UrlCache::NULL)
    e = described_class.new(disk_cache: disk_cache, memory_cache: memory_cache)
    e.define_singleton_method(:providers) { providers }
    e
  end

  it 'returns the first successful provider output rendered as Markdown' do
    assert_equal good_markdown('ruby', 10), engine_with([good]).search('ruby', max_results: 10).to_s
  end

  it 'falls back past an Unavailable provider to one that succeeds' do
    assert_equal good_markdown('ruby', 5), engine_with([bad, good]).search('ruby', max_results: 5).to_s
  end

  it 'renders an empty result list as the standard no-results stub' do
    empty = Module.new do
      def self.label = 'Empty'
      def self.disk_cacheable? = true
      def self.search(_q, max_results:, cancellable: nil) = (_ = [max_results, cancellable]; [])
    end
    assert_equal "## Search Results\n\nNo results found.", engine_with([empty]).search('ruby', max_results: 10).to_s
  end

  it 'returns an "Error: ..." string when every provider is unavailable' do
    result = engine_with([bad, bad]).search('ruby', max_results: 10).to_s
    assert_match(/\AError: all search providers temporarily unavailable/, result)
    assert_includes result, 'Bad (rate-limited)'
  end

  it 'lets non-Unavailable exceptions bubble up' do
    boom = Module.new do
      def self.label = 'Boom'

      def self.search(_query, max_results:, cancellable: nil)
        _ = [max_results, cancellable]
        raise 'network kaboom'
      end
    end
    # Single provider — the cascade shuffles its provider list, so a
    # multi-provider stub would non-deterministically pick a different one
    # first and never trigger boom.
    assert_raises(RuntimeError) { engine_with([boom]).search('ruby', max_results: 10).to_s }
  end

  it 'normalizes the query (trim + collapse whitespace) before dispatch' do
    seen = nil
    spy = Module.new
    spy.define_singleton_method(:label) { 'Spy' }
    spy.define_singleton_method(:disk_cacheable?) { true }
    spy.define_singleton_method(:search) do |q, max_results:, cancellable: nil|
        _ = cancellable
      seen = q
      [Pikuri::Web::Search::Result.new(url: 'https://example.com', title: "ok (#{max_results})", body: '')]
    end

    engine_with([spy]).search("  ruby \n  on   rails  ", max_results: 10)
    assert_equal 'ruby on rails', seen
  end

  it 'rejects an empty query' do
    assert_raises(ArgumentError) { engine_with([good]).search('   ', max_results: 10).to_s }
  end

  it 'caches the answer so a subsequent call with the same query skips providers' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::Web::UrlCache::OnDisk.new(ttl: 60, dir: dir)
      calls = 0
      once = Module.new
      once.define_singleton_method(:label) { 'Once' }
      once.define_singleton_method(:disk_cacheable?) { true }
      once.define_singleton_method(:search) do |q, max_results:, cancellable: nil|
        _ = cancellable
        calls += 1
        [Pikuri::Web::Search::Result.new(url: 'https://example.com', title: "ok: #{q} (#{max_results})", body: '')]
      end
      engine = engine_with([once], disk_cache: cache)

      expected = "## Search Results\n\n[ok: ruby (10)](https://example.com)\n"
      assert_equal expected, engine.search('ruby', max_results: 10).to_s
      assert_equal expected, engine.search('ruby', max_results: 10).to_s
      assert_equal 1, calls, 'second call should be served from cache'
    end
  end

  it 'does not cache the all-unavailable error string' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::Web::UrlCache::OnDisk.new(ttl: 60, dir: dir)
      engine = engine_with([bad, bad], disk_cache: cache)
      engine.search('ruby', max_results: 10)
      # Now flip to a working provider on the same cache — if the error had
      # been cached, this would still return the previous "Error: ..." string.
      working = good
      engine.define_singleton_method(:providers) { [working] }
      assert_equal good_markdown('ruby', 10), engine.search('ruby', max_results: 10).to_s
    end
  end

  describe 'where results are cached' do
    # A provider answering +disk_cacheable?+ as given, counting its calls.
    def counting(disk_cacheable)
      parent = self
      calls = 0
      provider = Module.new
      provider.define_singleton_method(:label) { 'Counting' }
      provider.define_singleton_method(:disk_cacheable?) { disk_cacheable }
      provider.define_singleton_method(:calls) { calls }
      provider.define_singleton_method(:search) do |query, max_results:, cancellable: nil|
        _ = cancellable
        calls += 1
        parent.good_result(query, max_results)
      end
      provider
    end

    around do |example|
      Dir.mktmpdir('pikuri-cache-test-') do |dir|
        @disk = Pikuri::Web::UrlCache::OnDisk.new(ttl: 60, dir: dir)
        @memory = Pikuri::Web::UrlCache::InMemory.new(ttl: 60, max_entries: 10)
        example.run
      end
    end

    # The cached rows' URLs — an entry is rows as JSON, not Markdown.
    def cached_urls(cache)
      JSON.parse(cache.read('ruby')).map { |row| row['url'] }
    end

    it 'keeps a disk_cacheable winner\'s results on disk, not in memory' do
      engine_with([counting(true)], disk_cache: @disk, memory_cache: @memory).search('ruby', max_results: 10)
      assert_equal ['https://example.com/ok'], cached_urls(@disk)
      assert_nil @memory.read('ruby')
    end

    it 'never writes a non-disk_cacheable winner\'s results to disk' do
      engine_with([counting(false)], disk_cache: @disk, memory_cache: @memory).search('ruby', max_results: 10)
      assert_nil @disk.read('ruby')
      assert_equal ['https://example.com/ok'], cached_urls(@memory)
    end

    it 'serves a memory-cached search without asking the provider again' do
      provider = counting(false)
      engine = engine_with([provider], disk_cache: @disk, memory_cache: @memory)
      2.times { engine.search('ruby', max_results: 10) }
      assert_equal 1, provider.calls
    end
  end
end

RSpec.describe Pikuri::Web::Search::Engines, 'logging' do
  let(:log_io) { StringIO.new }

  let(:pair_provider) do
    Module.new do
      def self.label = 'Pair'
      def self.disk_cacheable? = true

      def self.search(query, max_results:, cancellable: nil)
        _ = cancellable
        _ = max_results
        [
          Pikuri::Web::Search::Result.new(url: 'https://example.com/a', title: 'Result A', body: "body a — about #{query}"),
          Pikuri::Web::Search::Result.new(url: 'https://example.com/b', title: 'Result B', body: 'body b')
        ]
      end
    end
  end

  around do |example|
    original_io = Pikuri.log_io
    Pikuri.log_io = log_io
    begin
      example.run
    ensure
      Pikuri.log_io = original_io
    end
  end

  # Each engine has its own @last_logged_providers memo, so a fresh engine
  # per example starts unlogged — no global reset needed.
  def engine_with(providers)
    e = Pikuri::Web::Search::Engines.new(disk_cache: Pikuri::Web::UrlCache::NULL, memory_cache: Pikuri::Web::UrlCache::NULL)
    e.define_singleton_method(:providers) { providers }
    e
  end

  it 'logs the available engines, tagged with the Engines progname, on first search' do
    engine_with([pair_provider]).search('ruby', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
  end

  it 'logs the chosen engine, query, and result count for a successful search' do
    engine_with([pair_provider]).search('ruby on rails', max_results: 10)
    assert_includes log_io.string, 'INFO -- Engines: engine=Pair query="ruby on rails" results=2'
  end

  it 'does not relog the available-engines line when the provider set is unchanged' do
    engine = engine_with([pair_provider])
    engine.search('first', max_results: 10)
    engine.search('second', max_results: 10)
    assert_equal 1, log_io.string.scan(/engines available:/).count
  end

  it 'logs a cache=hit line when a subsequent search is served from cache' do
    Dir.mktmpdir('pikuri-cache-test-') do |dir|
      cache = Pikuri::Web::UrlCache::OnDisk.new(ttl: 60, dir: dir)
      engine = Pikuri::Web::Search::Engines.new(disk_cache: cache, memory_cache: Pikuri::Web::UrlCache::NULL)
      provider = pair_provider
      engine.define_singleton_method(:providers) { [provider] }
      engine.search('ruby', max_results: 10)
      log_io.truncate(0)
      log_io.rewind
      engine.search('ruby', max_results: 10)
      assert_match(/INFO -- Engines: cache=hit query="ruby" bytes=\d+/, log_io.string)
      refute_match(/engine=Pair/, log_io.string)
    end
  end

  it 'relogs the available-engines line when the provider set changes' do
    other = Module.new do
      def self.label = 'Other'
      def self.disk_cacheable? = true

      def self.search(_query, max_results:, cancellable: nil)
        _ = cancellable
        _ = max_results
        [Pikuri::Web::Search::Result.new(url: 'https://example.com/only', title: 'Only', body: 'body')]
      end
    end

    engine = engine_with([pair_provider])
    engine.search('first', max_results: 10)
    engine.define_singleton_method(:providers) { [other] }
    engine.search('second', max_results: 10)

    assert_includes log_io.string, 'INFO -- Engines: engines available: Pair'
    assert_includes log_io.string, 'INFO -- Engines: engines available: Other'
  end
end

RSpec.describe Pikuri::Web::Search::Engines, 'page text' do
  let(:store) { Pikuri::Web::Search::PageStore.new }
  let(:memory) { Pikuri::Web::UrlCache::InMemory.new(ttl: 60, max_entries: 10) }

  # Two rows: the first came back with page text, the second without.
  let(:texty) do
    calls = 0
    Module.new do
      define_singleton_method(:label) { 'Texty' }
      define_singleton_method(:disk_cacheable?) { false }
      define_singleton_method(:calls) { calls }
      define_singleton_method(:search) do |_query, max_results:, cancellable: nil|
        _ = [max_results, cancellable]
        calls += 1
        [
          Pikuri::Web::Search::Result.new(url: 'https://example.com/a', title: 'A', body: 'snippet a',
                                           text: 'full text of a', indexed_at: Time.utc(2026, 11, 10)),
          Pikuri::Web::Search::Result.new(url: 'https://example.com/b', title: 'B', body: 'snippet b')
        ]
      end
    end
  end

  def engine(providers, page_text: true, page_store: store)
    e = described_class.new(engines: [:exa], exa_key: 'k', page_text: page_text,
                            disk_cache: Pikuri::Web::UrlCache::NULL, memory_cache: memory, page_store: page_store)
    e.define_singleton_method(:providers) { providers }
    e
  end

  it 'leads a row whose text came back with its handle, and stores the text under it' do
    out = engine([texty]).search('ruby', max_results: 10).to_s
    handle = store.handle_for('https://example.com/a')
    assert_match(/\A\h{8}\z/, handle)
    assert_includes out, "[#{handle}] [A](https://example.com/a)\nsnippet a"
    assert_includes out, "\n\n[B](https://example.com/b)\nsnippet b"
    page = store.read(handle)
    assert_equal 'full text of a', page.text
    assert_equal Time.utc(2026, 11, 10), page.indexed_at
  end

  it 'keeps page text out of the query cache' do
    engine([texty]).search('ruby', max_results: 10)
    rows = JSON.parse(memory.read('ruby'))
    assert_equal [true, false], rows.map { |r| r['has_text'] }
    refute(rows.any? { |r| r.key?('text') })
  end

  it 'still shows the handle on a query-cache hit' do
    e = engine([texty])
    first = e.search('ruby', max_results: 10).to_s
    assert_equal first, e.search('ruby', max_results: 10).to_s
    assert_equal 1, texty.calls
  end

  it 'renders a row whose page was evicted since without a handle' do
    e = engine([texty])
    e.search('ruby', max_results: 10)
    evicted = engine([texty], page_store: Pikuri::Web::Search::PageStore.new)
    out = evicted.search('ruby', max_results: 10).to_s
    assert_includes out, "## Search Results\n\n[A](https://example.com/a)"
  end

  it 'prints no handle and stores nothing without page_text, even for a row with text' do
    out = engine([texty], page_text: false).search('ruby', max_results: 10).to_s
    refute_match(/\[\h{8}\]/, out)
    assert_nil store.handle_for('https://example.com/a')
  end

  it 'counts rows for the summary, whatever the snippets say' do
    assert_equal 'Returned 2 search results', engine([texty]).search('ruby', max_results: 10).summary
  end

  it 'refuses page_text without an engine that can bring text back' do
    err = assert_raises(ArgumentError) { described_class.new(engines: [:duckduckgo], page_text: true) }
    assert_includes err.message, 'page_text needs brave or exa'
  end

  it 'builds its Brave and Exa in page-text mode' do
    e = described_class.new(engines: %i[duckduckgo brave exa], brave_key: 'b', exa_key: 'e', page_text: true)
    assert_equal [false, true, true], e.providers.map { |p| p.instance_variable_get(:@page_text) || false }
  end

  it 'leaves DuckDuckGo out of a key-derived page-text cascade' do
    e = described_class.new(brave_key: 'b', page_text: true)
    assert_equal ['Brave'], e.providers.map(&:label)
  end

  it 'keeps DuckDuckGo in a page-text cascade that lists it' do
    e = described_class.new(engines: %i[duckduckgo brave], brave_key: 'b', page_text: true)
    assert_equal %w[DuckDuckGo Brave], e.providers.map(&:label)
  end
end
