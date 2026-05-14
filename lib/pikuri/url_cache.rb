# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Pikuri
  # On-disk cache for string-keyed text payloads. Used by the bundled tools
  # to avoid re-fetching the same page or re-issuing the same web-search
  # query within a TTL window: {Tool::WebScrape.visit} caches the rendered
  # Markdown for a URL, and {Tool::Search::Engines.search} caches the
  # rendered result list for a query (the query string itself acts as the
  # key — keys are SHA-256 hashed, so any opaque string works).
  #
  # Each tool wires its own {UrlCache} instance against a dedicated
  # subdirectory under {ROOT_DIR}, so a +web_search+ query string and a
  # +web_scrape+ URL string can never collide on the same cache file. There
  # is no global default singleton — pass a fresh instance to whichever
  # code needs caching, or use {NULL} to disable caching entirely.
  #
  # One file per entry, named +<sha256>.txt+ under {#initialize}'s +dir+.
  # Freshness is tracked via the file's mtime; there is no sidecar metadata.
  # Stale entries are simply overwritten the next time {#fetch} is called
  # with the same key. To clear the cache, +rm -rf+ the directory.
  #
  # Not thread-safe: if two callers race on the same cold key, both compute
  # and both write the same file. That is the intended tradeoff to keep this
  # under a few dozen lines — the worst-case cost is a duplicate fetch.
  class UrlCache
    # Root directory under which per-tool cache subdirectories live.
    # Follows the XDG Base Directory spec: +$XDG_CACHE_HOME/pikuri/url_cache+
    # if the env var is set to a non-empty value, else
    # +~/.cache/pikuri/url_cache+. Each tool picks its own subdir
    # (e.g. +"#{ROOT_DIR}/web_scrape"+) so keys from different tools cannot
    # collide. The directory is created lazily on first cache write; pikuri
    # does not pre-create it.
    # @return [String]
    ROOT_DIR = begin
      xdg = ENV['XDG_CACHE_HOME']
      cache_home = xdg && !xdg.empty? ? xdg : File.join(Dir.home, '.cache')
      File.join(cache_home, 'pikuri', 'url_cache')
    end.freeze

    # Default freshness window: 2 hours, in seconds.
    #
    # Long enough to cover a single interactive session — revisiting
    # a scraped page or re-running a similar search within the same
    # working window hits the cache. Short enough that resuming the
    # next day doesn't serve stale news, docs, or search results.
    # Reference points: opencode keeps no cache, the +pi-web-fetch+
    # community extension uses 15 minutes, +pi-web-search+ uses 5;
    # 2 hours sits comfortably above the "single follow-up" window
    # those numbers are aimed at without holding content across days.
    # @return [Integer]
    DEFAULT_TTL = 2 * 60 * 60

    # @param ttl [Integer] freshness window in seconds; entries with an
    #   mtime older than this are treated as misses
    # @param dir [String] directory under which cache files live; created
    #   lazily on first write
    def initialize(ttl:, dir:)
      @ttl = ttl
      @dir = dir
    end

    # Return the cached payload for +url+ if a fresh entry exists, otherwise
    # yield to compute it, persist the result, and return it.
    #
    # The block is only invoked on a miss. If the block raises, no file is
    # written — errors are not cached.
    #
    # @param url [String] cache key; a URL or any opaque string identifier
    # @yieldreturn [String] payload to store and return on a miss
    # @return [String] cached or freshly-computed payload
    def fetch(url)
      path = path_for(url)
      return File.read(path) if fresh?(path)

      content = yield
      FileUtils.mkdir_p(@dir)
      File.write(path, content)
      content
    end

    # @param path [String]
    # @return [Boolean] true when +path+ exists and was written within the
    #   TTL window
    def fresh?(path)
      File.exist?(path) && Time.now - File.mtime(path) < @ttl
    end

    # @param url [String]
    # @return [String] absolute path of the cache file for +url+
    def path_for(url)
      File.join(@dir, "#{Digest::SHA256.hexdigest(url)}.txt")
    end

    # Null cache: a drop-in replacement that always misses and never
    # persists. Use this in tests (or anywhere else you want caching off)
    # without giving up the {UrlCache#fetch} contract.
    NULL = Object.new
    # Singleton +fetch+ on {NULL} that mirrors {UrlCache#fetch}'s shape:
    # ignores +_key+, always yields, never persists.
    #
    # @param _key [String] cache key; ignored
    # @yieldreturn [String] freshly-computed payload
    # @return [String] whatever the block returned
    def NULL.fetch(_key)
      yield
    end
    NULL.freeze
  end
end
