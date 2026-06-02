# frozen_string_literal: true

require 'faraday'

module Pikuri
  module VectorDb
    module Server
      # Lifecycle engine for one named, disposable docker container
      # with persistent bind-mounted data — the shared machinery
      # {Server::Qdrant} and {Server::Chroma} compose. The supervisor
      # carries the engine's identity (image pin, container name,
      # persist path, heartbeat path) and hands it all over here as
      # explicit constructor parameters; this class does the docker
      # work: create / recreate / remove the container, publish the
      # port, heartbeat-poll until ready.
      #
      # == Namespace squat: pikuri-internal-*
      #
      # Containers are named +"pikuri-internal-<engine>"+ and carry
      # the +pikuri.internal=true+ docker label. Any container under
      # such a name is treated as fully owned by pikuri — wrong
      # image, stopped, or left behind by a crash, it is removed and
      # recreated on the pinned image without ceremony. The data
      # volume is bind-mounted from the user's cache directory and is
      # *not* nuked by this — the user's corpus is theirs, even when
      # the container that runs against it gets replaced. The same
      # convention scales to future internal containers (rerankers,
      # alternative vector stores): anything starting with
      # +"pikuri-internal-"+ is fair game for pikuri to manage.
      #
      # == Ephemeral container, persistent data
      #
      # The container is disposable; the data is not. Every byte of
      # engine state lives on the host volume bind-mounted into the
      # container, so the container itself carries nothing worth
      # keeping. {#ensure_running!} therefore *recreates* it from
      # scratch on every boot — the lone exception is a container
      # this same instance already started and left running, which it
      # reuses (so repeated calls within one process stay cheap). A
      # stopped container, or one left running by a previous run / a
      # crash / a concurrent pikuri, is removed and recreated rather
      # than adopted: a fresh container on the pinned image against
      # the persistent volume is always a clean, known-good start,
      # and the image tag never has to be reconciled. {#close}
      # +docker rm -f+s the container — nothing is left behind, not
      # even a stopped shell. The single-named-container convention
      # assumes one active pikuri at a time; a second concurrent
      # pikuri would remove the first's container out from under it.
      #
      # == Subprocess seam
      #
      # Docker invocations (+docker inspect+, +docker run+,
      # +docker rm -f+) are short-lived shell-outs — capture output,
      # check exit, act. They route through
      # {Pikuri::Subprocess.spawn} like the rest of pikuri-* +lib/+;
      # this class is *not* an exception to the subprocess seam,
      # unlike +pikuri-mcp+'s +ClientWrapper+ (which owns a
      # long-lived stdio pipe the +mcp+ gem mediates).
      #
      # == Bind 127.0.0.1, not 0.0.0.0
      #
      # The port publish is built here as
      # +-p 127.0.0.1:<host>:<container>+, never the docker default
      # +-p <host>:<container>+. The default binds the host port to
      # every interface, which would expose the user's indexed corpus
      # to anyone on the same LAN. Centralizing the publish string in
      # this class makes the privacy posture a single enforcement
      # point rather than a per-supervisor convention.
      #
      # == Errors are loud at boot, quiet at teardown
      #
      # Docker missing, +docker run+ exit non-zero, healthcheck
      # timeout — all raise +RuntimeError+ with the offending output,
      # prefixed with the container name. Caller is internal pikuri
      # code (a host's +Agent.new+ block running at boot); this is
      # bug territory, not "tell the model and let it retry". {#close}
      # is the opposite: best-effort, idempotent, logs instead of
      # raising — teardown shouldn't abort on a container that's
      # already gone.
      class DockerContainer
        LOGGER = Pikuri.logger_for('VectorDb::Server')

        # @param name [String] container name, e.g.
        #   +"pikuri-internal-qdrant"+ — see "Namespace squat" in the
        #   class header.
        # @param image [String] pinned docker image, e.g.
        #   +"qdrant/qdrant:v1.12.4"+.
        # @param label [String] docker label set on the container,
        #   e.g. +"pikuri.internal=true"+.
        # @param host_port [Integer] host port to publish, bound to
        #   127.0.0.1 only.
        # @param container_port [Integer] the engine's port inside
        #   the container, e.g. +6333+ for qdrant.
        # @param volume [String] full +-v+ bind-mount argument,
        #   +"<host dir>:<container persist dir>"+. The host side
        #   must exist before {#ensure_running!} (the supervisor
        #   +mkdir_p+s it — docker would otherwise create it
        #   root-owned).
        # @param health_path [String] HTTP path heartbeat-polled
        #   until it returns 200, e.g. +"/healthz"+.
        # @param healthcheck_timeout [Integer] seconds to poll
        #   +health_path+ before giving up.
        # @param connection [Faraday::Connection, nil] DI hook for
        #   tests. Production callers leave it +nil+.
        # @return [DockerContainer]
        def initialize(name:, image:, label:, host_port:, container_port:,
                       volume:, health_path:, healthcheck_timeout:,
                       connection: nil)
          @name = name
          @image = image
          @label = label
          @host_port = host_port
          @container_port = container_port
          @volume = volume
          @health_path = health_path
          @healthcheck_timeout = healthcheck_timeout
          @connection = connection
          @owns_container = false
          @closed = false
        end

        # @return [String] container name.
        attr_reader :name

        # @return [String] +"http://localhost:<host_port>"+.
        def endpoint
          "http://localhost:#{@host_port}"
        end

        # Idempotent: ensure a fresh container is running, then
        # heartbeat-poll until ready. A container this instance
        # already started and left running is reused (a second call
        # is one +docker inspect+ plus a heartbeat round trip);
        # anything else — a stopped container, a running one this
        # instance did not start, or no container at all — is removed
        # (if present) and recreated on the pinned image. See
        # "Ephemeral container, persistent data" in the class header.
        #
        # @return [void]
        # @raise [RuntimeError] on missing docker, any docker
        #   command failure, or healthcheck timeout.
        def ensure_running!
          state = container_state
          if @owns_container && state == :running
            LOGGER.info("#{@name} already running")
          else
            remove_container! unless state == :missing
            run_container!
          end

          @owns_container = true
          @closed = false
          wait_for_healthy!
        end

        # Remove the container (+docker rm -f+), leaving the
        # bind-mounted host volume — the data survives. Best-effort
        # and idempotent: a no-op if this instance never started a
        # container or has already closed, and a non-zero +rm+ is
        # logged rather than raised — that's teardown, boot is loud.
        #
        # @return [void]
        def close
          return if @closed || !@owns_container

          @closed = true
          result = docker('rm', '-f', @name)
          return if result.status.success?

          LOGGER.warn(
            "docker rm -f #{@name} failed " \
            "(exit #{result.status.exitstatus}): #{result.output.strip}"
          )
        end

        private

        # Inspect the container by name. Returns one of +:missing+ /
        # +:stopped+ / +:running+. +docker inspect+ exits non-zero
        # when the container doesn't exist. The image tag is *not*
        # consulted: a wrong-image container falls into the same
        # remove-and-recreate path as any other non-owned container
        # (see {#ensure_running!}), so there is nothing to branch on.
        def container_state
          result = docker('inspect', '--format', '{{.State.Running}}', @name)
          return :missing unless result.status.success?

          result.output.strip == 'true' ? :running : :stopped
        end

        def run_container!
          LOGGER.info(
            "starting #{@name} (#{@image}) on 127.0.0.1:#{@host_port}, " \
            "volume: #{@volume}"
          )
          result = docker(
            'run', '-d',
            '--name', @name,
            '--label', @label,
            '-p', "127.0.0.1:#{@host_port}:#{@container_port}",
            '-v', @volume,
            @image
          )
          return if result.status.success?

          raise "#{@name}: docker run failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        def remove_container!
          result = docker('rm', '-f', @name)
          return if result.status.success?

          raise "#{@name}: docker rm -f failed " \
                "(exit #{result.status.exitstatus}): #{result.output.strip}"
        end

        # Poll +GET <health_path>+ until 200 or
        # +@healthcheck_timeout+ elapses. 500ms between attempts.
        # Faraday connection errors during the wait are normal (the
        # container's HTTP listener takes a few seconds to bind on
        # cold start); they don't propagate, just feed the loop. Only
        # the final timeout raises.
        def wait_for_healthy!
          deadline = Time.now + @healthcheck_timeout
          last_error = 'no attempts'

          until Time.now > deadline
            begin
              response = http.get(@health_path)
              return if response.status == 200

              last_error = "HTTP #{response.status}"
            rescue Faraday::Error => e
              last_error = "#{e.class.name.split('::').last}: #{e.message}"
            end
            sleep 0.5
          end

          raise "#{@name}: did not become healthy within " \
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
          raise "#{@name}: `docker` not found on PATH. Install docker, " \
                'or point the engine Backend at a server you run yourself ' \
                '(e.g. Backend::Qdrant.new(host:, port:, collection:)).'
        end
      end
    end
  end
end
