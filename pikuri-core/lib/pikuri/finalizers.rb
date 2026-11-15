# frozen_string_literal: true

module Pikuri
  # Process-global teardown registry: one +at_exit+ for the whole process,
  # with everything owning a resource that needs orderly shutdown (agents,
  # {VectorDb::Server::Qdrant}, background workers) registering here instead of
  # growing its own +at_exit+. {Agent#on_close} promoted per-agent → per-process
  # — the same LIFO + per-handler-rescue + idempotent shape.
  #
  # == Why one chokepoint
  #
  # Independent +at_exit+ hooks fire in file-load order — invisible and fragile.
  # One registry makes the order explicit: the SIGTERM-the-strays backstop
  # ({Subprocess.cleanup!}) registers at *load* time, so it sits at the bottom
  # of the LIFO stack and runs *last* — after agents and servers (registered at
  # *construction* time) close gracefully, while the subprocess machinery they
  # shell out to during close (a +docker stop+) is still live.
  #
  # == Contract
  #
  # A registrant MUST respond to +#close+, idempotent and tolerant of running at
  # exit (the host may have closed it earlier). Pass a block instead for
  # teardown with no natural +#close+
  # (+Finalizers.register { Pikuri::Subprocess.cleanup! }+).
  #
  # == Order: LIFO
  #
  # Last registered, first closed. A registrant depending on an earlier one (a
  # background indexer writing into {VectorDb::Server::Qdrant}) registers later
  # and tears down first — registration order is dependency order.
  #
  # == Errors are contained
  #
  # Each +#close+ runs in its own +rescue+ (a raise is logged, the sweep
  # continues). {.run!} drains the registry, so a second call closes nothing.
  module Finalizers
    # @return [Logger] subsystem logger for contained teardown failures.
    LOGGER = Pikuri.logger_for('Finalizers')

    # Adapts a teardown block to the +#close+ protocol, so a block and a
    # closeable share one registry.
    Closer = Struct.new(:block) do
      # @return [void]
      def close
        block.call
      end
    end

    @registered = []
    @mutex      = Mutex.new

    class << self
      # Register a closeable (or a block) to tear down at exit. Returns the
      # handle so the caller can later {.unregister} it — a resource closed
      # explicitly before exit should drop out to be GC'd, not pinned alive.
      #
      # @param closeable [#close, nil] resource to close; omit when passing a block
      # @yield teardown for resources with no +#close+
      # @return [#close] the registered handle (the object, or the {Closer}
      #   wrapping the block); pass to {.unregister}
      # @raise [ArgumentError] if neither an object nor a block is given
      def register(closeable = nil, &block)
        unless closeable || block
          raise ArgumentError, 'Finalizers.register requires an object or a block'
        end

        handle = closeable || Closer.new(block)
        @mutex.synchronize { @registered << handle }
        handle
      end

      # Drop a previously-registered handle. Idempotent.
      #
      # @param handle [#close] the value returned by {.register}
      # @return [void]
      def unregister(handle)
        @mutex.synchronize { @registered.delete(handle) }
        nil
      end

      # Close every registrant in LIFO order, each guarded by its own +rescue+.
      # Wired to +at_exit+ below. Draining under the lock makes a repeat call a
      # no-op and stays safe against a concurrent caller.
      #
      # @return [void]
      def run!
        handles = @mutex.synchronize do
          taken = @registered.reverse
          @registered.clear
          taken
        end

        handles.each do |handle|
          handle.close
        rescue StandardError => e
          LOGGER.warn("finalizer #{handle.class} raised #{e.class}: #{e.message}")
        end
      end
    end
  end
end

at_exit { Pikuri::Finalizers.run! }
