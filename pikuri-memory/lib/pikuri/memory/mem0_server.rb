# frozen_string_literal: true

require 'faraday'
require 'fileutils'
require 'pathname'

module Pikuri
  module Memory
    # Supervisor for a self-managed mem0 + Qdrant sidecar. Pairs with
    # {Mem0Client}: this class owns the *stack* (clone + patch the mem0
    # source, +docker compose up --build+, heartbeat-poll, tear down);
    # {Mem0Client} owns the HTTP client that talks to it. {#client}
    # returns a {Mem0Client} pre-pointed at the running server.
    #
    # Same split, and the same "let pikuri manage it" vs "bring your own"
    # choice, as +pikuri-vectordb+'s {Pikuri::VectorDb::ChromaServer} /
    # {Pikuri::VectorDb::Backend::Chroma}. A host already running mem0
    # elsewhere skips this class and wires {Mem0Client.new(endpoint:)}
    # directly.
    #
    # == Why a compose stack, not a single +docker run+
    #
    # Unlike Chroma (one clean published image), mem0's REST server has
    # no usable published image — the one on Docker Hub is stale
    # (pre-v3) — so it is *built from source*, and it needs Qdrant as a
    # second container. Two interdependent services with a build step is
    # exactly what compose models, and it is mem0 upstream's own blessed
    # run path. So this supervisor wraps +docker compose+ (through
    # {Pikuri::Subprocess.spawn}) over the compose file shipped in the
    # gem's +docker/+ directory, rather than reimplementing service
    # ordering by hand.
    #
    # == No Postgres; Qdrant, patched in at build
    #
    # The upstream server's +DEFAULT_CONFIG+ hardcodes the **pgvector**
    # vector store, whose mem0 provider has a top-k inversion bug (cosine
    # *distance* ranked as a *similarity* — DESIGN.md §"Root cause: the
    # pgvector top-k inversion"), *and* whose provider connects to
    # Postgres eagerly at boot.
    # {#prepare_checkout!} applies +docker/qdrant-default-config.patch+ to
    # the pinned checkout, swapping that default to **Qdrant** (env-driven
    # host/port/dims). Result: correct nearest-first ranking *and* no
    # Postgres in the stack — verified end-to-end (server boots
    # Postgres-free; add + search through the REST API rank correctly
    # against the local llama.cpp router).
    #
    # == Local LLM + embedder via the router
    #
    # mem0's bundled provider validation accepts only +openai+ /
    # +anthropic+ / +gemini+ for the LLM and +openai+ / +gemini+ for the
    # embedder, so the local path keeps +provider: "openai"+ and points
    # +OPENAI_BASE_URL+ at the llama.cpp router. The extraction model must
    # be **non-reasoning** (e.g. +Qwen2.5-7B-Instruct+): a thinking model
    # burns its budget on CoT and returns empty/truncated JSON
    # (DESIGN.md §"Extraction model decision"). The vector
    # store is not bundle-gated, so Qdrant is accepted.
    #
    # == Pinned + patched checkout
    #
    # The mem0 server is built from {MEM0_REF} (a pinned commit), cloned
    # into the cache dir once and reused. The patch is applied with
    # +git apply+ and is **fail-loud**: if it neither applies cleanly nor
    # is already applied, {#prepare_checkout!} raises rather than building
    # a wrong image (same discipline as the no-think build patch in
    # DESIGN.md §"The no-think patch (fallback): verified live").
    #
    # == Bind 127.0.0.1
    #
    # The shipped compose publishes both ports on +127.0.0.1+ only — the
    # user's memory never listens on a routable interface, same posture as
    # {Pikuri::VectorDb::ChromaServer}.
    #
    # == Subprocess seam
    #
    # Every +git+ / +docker+ invocation routes through
    # {Pikuri::Subprocess.spawn} per the subprocess seam. Errors at boot
    # (missing docker/git, build failure, healthcheck timeout) raise
    # +RuntimeError+ with the offending output; teardown failures are
    # logged, not raised.
    class Mem0Server
      LOGGER = Pikuri.logger_for('Memory::Mem0Server')

      # @return [String] mem0 git remote the server is built from.
      MEM0_REPO_URL = 'https://github.com/mem0ai/mem0.git'

      # @return [String] pinned mem0 commit the image is built from
      #   (library 2.0.4, v3 token-efficient algorithm). Bumping this is
      #   how the mem0 version is upgraded — and the shipped patch must be
      #   regenerated against the new ref if +DEFAULT_CONFIG+ moved.
      MEM0_REF = 'a3154d59e52386d4e1189c1f5f44819868f76514'

      # @return [String] compose project name. Prefix +pikuri-internal-+
      #   is the namespace pikuri squats for self-managed infra (same
      #   convention as {Pikuri::VectorDb::ChromaServer}).
      COMPOSE_PROJECT = 'pikuri-internal-mem0'

      # @return [String] absolute path to the shipped compose file.
      COMPOSE_FILE = File.expand_path('../../../docker/docker-compose.yml', __dir__)

      # @return [String] absolute path to the shipped DEFAULT_CONFIG
      #   pgvector→qdrant patch.
      PATCH_FILE = File.expand_path('../../../docker/qdrant-default-config.patch', __dir__)

      # @return [Integer] default host port mem0's REST API binds (127.0.0.1).
      DEFAULT_PORT = 8888

      # @return [Integer] default host port Qdrant binds (127.0.0.1),
      #   published for inspection only.
      DEFAULT_QDRANT_PORT = 6333

      # @return [Integer] default embedding dimension. 768 matches
      #   +nomic-embed-text-v1.5+; must equal the embedder's output dim or
      #   Qdrant rejects upserts.
      DEFAULT_EMBEDDING_DIMS = 768

      # @return [String] default Qdrant collection name.
      DEFAULT_COLLECTION = 'pikuri_memory'

      # @return [String] pinned Qdrant image.
      DEFAULT_QDRANT_IMAGE = 'qdrant/qdrant:v1.12.4'

      # @return [Integer] seconds to wait for the REST API to answer after
      #   +compose up+ returns. The first run also builds the image inside
      #   +compose up --build+ (minutes), but that is covered by the
      #   blocking build call, not this poll — this only covers
      #   container-start readiness.
      DEFAULT_HEALTHCHECK_TIMEOUT = 60

      # Construct and immediately ensure the stack is running.
      # Convenience factory — +new(...).tap(&:ensure_running!)+.
      #
      # @return [Mem0Server]
      def self.ensure_running(**kwargs)
        new(**kwargs).tap(&:ensure_running!)
      end

      # @param router_url [String] llama.cpp OpenAI-compatible base URL
      #   (e.g. +"http://192.168.122.1:8080/v1"+) the mem0 server routes
      #   its LLM + embedder calls to.
      # @param llm_model [String] extraction model id on the router. Must
      #   be **non-reasoning** (see the class header).
      # @param embedder_model [String] embedder model id on the router.
      # @param port [Integer] host port for the REST API (127.0.0.1).
      # @param qdrant_port [Integer] host port for Qdrant (127.0.0.1).
      # @param embedding_dims [Integer] embedder output dimension.
      # @param collection [String] Qdrant collection name.
      # @param qdrant_image [String] Qdrant docker image.
      # @param cache_dir [String, Pathname, nil] where the mem0 checkout
      #   lives. +nil+ resolves to {#default_cache_dir}.
      # @param healthcheck_timeout [Integer] seconds to poll readiness.
      # @param connection [Faraday::Connection, nil] DI hook for tests.
      # @return [Mem0Server]
      def initialize(router_url:, llm_model:, embedder_model:,
                     port: DEFAULT_PORT, qdrant_port: DEFAULT_QDRANT_PORT,
                     embedding_dims: DEFAULT_EMBEDDING_DIMS, collection: DEFAULT_COLLECTION,
                     qdrant_image: DEFAULT_QDRANT_IMAGE, cache_dir: nil,
                     healthcheck_timeout: DEFAULT_HEALTHCHECK_TIMEOUT, connection: nil)
        @router_url = router_url
        @llm_model = llm_model
        @embedder_model = embedder_model
        @port = port
        @qdrant_port = qdrant_port
        @embedding_dims = embedding_dims
        @collection = collection
        @qdrant_image = qdrant_image
        @cache_dir = Pathname.new(cache_dir || default_cache_dir).expand_path
        @healthcheck_timeout = healthcheck_timeout
        @connection = connection
        @closed = false
        @finalizer_handle = nil
      end

      # @return [Integer] host port the REST API binds.
      attr_reader :port

      # @return [Pathname] the mem0 source checkout (the image build
      #   context). Under +temp/+ — it is a regenerable clone, not data.
      def checkout_dir
        @cache_dir.join('temp', 'git')
      end

      # @return [Pathname] host directory bind-mounted into the
      #   containers for persistent state — +data/qdrant+ holds the
      #   Qdrant corpus, +data/history+ the memory-history SQLite. The
      #   containers are ephemeral; this survives them (same posture as
      #   {Pikuri::VectorDb::ChromaServer}).
      def data_dir
        @cache_dir.join('data')
      end

      # @return [String] +"http://localhost:<port>"+.
      def endpoint
        "http://localhost:#{@port}"
      end

      # Build a {Mem0Client} pointed at the supervised server.
      #
      # @return [Mem0Client]
      def client
        Mem0Client.new(endpoint: endpoint, connection: @connection)
      end

      # Idempotent: ensure the checkout exists + is patched, bring the
      # compose stack up (building the image on first run), heartbeat-poll
      # the REST API until ready, then register {#close} with
      # {Pikuri::Finalizers} so the stack is stopped at process exit.
      #
      # @return [void]
      # @raise [RuntimeError] on missing docker/git, clone/patch failure,
      #   +compose up+ failure, or healthcheck timeout.
      def ensure_running!
        prepare_checkout!
        # Pre-create the bind-mount sources so docker doesn't create them
        # root-owned (and so a missing dir isn't silently a fresh volume).
        FileUtils.mkdir_p(data_dir.join('qdrant'))
        FileUtils.mkdir_p(data_dir.join('history'))
        LOGGER.info("starting #{COMPOSE_PROJECT} (mem0 + Qdrant) on 127.0.0.1:#{@port}; " \
                    'first run builds the mem0 image and may take a few minutes')
        compose!('up', '-d', '--build')
        wait_for_healthy!
        register_for_cleanup
      end

      # Stop the stack (+docker compose down+), leaving {#data_dir}'s
      # bind-mounted host directories — the Qdrant corpus and memory
      # history survive. Registered with
      # {Pikuri::Finalizers} by {#ensure_running!}; safe to call directly.
      # Best-effort and idempotent: a non-zero +down+ is logged, not
      # raised (teardown shouldn't abort on an already-gone stack).
      #
      # @return [void]
      def close
        return if @closed

        @closed = true
        result = compose('down')
        return if result.status.success?

        LOGGER.warn("docker compose down failed (exit #{result.status.exitstatus}): #{result.output.strip}")
      end

      # Default cache root for this supervisor: +<Pikuri::Paths.cache>/mem0+
      # (i.e. +$XDG_CACHE_HOME/pikuri/mem0+ or +~/.cache/pikuri/mem0+).
      # Holds +temp/git+ (the checkout) and +data/+ (the bind-mounted
      # corpus + history). Shares the cache root with
      # {Pikuri::VectorDb::ChromaServer} via {Pikuri::Paths}. Public so
      # tests and docs reference the same path the supervisor resolves.
      #
      # @return [String]
      def default_cache_dir
        Pikuri::Paths.cache.join('mem0').to_s
      end

      private

      # Clone mem0 at {MEM0_REF} (once) and apply the Qdrant patch
      # (idempotently, fail-loud). Reused across runs — a populated,
      # already-patched checkout is a no-op.
      def prepare_checkout!
        ensure_clone!
        apply_patch!
      end

      # Shallow-fetch the pinned commit into {#checkout_dir} if not already
      # there. GitHub serves a fetch-by-SHA, so this stays a one-commit
      # fetch rather than a full clone.
      def ensure_clone!
        dir = checkout_dir
        return if dir.join('.git').directory? && git('rev-parse', 'HEAD', chdir: dir).output.strip == MEM0_REF

        LOGGER.info("fetching mem0 @ #{MEM0_REF[0, 12]} into #{dir}")
        FileUtils.mkdir_p(dir)
        run_loud!(git('init', '-q', chdir: dir), 'git init')
        # `remote add` is non-idempotent; ignore its failure (already added).
        git('remote', 'add', 'origin', MEM0_REPO_URL, chdir: dir)
        run_loud!(git('fetch', '--depth', '1', 'origin', MEM0_REF, chdir: dir),
                  "git fetch #{MEM0_REF}")
        run_loud!(git('checkout', '-q', '--detach', 'FETCH_HEAD', chdir: dir),
                  'git checkout FETCH_HEAD')
      end

      # Apply {PATCH_FILE} unless it is already applied. Fail loud if it
      # neither applies cleanly nor is already present (upstream drift
      # past the pinned ref) — never build a wrong image silently.
      def apply_patch!
        dir = checkout_dir
        return if git('apply', '--reverse', '--check', PATCH_FILE, chdir: dir).status.success?

        result = git('apply', PATCH_FILE, chdir: dir)
        return if result.status.success?

        raise "Mem0Server: failed to apply #{PATCH_FILE} to mem0 @ #{MEM0_REF} " \
              "(exit #{result.status.exitstatus}): #{result.output.strip}. " \
              'The pinned ref or the patch may have drifted; regenerate the patch.'
      end

      # Run +docker compose+ with the supervisor's env, raising on
      # failure. Used for +up+ (boot — loud).
      def compose!(*args)
        run_loud!(compose(*args), "docker compose #{args.join(' ')}")
      end

      # Run +docker compose+ with the supervisor's env, returning the
      # {Pikuri::Subprocess::Result} (caller decides loud vs quiet). Used
      # for +down+ (teardown — quiet).
      def compose(*args)
        docker('compose', '-p', COMPOSE_PROJECT, '-f', COMPOSE_FILE, *args, env: compose_env)
      end

      # Environment the compose file interpolates (+${PIKURI_*}+) — the
      # checkout path as the build context plus the router + model wiring.
      def compose_env
        {
          'PIKURI_MEM0_SRC' => checkout_dir.to_s,
          'PIKURI_DATA_DIR' => data_dir.to_s,
          'PIKURI_ROUTER_URL' => @router_url,
          'PIKURI_LLM_MODEL' => @llm_model,
          'PIKURI_EMBEDDER_MODEL' => @embedder_model,
          'PIKURI_MEM0_PORT' => @port.to_s,
          'PIKURI_QDRANT_PORT' => @qdrant_port.to_s,
          'PIKURI_QDRANT_IMAGE' => @qdrant_image,
          'PIKURI_COLLECTION' => @collection,
          'PIKURI_EMBEDDING_DIMS' => @embedding_dims.to_s
        }
      end

      # Poll the REST API's +/docs+ (FastAPI serves it once startup —
      # including Qdrant collection creation — completes) until 200 or the
      # timeout elapses. Connection errors during the wait are normal
      # (the container takes a moment to bind) and just feed the loop.
      def wait_for_healthy!
        deadline = Time.now + @healthcheck_timeout
        last_error = 'no attempts'

        until Time.now > deadline
          begin
            response = http.get('/docs')
            return if response.status == 200

            last_error = "HTTP #{response.status}"
          rescue Faraday::Error => e
            last_error = "#{e.class.name.split('::').last}: #{e.message}"
          end
          sleep 0.5
        end

        raise "Mem0Server: #{COMPOSE_PROJECT} did not become healthy within " \
              "#{@healthcheck_timeout}s at #{endpoint} (last: #{last_error})"
      end

      # Heartbeat-poll connection. Uses the injected +connection:+ when
      # given (DI for tests), else a fresh plain connection against the
      # endpoint.
      def http
        @http ||= @connection || Faraday.new(url: endpoint) do |f|
          f.adapter Faraday.default_adapter
        end
      end

      # Register {#close} with the process-global teardown registry, once.
      def register_for_cleanup
        @finalizer_handle ||= Pikuri::Finalizers.register(self)
      end

      # +docker+ chokepoint — routes through {Pikuri::Subprocess.spawn}
      # (subprocess seam). Surfaces a clearer message when docker is absent.
      def docker(*argv, env: {})
        Pikuri::Subprocess.spawn('docker', *argv, chdir: '/', env: env).wait
      rescue Errno::ENOENT
        raise 'Mem0Server: `docker` not found on PATH. Install docker (with the ' \
              'compose plugin), or point Mem0Client at an existing mem0 endpoint ' \
              'via Pikuri::Memory::Mem0Client.new(endpoint:).'
      end

      # +git+ chokepoint — routes through {Pikuri::Subprocess.spawn}.
      def git(*argv, chdir:)
        Pikuri::Subprocess.spawn('git', *argv, chdir: chdir.to_s).wait
      rescue Errno::ENOENT
        raise 'Mem0Server: `git` not found on PATH. Install git, or point ' \
              'Mem0Client at an existing mem0 endpoint.'
      end

      # Raise with the command's output if +result+ is non-zero.
      def run_loud!(result, what)
        return result if result.status.success?

        raise "Mem0Server: #{what} failed (exit #{result.status.exitstatus}): #{result.output.strip}"
      end
    end
  end
end
