# frozen_string_literal: true

module Pikuri
  module Web
    # Text payloads cached by key within a TTL, so a tool doesn't redo a request.
    # Two stores share one duck-typed API:
    #
    #   cache = UrlCache::OnDisk.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_scrape")
    #   cache = UrlCache::InMemory.new(ttl: UrlCache::DEFAULT_TTL, max_entries: 100)
    #
    #   cache.fetch(key) { compute }   # yield on a miss, store, return; a raise stores nothing
    #   cache.read(key)                # => String, or nil on a miss or stale entry
    #   cache.write(key, value)        # => value; replaces any entry
    #
    # Pick the store by what the payload's source allows. {OnDisk} survives a
    # restart and is shared by every pikuri process; {InMemory} lives only as
    # long as the Ruby VM, for results whose terms forbid storing them — a search
    # provider says which via +disk_cacheable?+. Each user holds its own
    # instance in a constant, never a shared one: the dir, TTL and size are per
    # use. {NULL} stands in for either.
    module UrlCache
      # Root dir for the {OnDisk} subdirs, per XDG:
      # +$XDG_CACHE_HOME/pikuri/url_cache+ or +~/.cache/pikuri/url_cache+. Each
      # user picks its own subdir (+"#{ROOT_DIR}/web_scrape"+) so keys can't
      # collide.
      #
      # @return [String]
      ROOT_DIR = Paths.cache.join('url_cache').to_path

      # Default freshness window: 2 hours. Long enough to cover an interactive
      # session (revisiting a page or re-running a search within the working
      # window hits the cache), short enough that resuming the next day doesn't
      # serve stale results. (opencode caches nothing; +pi-web-fetch+ uses 15 min,
      # +pi-web-search+ 5.)
      #
      # @return [Integer]
      DEFAULT_TTL = 2 * 60 * 60

      # Null cache: always misses, never stores — a drop-in for either store in
      # tests, or anywhere caching should be off.
      #
      #   UrlCache::NULL.fetch('k') { 'x' }   # => "x", yields every time
      #   UrlCache::NULL.read('k')            # => nil
      #
      # @return [Object]
      NULL = Object.new
      # @param _key [String] ignored
      # @return [nil] always a miss
      def NULL.read(_key) = nil

      # @param _key [String] ignored
      # @param value [String] returned, never stored
      # @return [String] +value+
      def NULL.write(_key, value) = value

      # @param _key [String] ignored
      # @yieldreturn [String] freshly-computed payload
      # @return [String] whatever the block returned
      def NULL.fetch(_key) = yield
      NULL.freeze
    end
  end
end
