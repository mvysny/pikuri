# frozen_string_literal: true

module Pikuri
  module Lsp
    # Every language server this agent has, live: one {ClientWrapper} per
    # {Registry} entry, and the routing that picks which one answers for a file.
    #
    #   servers = Servers.new(registry: registry, root: filesystem.project_root)
    #   servers.start_all                                   # raises if a binary is missing
    #   servers.client_for('lib/pikuri/agent.rb').entry.id  # => "ruby"
    #   servers.client_for('README.md')                     # => nil
    #   servers.close
    #
    # == Two-phase, and why the order matters
    #
    # {#initialize} is pure and {#start_all} spawns, so an owner can arm its
    # teardown *between* the two. Get that order wrong and a missing second binary
    # orphans the first server: a half-way start leaves the children it did start
    # registered here precisely so an already-armed +close+ still sweeps them.
    #
    # == Spawn at boot, block on the first call
    #
    # Every registered server starts when the agent is wired rather than when a
    # call first needs it, which turns a typo'd +command+ into a boot-time error
    # with the child's own last words attached ({ClientWrapper#stderr_tail})
    # instead of a puzzling tool failure ten turns in. Indexing then runs in the
    # background while the user types. The cost is accepted rather than
    # unnoticed: a Ruby-only question in a Ruby+Java project still spawned jdtls.
    class Servers
      LOGGER = Pikuri.logger_for('Lsp::Servers')
      private_constant :LOGGER

      # @return [Registry] the configuration these clients run.
      attr_reader :registry

      # @param registry [Registry] which servers exist. {Registry::EMPTY} makes
      #   every method here a no-op answer, so a host with no config wires no
      #   tool and nothing else has to care.
      # @param root [String, Pathname] the workspace root: every child's cwd and
      #   the +rootUri+ it indexes.
      # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] threaded
      #   into each handshake.
      # @param spawn [Proc, nil] +entry+ → a started {ClientWrapper}. The seam a
      #   spec replaces to drive fake servers over pipes; production passes
      #   nothing.
      def initialize(registry:, root:, cancellable: nil, spawn: nil)
        @registry = registry
        @root = root
        @cancellable = cancellable
        @spawn = spawn || lambda { |entry|
          ClientWrapper.spawn(entry, root: @root, cancellable: @cancellable)
        }
        @clients = {}
      end

      # Spawn and hand-shake every registered server, in declaration order.
      #
      # @return [self]
      # @raise [ClientWrapper::ServerDied] on the first server that cannot be
      #   started. Servers already up stay registered for {#close}.
      def start_all
        @registry.entries.each do |entry|
          next if @clients.key?(entry.id)

          @clients[entry.id] = @spawn.call(entry)
        end
        self
      end

      # @return [Array<ClientWrapper>] every live client, in declaration order —
      #   the fan-out set for an operation that names no file.
      def all
        @clients.values
      end

      # The server that answers for +path+.
      #
      # @param path [String, Pathname] matched on its basename by
      #   {Registry::StdioEntry#claims?}.
      # @return [ClientWrapper, nil] +nil+ when no entry claims the file, or when
      #   the one that does was never started.
      def client_for(path)
        entry = @registry.entry_for(path)
        entry && @clients[entry.id]
      end

      # @return [Boolean] whether there is nothing to ask.
      def empty?
        @clients.empty?
      end

      # Shut every server down. Idempotent, and never raises — it runs from an
      # +on_close+ at exit, where one bad teardown must not take the rest of the
      # sweep with it ({ClientWrapper#close} already swallows its own).
      #
      # @return [void]
      def close
        @clients.each_value(&:close)
        @clients.clear
        LOGGER.debug('closed')
        nil
      end
    end
  end
end
