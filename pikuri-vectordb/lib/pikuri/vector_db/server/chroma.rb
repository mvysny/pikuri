# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    module Server
      # Supervisor for a self-managed Chroma docker container. Pairs
      # with {Backend::Chroma}: this class owns the *process* (create /
      # recreate / remove the container, mount the volume,
      # heartbeat-poll until ready); {Backend::Chroma} owns the HTTP
      # client that talks to it. {#client} returns a {Backend::Chroma}
      # pre-pointed at the running container.
      #
      # == Why split server from client
      #
      # Container lifecycle and HTTP wire protocol have nothing in
      # common — they're separate jobs reading separate man pages.
      # Splitting them keeps {Backend::Chroma} a thin Faraday client
      # (the audit-friendly shape) and concentrates the docker-shaped
      # complexity in one place a reader can skip when they don't
      # care.
      #
      # Hosts that already manage Chroma elsewhere (a production
      # deployment, a docker-compose stack, a Kubernetes service)
      # wire {Backend::Chroma.new(host:, port:)} directly and never
      # touch this class.
      #
      # == Namespace squat: pikuri-internal-*
      #
      # The container is named {CONTAINER_NAME} (currently
      # +"pikuri-internal-chroma"+) and carries the
      # +pikuri.internal=true+ docker label. Any container under
      # that name is treated as fully owned by pikuri — if the
      # existing container's image tag doesn't match {IMAGE}, the
      # container is removed and recreated on the pinned image
      # without ceremony. The data volume is bind-mounted from the
      # user's cache directory and is *not* nuked by this — the
      # user's chroma data is theirs, even when the container that
      # runs against it gets replaced.
      #
      # Same convention scales to future internal containers
      # (rerankers, alternative vector stores) — anything starting
      # with +"pikuri-internal-"+ is fair game for pikuri to manage.
      #
      # == Ephemeral container, persistent data
      #
      # The container is disposable; the corpus is not. Every byte of
      # chroma state lives on the host volume bind-mounted at
      # {CONTAINER_PERSIST_DIR}, so the container itself carries
      # nothing worth keeping. {#ensure_running!} therefore *recreates*
      # it from scratch on every boot — the lone exception is a
      # container this same process already started and left running,
      # which it reuses (so repeated {#ensure_running!} calls within
      # one process stay cheap). A stopped container, or one left
      # running by a previous run / a crash / a concurrent pikuri, is
      # removed and recreated rather than adopted: a fresh container on
      # the pinned {IMAGE} against the persistent volume is always a
      # clean, known-good start, and the image tag never has to be
      # reconciled.
      #
      # {#close} (fired at process exit via {Pikuri::Finalizers})
      # +docker rm -f+s the container — nothing is left behind, not
      # even a stopped shell. The next run creates a new one and
      # bind-mounts the same volume, so the indexed corpus survives
      # untouched. The single-named-container convention means this
      # assumes one active pikuri at a time; a second concurrent pikuri
      # would remove the first's container out from under it.
      #
      # == Subprocess seam
      #
      # Docker invocations (+docker inspect+, +docker run+,
      # +docker rm -f+) are short-lived shell-outs
      # — capture output, check exit, act. They route through
      # {Pikuri::Subprocess.spawn} like the rest of pikuri-* +lib/+;
      # this class is *not* an exception to the subprocess seam,
      # unlike +pikuri-mcp+'s +ClientWrapper+ (which owns a
      # long-lived stdio pipe the +mcp+ gem mediates).
      #
      # == Bind 127.0.0.1, not 0.0.0.0
      #
      # +-p 127.0.0.1:8000:8000+, not the docker default
      # +-p 8000:8000+. The default binds the host port to every
      # interface, which would expose the user's indexed corpus to
      # anyone on the same LAN. The privacy posture from chapter 1
      # extends here.
      #
      # == Errors are loud
      #
      # Docker missing, +docker run+ exit non-zero, +docker rm -f+
      # exit non-zero, healthcheck timeout — all raise
      # +RuntimeError+ with the offending output. Caller is internal
      # pikuri code (a host's +Agent.new+ block running at boot);
      # this is bug territory, not "tell the model and let it
      # retry."
      class Chroma
        LOGGER = Pikuri.logger_for('VectorDb::Server::Chroma')

        # @return [String] pinned chroma docker image. Bumping this
        #   constant is how the codebase upgrades the chroma
        #   version: {#ensure_running!} recreates the container from
        #   scratch on the next boot, so it comes up on the new pin
        #   automatically (the bind-mounted corpus is untouched).
        IMAGE = 'chromadb/chroma:1.5.9'

        # @return [String] the container name pikuri claims for its
        #   chroma supervisor. Prefix +"pikuri-internal-"+ is the
        #   namespace pikuri squats — see class header.
        CONTAINER_NAME = 'pikuri-internal-chroma'

        # @return [String] docker label set on every container this
        #   class creates. Used by future +docker ps --filter
        #   "label=#{LABEL}"+ enumeration; not load-bearing for the
        #   {#ensure_running!} algorithm itself.
        LABEL = 'pikuri.internal=true'

        # @return [String] path inside the container where chroma
        #   persists its data. Chroma 1.x (the pinned {IMAGE} line)
        #   stores its SQLite + segment files at +/data+ — this is
        #   the +-v+ target the host's {#default_data_dir}
        #   bind-mounts onto. (Chroma 0.x used +/chroma/chroma+;
        #   mounting that path against a 1.x image silently leaves
        #   the host dir empty while the data accumulates in the
        #   container's writable layer, where +remove_container!+
        #   would destroy it.)
        CONTAINER_PERSIST_DIR = '/data'

        # @return [Integer] default seconds to wait for the
        #   container's HTTP heartbeat to start returning 200 after
        #   +docker run+ / +docker start+.
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
        #   wiring custom +Backend::Chroma+ constructions.
        def endpoint
          "http://localhost:#{@port}"
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

        # Idempotent: ensure a fresh container is running, heartbeat-poll
        # until ready, then register {#close} with {Pikuri::Finalizers} so
        # the container is removed at process exit. A container this
        # process already started and left running is reused (a second
        # call is one +docker inspect+ plus a heartbeat round trip);
        # anything else — a stopped container, a running one this process
        # did not start, or no container at all — is removed (if present)
        # and recreated on the pinned {IMAGE}. See "Ephemeral container,
        # persistent data" in the class header.
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
            # A stopped container, a running one this process did not
            # start, or nothing at all: replace it with a fresh
            # container on the pinned image. The corpus lives on the
            # bind-mounted host volume, so the discarded container holds
            # no state worth keeping. See the class header, "Ephemeral
            # container, persistent data".
            remove_container! unless state == :missing
            run_container!
          end

          @owns_container = true
          wait_for_healthy!
          register_for_cleanup
        end

        # Remove the supervised container. Registered with
        # {Pikuri::Finalizers} by {#ensure_running!} so it runs at
        # process exit; safe to call directly too.
        #
        # Best-effort and idempotent: a no-op if this server never
        # started a container or has already closed, and a non-zero
        # +docker rm -f+ is logged rather than raised (teardown shouldn't
        # abort on a container that's already gone). Contrast
        # {#ensure_running!}, where docker failures are loud — that's
        # boot, this is teardown.
        #
        # Uses +docker rm -f+, not +docker stop+: the container is
        # disposable (the corpus lives on the bind-mounted host volume),
        # so it is discarded outright rather than left stopped. The next
        # run's {#ensure_running!} creates a fresh container against the
        # same volume. See "Ephemeral container, persistent data" in the
        # class header.
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
        # +$XDG_CACHE_HOME/pikuri/chroma+ if set, else
        # +~/.cache/pikuri/chroma+. Public so tests and chapter
        # examples can reference the same path the supervisor
        # resolves at runtime.
        #
        # @return [String]
        def default_data_dir
          Pikuri::Paths.cache.join('chroma').to_s
        end

        private

        # Register this server's {#close} with the process-global
        # teardown registry, once. Idempotent across repeated
        # {#ensure_running!} calls — {Pikuri::Finalizers} would
        # otherwise hold duplicate handles for the same server.
        def register_for_cleanup
          @finalizer_handle ||= Pikuri::Finalizers.register(self)
        end

        # Inspect the container by name. Returns one of +:missing+ /
        # +:stopped+ / +:running+. +docker inspect+ exits non-zero
        # when the container doesn't exist. The image tag is *not*
        # consulted: a wrong-image container falls into the same
        # remove-and-recreate path as any other non-owned container
        # (see {#ensure_running!}), so there is nothing to branch on.
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
            '-p', "127.0.0.1:#{@port}:8000",
            '-v', "#{@data_dir}:#{CONTAINER_PERSIST_DIR}",
            IMAGE
          )
          return if result.status.success?

          raise "Server::Chroma: docker run failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        def remove_container!
          result = docker('rm', '-f', CONTAINER_NAME)
          return if result.status.success?

          raise "Server::Chroma: docker rm -f #{CONTAINER_NAME} failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        # Poll +GET /api/v2/heartbeat+ until 200 or
        # +@healthcheck_timeout+ elapses. 500ms between attempts.
        # Faraday connection errors during the wait are normal
        # (the container's HTTP listener takes a few seconds to
        # bind on cold start); they don't propagate, just feed the
        # loop. Only the final timeout raises.
        def wait_for_healthy!
          deadline = Time.now + @healthcheck_timeout
          last_error = 'no attempts'

          until Time.now > deadline
            begin
              response = http.get('/api/v2/heartbeat')
              return if response.status == 200

              last_error = "HTTP #{response.status}"
            rescue Faraday::Error => e
              last_error = "#{e.class.name.split('::').last}: #{e.message}"
            end
            sleep 0.5
          end

          raise "Server::Chroma: #{CONTAINER_NAME} did not become healthy within " \
                "#{@healthcheck_timeout}s at #{endpoint} (last: #{last_error})"
        end

        def http
          @connection ||= Faraday.new(url: endpoint) do |f|
            f.request :json
            f.response :json
            f.adapter Faraday.default_adapter
          end
        end

        # Single chokepoint for every +docker+ invocation. Routes
        # through {Pikuri::Subprocess.spawn} per the subprocess
        # seam; rescues +Errno::ENOENT+ to surface a clearer
        # message when docker isn't installed.
        def docker(*argv)
          Pikuri::Subprocess.spawn('docker', *argv, chdir: '/').wait
        rescue Errno::ENOENT
          raise 'Server::Chroma: `docker` not found on PATH. ' \
                'Install docker, or point Backend::Chroma at an existing ' \
                'chroma endpoint via Backend::Chroma.new(host:, port:, collection:).'
        end
      end
    end
  end
end
