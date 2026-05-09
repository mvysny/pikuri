# frozen_string_literal: true

require 'digest'
require 'fileutils'

# On-disk cache for URL-keyed text payloads. Used by the bundled tools to
# avoid re-fetching the same page or re-issuing the same web-search query
# within a TTL window: {Tool::WebpageVisitor.visit} caches the rendered
# Markdown for a URL, and the {Tool::Search} provider modules cache the
# rendered result list for a query (the query string itself acts as the
# "URL" — keys are SHA-256 hashed, so any opaque string works).
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
  # Default cache directory under +/tmp+. Writeable on Linux/macOS and
  # cleared on reboot, which is fine for a downloads cache.
  # @return [String]
  DEFAULT_DIR = '/tmp/pikuri/cache/url'

  # Default freshness window: 24 hours, in seconds.
  # @return [Integer]
  DEFAULT_TTL = 24 * 60 * 60

  # @param ttl [Integer] freshness window in seconds; entries with an
  #   mtime older than this are treated as misses
  # @param dir [String] directory under which cache files live; created
  #   lazily on first write
  def initialize(ttl:, dir: DEFAULT_DIR)
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

  # Single shared instance used by the bundled tools. Tests or alternative
  # wirings can build a fresh {UrlCache} with their own +ttl+/+dir+.
  # @return [UrlCache]
  DEFAULT = new(ttl: DEFAULT_TTL)
end
