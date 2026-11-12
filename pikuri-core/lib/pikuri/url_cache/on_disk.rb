# frozen_string_literal: true

require 'digest'
require 'fileutils'

module Pikuri
  module UrlCache
    # The on-disk store: one file per entry, +<dir>/<sha256 of key>.txt+,
    # freshness by mtime, no sidecar metadata. Survives a restart and is shared
    # by every pikuri process. Part of {UrlCache} — see it for the API.
    #
    #   CACHE = UrlCache::OnDisk.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/fetch")
    #
    # A stale entry stays on disk until a {#write} with its key replaces it;
    # +rm -rf+ the directory to clear it. Never use it for a payload whose terms
    # forbid storing it — that is {InMemory}'s job.
    #
    # Sharing: +P_shared_benign+ — an instance holds only its TTL and directory,
    # and every owner keeps it in a class-level constant, so all agents (and
    # other pikuri processes) hit the same files. Two callers racing on one cold
    # key both compute and both write the same bytes — the accepted tradeoff for
    # keeping this a few dozen lines (worst case: a duplicate fetch). The
    # cross-agent flow is deliberate: a public URL's content is nobody's private
    # context.
    class OnDisk
      # @param ttl [Numeric] freshness window in seconds; an entry with an older
      #   mtime is a miss. +Float::INFINITY+ never expires.
      # @param dir [String] where the files live; created lazily on first write
      def initialize(ttl:, dir:)
        @ttl = ttl
        @dir = dir
      end

      # @param key [String] a URL or any opaque string
      # @return [String, nil] the stored payload, or +nil+ when absent or stale
      def read(key)
        path = path_for(key)
        File.read(path) if fresh?(path)
      end

      # @param key [String] a URL or any opaque string
      # @param value [String] payload to store, replacing any entry
      # @return [String] +value+
      def write(key, value)
        FileUtils.mkdir_p(@dir)
        File.write(path_for(key), value)
        value
      end

      # Return the stored payload for +key+ if fresh, else yield to compute it,
      # store and return it. A raising block stores nothing (errors aren't cached).
      #
      # @param key [String] a URL or any opaque string
      # @yieldreturn [String] payload to store and return on a miss
      # @return [String] cached or freshly-computed payload
      def fetch(key)
        cached = read(key)
        return cached unless cached.nil?

        write(key, yield)
      end

      # @param key [String]
      # @return [String] absolute path of the cache file for +key+
      def path_for(key)
        File.join(@dir, "#{Digest::SHA256.hexdigest(key)}.txt")
      end

      private

      # @param path [String]
      # @return [Boolean] true when +path+ exists and was written within the TTL
      def fresh?(path)
        File.exist?(path) && Time.now - File.mtime(path) < @ttl
      end
    end
  end
end
