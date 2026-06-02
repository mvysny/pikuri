# frozen_string_literal: true

module Pikuri
  # Process-global teardown registry: one +at_exit+ for the whole
  # process, with everything that owns a resource needing orderly
  # shutdown (agents, {VectorDb::Server::Chroma}, future background
  # workers) registering here instead of growing its own +at_exit+.
  # It is {Agent#on_close} promoted from per-agent to per-process —
  # the same LIFO + per-handler-rescue + idempotent shape, one level
  # up.
  #
  # == Why one chokepoint
  #
  # Independent +at_exit+ hooks fire in an order decided by file load
  # order, which is invisible and fragile. Routing every teardown
  # through one registry makes the order explicit and controllable:
  # the SIGTERM-the-strays backstop ({Subprocess.cleanup!}) registers
  # at *load* time, so it sits at the bottom of the LIFO stack and runs
  # *last* — after agents and servers (which register at *construction*
  # time) have closed gracefully, while the subprocess machinery they
  # shell out to during close (e.g. {VectorDb::Server::Chroma#close}'s
  # +docker stop+) is still live.
  #
  # == Contract
  #
  # A registrant MUST respond to +#close+, and +#close+ MUST be
  # idempotent and tolerant of running at process exit — the host may
  # also have closed it explicitly earlier. Pass a block instead for
  # teardown that has no natural +#close+ (e.g.
  # +Finalizers.register { Pikuri::Subprocess.cleanup! }+).
  #
  # == Order: LIFO
  #
  # Last registered, first closed — Ruby +ensure+ semantics. A
  # registrant that depends on an earlier one (a background indexer
  # writing into {VectorDb::Server::Chroma}) is registered later and so
  # tears down first. Registration order is therefore dependency order;
  # register the dependency before its dependents.
  #
  # == Errors are contained
  #
  # Each +#close+ runs inside its own +rescue+: a raise is logged via
  # {Pikuri.logger_for} and the sweep continues, so one botched
  # teardown can't strand the rest. {.run!} drains the registry, so a
  # second call (an explicit one, then the +at_exit+) closes nothing.
  module Finalizers
    # @return [Logger] subsystem logger for contained teardown failures.
    LOGGER = Pikuri.logger_for('Finalizers')

    # Adapts a teardown block to the +#close+ protocol, so a block and a
    # closeable object can share one registry.
    Closer = Struct.new(:block) do
      # @return [void]
      def close
        block.call
      end
    end

    @registered = []
    @mutex      = Mutex.new

    class << self
      # Register a closeable (or a block) to be torn down at process
      # exit. Returns the registered handle so the caller can later
      # {.unregister} it — a resource closed explicitly before exit
      # should drop out so it can be garbage-collected rather than
      # pinned alive until the process dies.
      #
      # @param closeable [#close, nil] resource to close at exit; omit
      #   when passing a block
      # @yield teardown to run at exit, for resources with no +#close+
      # @return [#close] the registered handle — the object itself, or
      #   the {Closer} wrapping the block; pass it to {.unregister}
      # @raise [ArgumentError] if neither an object nor a block is given
      def register(closeable = nil, &block)
        unless closeable || block
          raise ArgumentError, 'Finalizers.register requires an object or a block'
        end

        handle = closeable || Closer.new(block)
        @mutex.synchronize { @registered << handle }
        handle
      end

      # Drop a previously-registered handle. Idempotent — unregistering
      # something already gone (or never registered) is a no-op.
      #
      # @param handle [#close] the value returned by {.register}
      # @return [void]
      def unregister(handle)
        @mutex.synchronize { @registered.delete(handle) }
        nil
      end

      # Close every registrant in LIFO order, each guarded by its own
      # +rescue+. Wired to +at_exit+ at the bottom of this file.
      # Draining the registry under the lock makes a repeat call a
      # no-op and keeps it safe against a concurrent caller.
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
