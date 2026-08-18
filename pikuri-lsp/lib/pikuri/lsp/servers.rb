# frozen_string_literal: true

module Pikuri
  module Lsp
    # Every language server this agent may use: one {ClientWrapper} per
    # {Registry} entry, started on demand, plus the routing that picks which one
    # answers for a file.
    #
    #   servers = Servers.new(registry: registry, root: filesystem.project_root)
    #   servers.client_for('lib/pikuri/agent.rb').entry.id  # => "ruby" — spawns it
    #   servers.client_for('README.md')                     # => nil   — spawns nothing
    #   servers.close
    #
    # {#initialize} is pure and every start is lazy, so arm teardown right after
    # construction: a server that started before a later one failed is registered
    # here precisely so an already-armed +close+ still sweeps it.
    #
    # == Implementation details
    #
    # **Don't move the spawn back to boot.** Which servers you have installed is
    # machine state, so one config file serves every project ({Registry.from_h}) —
    # eager spawning makes a stray +java+ entry cost a JVM and a multi-minute cold
    # import in every Ruby-only repo. The price is that a misconfigured +command+
    # surfaces at first use instead of at boot, as an +"Error: …"+ observation the
    # model relays; that is the same path a server that dies *after* spawning
    # already took.
    class Servers
      LOGGER = Pikuri.logger_for('Lsp::Servers')
      private_constant :LOGGER

      # @return [Registry] the configuration these clients run.
      attr_reader :registry

      # @param registry [Registry] which servers exist. {Registry::EMPTY} makes
      #   every method here a no-op answer, so a host with no config wires no
      #   tool and nothing else has to care.
      # @param root [String, Pathname] the workspace root: every child's cwd, the
      #   +rootUri+ it indexes, and the tree {#active_entries} scans.
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
        @active = nil
      end

      # The fan-out set — every project-relevant server, started on demand.
      #
      # It is the *relevant* set rather than the registered one because a fan-out
      # cannot choose between servers without starting them: {Navigator} gates on
      # what each advertised in this workspace, and only a live handshake carries
      # that.
      #
      # @return [Array<ClientWrapper>] in declaration order; empty when nothing is
      #   configured or nothing in the project matches.
      # @raise [ClientWrapper::ServerDied] from the first server that cannot be
      #   started.
      def active
        active_entries.map { |entry| client(entry) }
      end

      # The registered entries this project has files for, in declaration order —
      # the relevance question answered without spawning anything.
      #
      # Scanned once, then memoized. Relevance *mirrors* dispatch rather than
      # merely resembling it: the first entry claiming a basename wins, exactly as
      # {Registry#entry_for} decides, so an entry shadowed by an earlier one is
      # never activated by files it would not be asked about.
      #
      # @return [Array<Registry::StdioEntry>]
      def active_entries
        @active ||= relevant_entries
      end

      # The server that answers for +path+, started on demand.
      #
      # No relevance scan is involved — a path that exists *is* the evidence,
      # which is why the file-anchored call never walks the project.
      #
      # @param path [String, Pathname] matched on its basename by
      #   {Registry::StdioEntry#claims?}.
      # @return [ClientWrapper, nil] +nil+ when no entry claims the file.
      # @raise [ClientWrapper::ServerDied] when the claiming server cannot start.
      def client_for(path)
        entry = @registry.entry_for(path)
        entry && client(entry)
      end

      # @return [Array<String>] ids of the servers actually running, in start
      #   order — nothing at all until a call needs one.
      def started_ids
        @clients.keys
      end

      # @return [Boolean] whether there is nothing to ask. A *registry* question,
      #   not a liveness one: under lazy start nothing runs before the first call,
      #   so liveness would answer "no servers" to every call.
      def empty?
        @registry.empty?
      end

      # Shut every started server down. Idempotent, and never raises — it runs
      # from an +on_close+ at exit, where one bad teardown must not take the rest
      # of the sweep with it ({ClientWrapper#close} already swallows its own).
      #
      # @return [void]
      def close
        @clients.each_value(&:close)
        @clients.clear
        LOGGER.debug('closed')
        nil
      end

      private

      # @return [ClientWrapper]
      def client(entry)
        # A raising spawn stays unmemoized on purpose: installing the missing
        # binary mid-session then recovers, and re-learning an ENOENT is free.
        @clients[entry.id] ||= begin
          LOGGER.info("#{entry.id}: starting on first use")
          @spawn.call(entry)
        end
      end

      # One pruned walk, stopping as soon as every entry is accounted for — so a
      # project whose languages are all configured exits after a handful of files.
      #
      # Undescended: dot-directories (+.git+ and a vendored bundle hold thousands
      # of files that say nothing about what *this* project is written in) and
      # symlinked directories (the cheapest cycle-free rule). Relevance is
      # therefore a heuristic, and only ever narrows the *fan-out* — a
      # file-anchored call starts its server regardless.
      #
      # @return [Array<Registry::StdioEntry>]
      def relevant_entries
        return [] if @registry.empty?

        pending = @registry.entries.dup
        found = []
        scan(@root.to_s, pending, found)
        @registry.entries.select { |entry| found.include?(entry) }
      end

      # @return [void]
      def scan(dir, pending, found)
        Dir.children(dir).each do |name|
          return if pending.empty?

          path = File.join(dir, name)
          if !File.symlink?(path) && File.directory?(path)
            scan(path, pending, found) unless name.start_with?('.')
          else
            claimant = pending.find { |entry| entry.claims?(name) }
            next if claimant.nil?

            found << claimant
            pending.delete(claimant)
          end
        end
      rescue SystemCallError => e
        # A heuristic must not fail the call it serves, and an unreadable
        # directory says nothing about relevance either way.
        LOGGER.debug("relevance scan skipped #{dir}: #{e.message}")
        nil
      end
    end
  end
end
