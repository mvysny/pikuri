# frozen_string_literal: true

require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    module Server
      # Supervisor for a self-managed Qdrant docker container. Pairs
      # with {Backend::Qdrant} exactly as {Server::Chroma} pairs with
      # {Backend::Chroma}: this class owns the *process*; the backend
      # owns the HTTP client. {#client} returns a {Backend::Qdrant}
      # pre-pointed at the running container.
      #
      # Like {Server::Chroma}, this class carries only the engine's
      # *identity* — image pin, container name, persist path,
      # heartbeat path — and composes a {DockerContainer} for the
      # docker work and the shared rationale (namespace squat,
      # ephemeral-container-persistent-data, subprocess seam,
      # 127.0.0.1 binding, loud boot / quiet teardown).
      #
      # == The port 6333 caveat
      #
      # Published on +127.0.0.1:#{port}+ only, same privacy posture
      # as {Server::Chroma}. Note that +pikuri-memory+'s +Mem0Server+
      # compose stack *also* publishes its own internal Qdrant on
      # host port 6333 (for inspection). The two are separate
      # instances by design (see +DESIGN.md+ §"Verdict"); running
      # both on one host at the defaults collides on the port —
      # pass a different +port:+ to this supervisor when the mem0
      # stack is up.
      class Qdrant
        # @return [String] pinned qdrant docker image. Bumping this
        #   constant is how the codebase upgrades the qdrant version
        #   ({#ensure_running!} recreates the container from scratch
        #   on the next boot; the bind-mounted data dir is
        #   untouched). **Kept in lockstep with
        #   +Pikuri::Memory::Mem0Server::DEFAULT_QDRANT_IMAGE+** —
        #   same tag, so a host running both stacks holds one image
        #   on disk. The gems don't depend on each other, so the pin
        #   is a convention, not a shared constant; bump both
        #   together. See +pikuri-vectordb/DESIGN.md+ §"Verdict".
        IMAGE = 'qdrant/qdrant:v1.12.4'

        # @return [String] the container name pikuri claims for its
        #   qdrant supervisor — the +"pikuri-internal-"+ namespace
        #   squat (see {DockerContainer}).
        CONTAINER_NAME = 'pikuri-internal-qdrant'

        # @return [String] docker label set on every container this
        #   class creates. Same label as {Server::Chroma::LABEL}.
        LABEL = 'pikuri.internal=true'

        # @return [String] path inside the container where qdrant
        #   persists its data — the +-v+ target the host's
        #   {#default_data_dir} bind-mounts onto. +/qdrant/storage+
        #   is the image's documented storage root (the same path
        #   +pikuri-memory+'s compose file mounts).
        CONTAINER_PERSIST_DIR = '/qdrant/storage'

        # @return [Integer] default host port, qdrant's native REST
        #   port. See the class header for the collision caveat
        #   with the mem0 stack's inspection port.
        DEFAULT_PORT = 6333

        # @return [Integer] default seconds to wait for the
        #   container's HTTP heartbeat to start returning 200 after
        #   +docker run+.
        DEFAULT_HEALTHCHECK_TIMEOUT = 30

        # Construct a server and immediately ensure it's running.
        # Convenience factory — equivalent to +new(...).tap(&:ensure_running!)+.
        #
        # @param data_dir [String, Pathname, nil] host path
        #   bind-mounted into the container's persist directory.
        #   +nil+ resolves to {#default_data_dir}. Created if missing.
        # @param port [Integer] host port bound to qdrant's 6333.
        #   Bound to 127.0.0.1 only.
        # @param healthcheck_timeout [Integer] seconds to poll
        #   +/healthz+ before giving up.
        # @return [Server::Qdrant]
        def self.ensure_running(data_dir: nil, port: DEFAULT_PORT,
                                healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT)
          new(
            data_dir: data_dir, port: port,
            healthcheck_timeout: healthcheck_timeout
          ).tap(&:ensure_running!)
        end

        # @param data_dir [String, Pathname, nil] host path to
        #   bind-mount as qdrant's storage dir. +nil+ resolves to
        #   {#default_data_dir}.
        # @param port [Integer] host port to publish.
        # @param healthcheck_timeout [Integer]
        # @param connection [Faraday::Connection, nil] DI hook for
        #   tests. Production callers leave it +nil+.
        # @return [Server::Qdrant]
        def initialize(data_dir: nil, port: DEFAULT_PORT,
                       healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT,
                       connection: nil)
          @data_dir = Pathname.new(data_dir || default_data_dir).expand_path
          @port = port
          @container = DockerContainer.new(
            name: CONTAINER_NAME, image: IMAGE, label: LABEL,
            host_port: port, container_port: 6333,
            volume: "#{@data_dir}:#{CONTAINER_PERSIST_DIR}",
            health_path: '/healthz',
            healthcheck_timeout: healthcheck_timeout,
            connection: connection
          )
          @finalizer_handle = nil
        end

        # @return [Pathname] host-side data directory.
        attr_reader :data_dir

        # @return [Integer] host-side port.
        attr_reader :port

        # @return [String] +"http://localhost:<port>"+. Useful for
        #   wiring custom +Backend::Qdrant+ constructions.
        def endpoint
          @container.endpoint
        end

        # Build a {Backend::Qdrant} pointing at the supervised
        # container. Constructor convenience — the supervisor
        # carries the host/port, the caller carries the collection
        # name.
        #
        # @param collection [String] Qdrant collection name.
        # @return [Backend::Qdrant]
        def client(collection:)
          Backend::Qdrant.new(host: 'localhost', port: @port, collection: collection)
        end

        # Idempotent: ensure a fresh container is running and healthy
        # (see {DockerContainer#ensure_running!} for the
        # reuse-or-recreate algorithm), then register {#close} with
        # {Pikuri::Finalizers} — once — so the container is removed
        # at process exit.
        #
        # @return [void]
        # @raise [RuntimeError] on missing docker, any docker
        #   command failure, or healthcheck timeout.
        def ensure_running!
          FileUtils.mkdir_p(@data_dir)
          @container.ensure_running!
          @finalizer_handle ||= Pikuri::Finalizers.register(self)
          nil
        end

        # Remove the supervised container (+docker rm -f+), leaving
        # the bind-mounted {#data_dir} — the corpus survives.
        # Registered with {Pikuri::Finalizers} by {#ensure_running!};
        # safe to call directly too. Best-effort and idempotent — see
        # {DockerContainer#close}.
        #
        # @return [void]
        def close
          @container.close
        end

        # Default host-side data directory:
        # +$XDG_CACHE_HOME/pikuri/qdrant+ if set, else
        # +~/.cache/pikuri/qdrant+. Public so tests and chapter
        # examples can reference the same path the supervisor
        # resolves at runtime.
        #
        # @return [String]
        def default_data_dir
          Pikuri::Paths.cache.join('qdrant').to_s
        end
      end
    end
  end
end
