# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    # Supervisor for a self-managed Qdrant docker container. Pairs
    # with {Backend::Qdrant} exactly as {ChromaServer} pairs with
    # {Backend::Chroma}: this class owns the *process* (create /
    # recreate / remove the container, bind-mount the data dir,
    # heartbeat-poll until ready); the backend owns the HTTP
    # client. {#client} returns a {Backend::Qdrant} pre-pointed at
    # the running container.
    #
    # == A deliberate clone, not a shared base class
    #
    # This is {ChromaServer} with the engine-specific constants
    # swapped — image, container name, persist path, heartbeat
    # path, default port. The duplication is intentional: a
    # +ContainerServer+ base class would save ~150 lines at the
    # cost of an abstraction layer a reader must page through to
    # answer "what does this actually run?", and the two
    # supervisors drift independently with their engines (a third
    # sibling, +pikuri-memory+'s +Mem0Server+, is already
    # compose-shaped rather than single-container). All the
    # shared rationale — the +pikuri-internal-*+ namespace squat,
    # ephemeral-container-persistent-data, the subprocess seam,
    # loud boot errors vs quiet teardown — lives in
    # {ChromaServer}'s class header and is not repeated here.
    #
    # == Bind 127.0.0.1 — and the port 6333 caveat
    #
    # Published on +127.0.0.1:#{port}+ only, same privacy posture
    # as {ChromaServer}. Note that +pikuri-memory+'s +Mem0Server+
    # compose stack *also* publishes its own internal Qdrant on
    # host port 6333 (for inspection). The two are separate
    # instances by design (see +DESIGN.md+ §"Verdict"); running
    # both on one host at the defaults collides on the port —
    # pass a different +port:+ to this supervisor when the mem0
    # stack is up.
    class QdrantServer
      LOGGER = Pikuri.logger_for('VectorDb::QdrantServer')

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
      #   squat (see {ChromaServer}'s class header).
      CONTAINER_NAME = 'pikuri-internal-qdrant'

      # @return [String] docker label set on every container this
      #   class creates. Same label as {ChromaServer::LABEL}.
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
      # @return [QdrantServer]
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
      # @return [QdrantServer]
      def initialize(data_dir: nil, port: DEFAULT_PORT,
                     healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT,
                     connection: nil)
        @data_dir = Pathname.new(data_dir || default_data_dir).expand_path
        @port = port
        @healthcheck_timeout = healthcheck_timeout
        @connection = connection
        @owns_container = false
        @closed = false
        @finalizer_handle = nil
      end

      # @return [Pathname] host-side data directory.
      attr_reader :data_dir

      # @return [Integer] host-side port.
      attr_reader :port

      # @return [String] +"http://localhost:<port>"+. Useful for
      #   wiring custom +Backend::Qdrant+ constructions.
      def endpoint
        "http://localhost:#{@port}"
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

      # Idempotent: ensure a fresh container is running, heartbeat-poll
      # until ready, then register {#close} with {Pikuri::Finalizers} so
      # the container is removed at process exit. Same algorithm as
      # {ChromaServer#ensure_running!}: a container this process already
      # started and left running is reused; anything else — stopped,
      # not ours, or absent — is removed (if present) and recreated on
      # the pinned {IMAGE}.
      #
      # @return [void]
      # @raise [RuntimeError] on missing docker, any docker
      #   command failure, or healthcheck timeout.
      def ensure_running!
        FileUtils.mkdir_p(@data_dir)

        state = container_state
        if @owns_container && state == :running
          LOGGER.info("#{CONTAINER_NAME} already running")
        else
          remove_container! unless state == :missing
          run_container!
        end

        @owns_container = true
        wait_for_healthy!
        register_for_cleanup
      end

      # Remove the supervised container (+docker rm -f+), leaving the
      # bind-mounted {#data_dir} — the corpus survives. Registered with
      # {Pikuri::Finalizers} by {#ensure_running!}; safe to call
      # directly too. Best-effort and idempotent: a no-op if this
      # server never started a container, and a non-zero +rm+ is
      # logged rather than raised — that's teardown, boot is loud.
      #
      # @return [void]
      def close
        return if @closed || !@owns_container

        @closed = true
        result = docker('rm', '-f', CONTAINER_NAME)
        return if result.status.success?

        LOGGER.warn(
          "docker rm -f #{CONTAINER_NAME} failed " \
          "(exit #{result.status.exitstatus}): #{result.output.strip}"
        )
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

      private

      # Register this server's {#close} with the process-global
      # teardown registry, once.
      def register_for_cleanup
        @finalizer_handle ||= Pikuri::Finalizers.register(self)
      end

      # Inspect the container by name. Returns one of +:missing+ /
      # +:stopped+ / +:running+.
      def container_state
        result = docker('inspect', '--format', '{{.State.Running}}', CONTAINER_NAME)
        return :missing unless result.status.success?

        result.output.strip == 'true' ? :running : :stopped
      end

      def run_container!
        LOGGER.info(
          "starting #{CONTAINER_NAME} (#{IMAGE}) on 127.0.0.1:#{@port}, " \
          "data: #{@data_dir}"
        )
        result = docker(
          'run', '-d',
          '--name', CONTAINER_NAME,
          '--label', LABEL,
          '-p', "127.0.0.1:#{@port}:6333",
          '-v', "#{@data_dir}:#{CONTAINER_PERSIST_DIR}",
          IMAGE
        )
        return if result.status.success?

        raise "QdrantServer: docker run failed " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}"
      end

      def remove_container!
        result = docker('rm', '-f', CONTAINER_NAME)
        return if result.status.success?

        raise "QdrantServer: docker rm -f #{CONTAINER_NAME} failed " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}"
      end

      # Poll +GET /healthz+ until 200 or +@healthcheck_timeout+
      # elapses. 500ms between attempts. Faraday connection errors
      # during the wait are normal (cold-start bind delay); only
      # the final timeout raises.
      def wait_for_healthy!
        deadline = Time.now + @healthcheck_timeout
        last_error = 'no attempts'

        until Time.now > deadline
          begin
            response = http.get('/healthz')
            return if response.status == 200

            last_error = "HTTP #{response.status}"
          rescue Faraday::Error => e
            last_error = "#{e.class.name.split('::').last}: #{e.message}"
          end
          sleep 0.5
        end

        raise "QdrantServer: #{CONTAINER_NAME} did not become healthy within " \
              "#{@healthcheck_timeout}s at #{endpoint} (last: #{last_error})"
      end

      def http
        @connection ||= Faraday.new(url: endpoint) do |f|
          f.request :json
          f.response :json
          f.adapter Faraday.default_adapter
        end
      end

      # Single chokepoint for every +docker+ invocation — routes
      # through {Pikuri::Subprocess.spawn} per the subprocess seam.
      def docker(*argv)
        Pikuri::Subprocess.spawn('docker', *argv, chdir: '/').wait
      rescue Errno::ENOENT
        raise 'QdrantServer: `docker` not found on PATH. ' \
              'Install docker, or point Backend::Qdrant at an existing ' \
              'qdrant endpoint via Backend::Qdrant.new(host:, port:, collection:).'
      end
    end
  end
end
