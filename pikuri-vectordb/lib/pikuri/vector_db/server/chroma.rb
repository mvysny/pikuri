# frozen_string_literal: true

require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    module Server
      # Supervisor for a self-managed Chroma docker container. Owns the
      # *process*; {Backend::Chroma} owns the HTTP client, and {#client} returns
      # one pre-pointed at the running container. Hosts that manage Chroma
      # elsewhere wire {Backend::Chroma.new(host:, port:)} directly and never
      # touch this class.
      #
      # This class carries Chroma's *identity* (image pin, name, persist +
      # heartbeat paths) and hands it to a composed {DockerContainer}, which does
      # the docker work and documents the shared rationale. What stays here:
      # {#default_data_dir}, the {Backend::Chroma} factory, and the
      # {Pikuri::Finalizers} registration (the supervisor is the host-facing
      # ownership boundary, so it registers, not the helper).
      class Chroma
        # @return [String] pinned chroma docker image. Bumping this
        #   constant is how the codebase upgrades the chroma
        #   version: {#ensure_running!} recreates the container from
        #   scratch on the next boot, so it comes up on the new pin
        #   automatically (the bind-mounted corpus is untouched).
        IMAGE = 'chromadb/chroma:1.5.9'

        # @return [String] container name; the +"pikuri-internal-"+ prefix is
        #   the namespace pikuri squats — see {DockerContainer}.
        CONTAINER_NAME = 'pikuri-internal-chroma'

        # @return [String] docker label set on every container this class
        #   creates (for +docker ps --filter+ enumeration).
        LABEL = 'pikuri.internal=true'

        # @return [String] path inside the container where chroma
        #   persists its data. Chroma 1.x (the pinned {IMAGE} line)
        #   stores its SQLite + segment files at +/data+ — this is
        #   the +-v+ target the host's {#default_data_dir}
        #   bind-mounts onto. (Chroma 0.x used +/chroma/chroma+;
        #   mounting that path against a 1.x image silently leaves
        #   the host dir empty while the data accumulates in the
        #   container's writable layer, where teardown would
        #   destroy it.)
        CONTAINER_PERSIST_DIR = '/data'

        # @return [Integer] default seconds to wait for the
        #   container's HTTP heartbeat to start returning 200 after
        #   +docker run+.
        DEFAULT_HEALTHCHECK_TIMEOUT = 30

        # Construct a server and immediately ensure it's running.
        # Convenience factory — equivalent to +new(...).tap(&:ensure_running!)+.
        #
        # @param data_dir [String, Pathname, nil] host path
        #   bind-mounted into the container's persist directory.
        #   +nil+ resolves to {#default_data_dir} ($XDG_CACHE_HOME
        #   or ~/.cache, then +pikuri/chroma+). Created if missing.
        # @param port [Integer] host port bound to chroma's 8000.
        #   Bound to 127.0.0.1 only.
        # @param healthcheck_timeout [Integer] seconds to poll
        #   +/api/v2/heartbeat+ before giving up.
        # @return [Server::Chroma]
        def self.ensure_running(data_dir: nil, port: 8000,
                                healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT)
          new(
            data_dir: data_dir, port: port,
            healthcheck_timeout: healthcheck_timeout
          ).tap(&:ensure_running!)
        end

        # @param data_dir [String, Pathname, nil] host path to
        #   bind-mount as chroma's persist dir. +nil+ resolves to
        #   {#default_data_dir}.
        # @param port [Integer] host port to publish.
        # @param healthcheck_timeout [Integer]
        # @param connection [Faraday::Connection, nil] DI hook for
        #   tests. Production callers leave it +nil+.
        # @return [Server::Chroma]
        def initialize(data_dir: nil, port: 8000,
                       healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT,
                       connection: nil)
          @data_dir = Pathname.new(data_dir || default_data_dir).expand_path
          @port = port
          @container = DockerContainer.new(
            name: CONTAINER_NAME, image: IMAGE, label: LABEL,
            host_port: port, container_port: 8000,
            volume: "#{@data_dir}:#{CONTAINER_PERSIST_DIR}",
            health_path: '/api/v2/heartbeat',
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
        #   wiring custom +Backend::Chroma+ constructions.
        def endpoint
          @container.endpoint
        end

        # Build a {Backend::Chroma} pointing at the supervised
        # container. Just a constructor convenience — the supervisor
        # carries the host/port, the caller carries the collection
        # name.
        #
        # @param collection [String] Chroma collection name.
        # @return [Backend::Chroma]
        def client(collection:)
          Backend::Chroma.new(host: 'localhost', port: @port, collection: collection)
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

        # Remove the supervised container, leaving the bind-mounted {#data_dir}
        # (the corpus survives). Best-effort and idempotent — see
        # {DockerContainer#close}.
        #
        # @return [void]
        def close
          @container.close
        end

        # Default host-side data directory
        # (+$XDG_CACHE_HOME/pikuri/chroma+, else +~/.cache/pikuri/chroma+).
        # Public so tests and chapter examples reference the same path.
        #
        # @return [String]
        def default_data_dir
          Pikuri::Paths.cache.join('chroma').to_s
        end
      end
    end
  end
end
