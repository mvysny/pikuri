# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'fileutils'
require 'tmpdir'

describe Pikuri::VectorDb::Server::Qdrant do
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze
  # Qdrant's /healthz answers text/plain, not JSON — the heartbeat
  # stubs mirror that so the json response middleware is exercised
  # against the real content type.
  TEXT_HEADERS = { 'Content-Type' => 'text/plain; charset=utf-8' }.freeze

  let(:data_dir) { Dir.mktmpdir('pikuri-qdrant-server-spec-') }
  after { FileUtils.remove_entry(data_dir) }

  # Stub the subprocess seam — same pattern as the Server::Chroma
  # spec: capture every docker invocation, return planned results
  # in FIFO order. +:enoent+ simulates `docker` missing.
  let(:docker_calls) { [] }
  let(:planned_results) { [] }

  # Faraday stub for the heartbeat poll.
  let(:heartbeat_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:heartbeat_conn) do
    Faraday.new do |f|
      f.request :json
      f.response :json
      f.adapter :test, heartbeat_stubs
    end
  end

  before do
    calls_ref = docker_calls
    plans_ref = planned_results

    fake_proc_class = Class.new do
      def initialize(exit_status, output)
        @exit_status = exit_status
        @output = output
      end

      def wait
        status = Struct.new(:exitstatus) do
          def success?
            exitstatus.zero?
          end
        end.new(@exit_status)
        Struct.new(:output, :status).new(@output, status)
      end
    end

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_spawn, :spawn)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **_kw|
      calls_ref << argv
      plan = plans_ref.shift
      raise Errno::ENOENT, 'docker' if plan == :enoent

      exit_status, output = plan
      fake_proc_class.new(exit_status, output)
    end
  end

  after do
    Pikuri::Subprocess.singleton_class.send(:alias_method, :spawn, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_spawn)
  end

  # Unregister built servers from the process-global Finalizers
  # after each example — same hygiene as the Server::Chroma spec.
  let(:built_servers) { [] }
  after { built_servers.each { |s| Pikuri::Finalizers.unregister(s) } }

  def build_server(**overrides)
    server = Pikuri::VectorDb::Server::Qdrant.new(
      data_dir: data_dir,
      port: 6333,
      healthcheck_timeout: 1,
      connection: heartbeat_conn,
      **overrides
    )
    built_servers << server
    server
  end

  describe '#initialize' do
    it 'expands data_dir' do
      server = Pikuri::VectorDb::Server::Qdrant.new(data_dir: '~/x', port: 6333)
      assert_equal File.expand_path('~/x'), server.data_dir.to_s
    end

    it 'derives default data_dir under XDG_CACHE_HOME / pikuri / qdrant' do
      server = Pikuri::VectorDb::Server::Qdrant.new
      assert_match(%r{/pikuri/qdrant\z}, server.default_data_dir)
    end

    it 'exposes endpoint built from port' do
      server = Pikuri::VectorDb::Server::Qdrant.new(port: 9999)
      assert_equal 'http://localhost:9999', server.endpoint
    end
  end

  describe '#client' do
    it 'returns a Backend::Qdrant pointed at this server' do
      server = Pikuri::VectorDb::Server::Qdrant.new(port: 9876)
      client = server.client(collection: 'guide')
      assert_kind_of Pikuri::VectorDb::Backend::Qdrant, client
    end
  end

  describe 'IMAGE pin' do
    it 'matches Mem0Server::DEFAULT_QDRANT_IMAGE when pikuri-memory is loadable (lockstep convention)' do
      # The cross-gem invariant from DESIGN.md §"Verdict": same tag,
      # one image on disk. The gems don't depend on each other, so
      # this guard only fires where the sibling gem is present (the
      # monorepo dev closure — which is where a drifting bump would
      # land first).
      begin
        require 'pikuri-memory'
      rescue LoadError
        skip 'pikuri-memory not in this closure'
      end

      assert_equal Pikuri::Memory::Mem0Server::DEFAULT_QDRANT_IMAGE,
                   Pikuri::VectorDb::Server::Qdrant::IMAGE
    end
  end

  describe '#ensure_running!' do
    it 'creates the container when missing, then heartbeats' do
      planned_results.replace([
                                [1, ''],                 # docker inspect → missing
                                [0, 'container-id-abc']  # docker run → ok
                              ])
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

      build_server.ensure_running!

      inspect_argv, run_argv = docker_calls
      assert_equal %w[docker inspect --format], inspect_argv[0..2]
      assert_equal Pikuri::VectorDb::Server::Qdrant::CONTAINER_NAME, inspect_argv.last
      assert_equal 'docker', run_argv[0]
      assert_equal 'run',    run_argv[1]
      assert_includes run_argv, '-d'
      assert_includes run_argv, Pikuri::VectorDb::Server::Qdrant::IMAGE
      assert_includes run_argv, '--label'
      assert_includes run_argv, Pikuri::VectorDb::Server::Qdrant::LABEL
      # 127.0.0.1 binding, not the docker default 0.0.0.0
      port_publish = run_argv[run_argv.index('-p') + 1]
      assert_equal '127.0.0.1:6333:6333', port_publish
      # Bind-mount → /qdrant/storage (the image's storage root)
      volume_arg = run_argv[run_argv.index('-v') + 1]
      assert_equal "#{data_dir}:#{Pikuri::VectorDb::Server::Qdrant::CONTAINER_PERSIST_DIR}",
                   volume_arg
    end

    it 'removes and recreates a pre-existing stopped container' do
      planned_results.replace([
                                [0, "false\n"],          # inspect → stopped
                                [0, ''],                 # docker rm -f
                                [0, 'container-id-new']  # docker run
                              ])
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

      build_server.ensure_running!

      assert_equal %w[inspect rm run], docker_calls.map { |c| c[1] }
    end

    it 'reclaims a pre-existing running container instead of adopting it' do
      planned_results.replace([
                                [0, "true\n"],          # inspect → running (not ours)
                                [0, ''],                # docker rm -f
                                [0, 'container-id-new'] # docker run
                              ])
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

      build_server.ensure_running!

      assert_equal %w[inspect rm run], docker_calls.map { |c| c[1] }
    end

    it 'does not recreate a container it started earlier in the same process' do
      planned_results.replace([
                                [1, ''],                 # inspect → missing
                                [0, 'container-id-abc'], # docker run
                                [0, "true\n"]            # inspect → running (ours)
                              ])
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

      server = build_server
      server.ensure_running!
      server.ensure_running!

      assert_equal %w[inspect run inspect], docker_calls.map { |c| c[1] }
    end

    it 'raises a clear error when docker is not on PATH' do
      planned_results.replace([:enoent])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/`docker` not found on PATH/, err.message)
    end

    it 'raises with the docker output when `docker run` fails' do
      planned_results.replace([
                                [1, ''],
                                [125, "docker: Error response from daemon: port already allocated\n"]
                              ])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/docker run failed/, err.message)
      assert_match(/port already allocated/, err.message)
    end

    it 'raises when heartbeat never returns 200 within the timeout' do
      planned_results.replace([
                                [1, ''],   # inspect → missing
                                [0, 'cid'] # docker run ok
                              ])
      heartbeat_stubs.get('/healthz') { [503, JSON_HEADERS, ''] }

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/did not become healthy/, err.message)
      assert_match(/HTTP 503/, err.message)
    end

    it 'tolerates Faraday connection errors during the warmup window' do
      planned_results.replace([
                                [1, ''],          # missing
                                [0, 'cid']        # docker run ok
                              ])
      call_n = 0
      heartbeat_stubs.get('/healthz') do
        call_n += 1
        call_n == 1 ? raise(Faraday::ConnectionFailed, 'refused') : [200, TEXT_HEADERS, 'healthz check passed']
      end

      build_server.ensure_running!
      assert call_n >= 2, 'heartbeat must be polled past the first connection refusal'
    end
  end

  describe '#close' do
    def start_then(*plans)
      planned_results.replace([[1, ''], [0, 'container-id-abc'], *plans]) # missing → run, then ...
      heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }
      server = build_server
      server.ensure_running!
      server
    end

    it 'docker-removes the container it started' do
      server = start_then([0, ''])
      server.close
      assert_equal %w[inspect run rm], docker_calls.map { |c| c[1] }
      assert_includes docker_calls.last, '-f'
      assert_equal Pikuri::VectorDb::Server::Qdrant::CONTAINER_NAME, docker_calls.last.last
    end

    it 'is idempotent — a second close issues no further docker rm' do
      server = start_then([0, ''])
      server.close
      server.close
      assert_equal 1, docker_calls.count { |c| c[1] == 'rm' }
    end

    it 'is a no-op when this server never started a container' do
      build_server.close
      assert_empty docker_calls
    end

    it 'logs rather than raises when docker rm fails' do
      server = start_then([137, 'No such container: pikuri-internal-qdrant'])
      server.close # must not raise even though rm exits non-zero
      assert_equal 'rm', docker_calls.last[1]
    end

    it 'registers itself once with Pikuri::Finalizers across repeated ensure_running!' do
      saved = Pikuri::Finalizers.instance_variable_get(:@registered)
      Pikuri::Finalizers.instance_variable_set(:@registered, [])
      begin
        planned_results.replace([
                                  [1, ''], [0, 'cid'], # 1st ensure: missing → run
                                  [0, "true\n"]        # 2nd ensure: running (ours)
                                ])
        heartbeat_stubs.get('/healthz') { [200, TEXT_HEADERS, 'healthz check passed'] }

        server = build_server
        server.ensure_running!
        server.ensure_running!

        registered = Pikuri::Finalizers.instance_variable_get(:@registered)
        assert_equal [server], registered
      ensure
        Pikuri::Finalizers.instance_variable_set(:@registered, saved)
      end
    end
  end
end
