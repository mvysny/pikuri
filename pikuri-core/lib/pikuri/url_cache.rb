# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Pikuri
  # On-disk cache for string-keyed text payloads. The bundled tools use it to
  # avoid re-fetching within a TTL: {Tool::WebScrape.visit} caches a URL's
  # rendered Markdown, {Tool::Search::Engines.search} caches a query's result
  # list (keys are SHA-256 hashed, so any opaque string works).
  #
  # Each tool wires its own instance against a dedicated subdir under {ROOT_DIR},
  # so a +web_search+ query and a +web_scrape+ URL can't collide on one file.
  # No global singleton — pass a fresh instance, or {NULL} to disable caching.
  #
  # One file per entry (+<sha256>.txt+), freshness by mtime, no sidecar
  # metadata; a stale entry is overwritten on the next {#fetch} with that key.
  # +rm -rf+ the directory to clear it.
  #
  # If two callers race on the same cold key, both compute and both write the
  # same file — the accepted tradeoff for keeping this a few dozen lines (worst
  # case: a duplicate fetch).
  class UrlCache
    # Root dir for per-tool cache subdirs, per XDG:
    # +$XDG_CACHE_HOME/pikuri/url_cache+ or +~/.cache/pikuri/url_cache+. Each
    # tool picks its own subdir (+"#{ROOT_DIR}/web_scrape"+) so keys can't
    # collide. Created lazily on first write.
    # @return [String]
    ROOT_DIR = Paths.cache.join('url_cache').to_path

    # Default freshness window: 2 hours. Long enough to cover an interactive
    # session (revisiting a page or re-running a search within the working
    # window hits the cache), short enough that resuming the next day doesn't
    # serve stale results. (opencode caches nothing; +pi-web-fetch+ uses 15 min,
    # +pi-web-search+ 5.)
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

    # Return the cached payload for +url+ if fresh, else yield to compute it,
    # persist, and return. The block runs only on a miss; if it raises, no file
    # is written (errors aren't cached).
    #
    # @param url [String] cache key; a URL or any opaque string
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

    # Null cache: always misses, never persists — a drop-in for tests (or
    # anywhere caching should be off) keeping the {UrlCache#fetch} contract.
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
