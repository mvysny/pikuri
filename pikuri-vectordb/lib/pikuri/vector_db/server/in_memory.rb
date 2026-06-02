# frozen_string_literal: true

require 'monitor'

module Pikuri
  module VectorDb
    module Server
      # The null supervisor — the in-process implementation of the
      # Server protocol ({.ensure_running} / {#client} / {#close})
      # that {Qdrant} and {Chroma} implement over docker. There is
      # no container and no process: this class owns the
      # {Backend::InMemory} stores' *lifetime* the way the docker
      # supervisors own a *container*, and that is exactly what
      # makes uniform host wiring possible — +bin/pikuri-corpus+
      # picks a Server class, calls +ensure_running.client(...)+,
      # and closes it at teardown, identically for all three
      # engines.
      #
      # == Collections
      #
      # +#client(collection:)+ memoizes one {Backend::InMemory} per
      # collection name: the same name returns the same store (so
      # the {Watcher} and the agent share one index), a different
      # name returns an independent one. The registry is guarded by
      # a +Monitor+ — same locking discipline {Backend::InMemory}
      # uses internally — so clients can be minted from any thread.
      #
      # == Close semantics
      #
      # {#close} empties every store (+delete_all+) and clears the
      # registry. Outstanding clients keep working but go *empty* —
      # mirroring the docker servers, where close removes the
      # container under the client's feet: degraded loudly-visible
      # behaviour, never silently-stale data. Idempotent.
      #
      # == No Finalizers registration
      #
      # {#ensure_running!} is a no-op and deliberately does NOT
      # register with {Pikuri::Finalizers}: the stores are plain
      # RAM, and process exit already reclaims them. Registering a
      # no-op teardown would be ceremony.
      class InMemory
        # Construct a server and "ensure it's running" — a no-op
        # for RAM, present so call sites can treat all three Server
        # classes identically
        # (+server_class.ensure_running.client(...)+).
        #
        # @return [InMemory]
        def self.ensure_running(**)
          new.ensure_running!
        end

        # @return [InMemory]
        def initialize
          @collections = {}
          @lock = Monitor.new
        end

        # No-op (nothing to boot); returns self so the
        # +ensure_running.client(...)+ chain works.
        #
        # @return [InMemory]
        def ensure_running!
          self
        end

        # Fetch-or-create the {Backend::InMemory} store for
        # +collection+. Same name → same store; the registry
        # persists until {#close}.
        #
        # @param collection [String] collection name.
        # @return [Backend::InMemory]
        # @raise [ArgumentError] on empty +collection+ (same
        #   contract as the docker servers' backends).
        def client(collection:)
          raise ArgumentError, 'collection must be non-empty' if collection.nil? || collection.to_s.empty?

          @lock.synchronize do
            @collections[collection] ||= Backend::InMemory.new
          end
        end

        # Empty every store and clear the registry. Outstanding
        # clients return no hits afterwards (see the class header).
        # Idempotent; safe to call directly at host teardown.
        #
        # @return [void]
        def close
          @lock.synchronize do
            @collections.each_value(&:delete_all)
            @collections.clear
          end
          nil
        end
      end
    end
  end
end
