# frozen_string_literal: true

module Pikuri
  module Web
    module UrlCache
      # The in-memory store: a bounded, least-recently-used +Hash+ that lives as
      # long as the Ruby VM and never touches disk. Part of {UrlCache} — see it
      # for the API.
      #
      #   MEMORY_CACHE = UrlCache::InMemory.new(ttl: UrlCache::DEFAULT_TTL, max_entries: 100)
      #
      # For payloads whose terms forbid storing them: Brave's API terms allow
      # only "transient storage required for operation", Exa's no copy beyond a
      # browser's display cache. A process-lifetime copy is the transient one;
      # exit frees it. So nothing tears it down earlier — not an agent's close,
      # a context clear or a history load.
      #
      # Past +max_entries+, a {#write} evicts the least recently used entry; a hit
      # counts as a use. The TTL is a freshness rule only: an expired entry is a
      # miss, dropped when met.
      #
      # Values are stored frozen, so a caller can't mutate a shared entry in
      # place; {#write} and {#fetch} return the frozen copy, hit or miss alike.
      #
      # Sharing: +P_shared_locked+ — every owner keeps one in a class-level
      # constant shared by all agents in the process; a +Mutex+ guards the hash,
      # reads included (a hit reorders it). {#fetch}'s block runs outside the
      # lock, so two callers racing on one cold key both compute and the later
      # write wins — the same benign race as {OnDisk}.
      class InMemory
        # @param ttl [Numeric] freshness window in seconds; +Float::INFINITY+
        #   never expires, leaving eviction to +max_entries+ alone.
        # @param max_entries [Integer] how many entries to keep
        # @raise [ArgumentError] unless +max_entries+ is a positive Integer
        def initialize(ttl:, max_entries:)
          unless max_entries.is_a?(Integer) && max_entries.positive?
            raise ArgumentError, "max_entries must be a positive Integer, got #{max_entries.inspect}"
          end

          @ttl = ttl
          @max_entries = max_entries
          @entries = {} # key => [value, stored_at]; insertion order is recency order
          @mutex = Mutex.new
        end

        # @param key [String] a URL or any opaque string
        # @return [String, nil] the stored (frozen) payload, or +nil+ when absent
        #   or stale
        def read(key)
          @mutex.synchronize do
            entry = @entries.delete(key)
            next nil if entry.nil? || now - entry.last >= @ttl

            @entries[key] = entry
            entry.first
          end
        end

        # @param key [String] a URL or any opaque string
        # @param value [String] payload to store, replacing any entry
        # @return [String] the stored, frozen copy of +value+
        def write(key, value)
          stored = value.frozen? ? value : value.dup.freeze
          @mutex.synchronize do
            @entries.delete(key)
            @entries[key] = [stored, now]
            @entries.shift while @entries.size > @max_entries
          end
          stored
        end

        # Return the stored payload for +key+ if fresh, else yield to compute it,
        # store and return it. A raising block stores nothing (errors aren't cached).
        #
        # @param key [String] a URL or any opaque string
        # @yieldreturn [String] payload to store and return on a miss
        # @return [String] cached or freshly-computed payload, frozen
        def fetch(key)
          cached = read(key)
          return cached unless cached.nil?

          write(key, yield)
        end

        private

        # Monotonic, so a wall-clock jump neither expires nor revives entries.
        #
        # @return [Float] seconds
        def now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
