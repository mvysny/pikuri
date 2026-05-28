# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'pathname'

module Pikuri
  module VectorDb
    # Supervisor for a self-managed Chroma docker container. Pairs
    # with {Backend::Chroma}: this class owns the *process* (find /
    # start / nuke-and-recreate the container, mount the volume,
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
    # == Subprocess seam
    #
    # Docker invocations (+docker inspect+, +docker run+,
    # +docker start+, +docker rm -f+) are short-lived shell-outs
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
    class ChromaServer
      LOGGER = Pikuri.logger_for('VectorDb::ChromaServer')

      # @return [String] pinned chroma docker image. Bumping this
      #   constant is how the codebase upgrades the chroma
      #   version. An existing container running an older image
      #   under our {CONTAINER_NAME} is removed and recreated
      #   when {#ensure_running!} runs against a bumped pin.
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
      #   persists its data (chroma's +PERSIST_DIRECTORY+ default
      #   when +WORKDIR+ is +/chroma+). The host's
      #   {#default_data_dir} bind-mounts here.
      CONTAINER_PERSIST_DIR = '/chroma/chroma'

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
      # @return [ChromaServer]
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
      # @return [ChromaServer]
      def initialize(data_dir: nil, port: 8000,
                     healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT,
                     connection: nil)
        @data_dir = Pathname.new(data_dir || default_data_dir).expand_path
        @port = port
        @healthcheck_timeout = healthcheck_timeout
        @connection = connection
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

      # Idempotent: find / start / recreate the container, then
      # heartbeat-poll until ready. Safe to call repeatedly; a
      # second call against an already-running healthy container
      # is a couple of +docker inspect+ + heartbeat round trips.
      #
      # @return [void]
      # @raise [RuntimeError] on missing docker, any docker
      #   command failure, or healthcheck timeout.
      def ensure_running!
        FileUtils.mkdir_p(@data_dir)

        case container_state
        when :missing
          run_container!
        when :wrong_image
          LOGGER.info("removing #{CONTAINER_NAME} (image mismatch with pin #{IMAGE})")
          remove_container!
          run_container!
        when :stopped
          LOGGER.info("starting existing #{CONTAINER_NAME}")
          start_container!
        when :running
          LOGGER.info("#{CONTAINER_NAME} already running")
        end

        wait_for_healthy!
      end

      # Default host-side data directory:
      # +$XDG_CACHE_HOME/pikuri/chroma+ if set, else
      # +~/.cache/pikuri/chroma+. Public so tests and chapter
      # examples can reference the same path the supervisor
      # resolves at runtime.
      #
      # @return [String]
      def default_data_dir
        cache_home = ENV['XDG_CACHE_HOME']
        cache_home = File.expand_path('~/.cache') if cache_home.nil? || cache_home.empty?
        File.join(cache_home, 'pikuri', 'chroma')
      end

      private

      # Inspect the container by name. Returns one of
      # +:missing+ / +:wrong_image+ / +:stopped+ / +:running+.
      # +docker inspect+ exits non-zero when the container
      # doesn't exist; the +--format+ string keeps parsing trivial
      # (image and running-state on one line, pipe-separated).
      def container_state
        result = docker(
          'inspect', '--format', '{{.Config.Image}}|{{.State.Running}}',
          CONTAINER_NAME
        )
        return :missing unless result.status.success?

        image, running = result.output.strip.split('|', 2)
        return :wrong_image unless image == IMAGE
        return :running if running == 'true'

        :stopped
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

        raise "ChromaServer: docker run failed " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}"
      end

      def remove_container!
        result = docker('rm', '-f', CONTAINER_NAME)
        return if result.status.success?

        raise "ChromaServer: docker rm -f #{CONTAINER_NAME} failed " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}"
      end

      def start_container!
        result = docker('start', CONTAINER_NAME)
        return if result.status.success?

        raise "ChromaServer: docker start #{CONTAINER_NAME} failed " \
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

        raise "ChromaServer: #{CONTAINER_NAME} did not become healthy within " \
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
        raise 'ChromaServer: `docker` not found on PATH. ' \
              'Install docker, or point Backend::Chroma at an existing ' \
              'chroma endpoint via Backend::Chroma.new(host:, port:, collection:).'
      end
    end
  end
end
