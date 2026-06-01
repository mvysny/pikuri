# frozen_string_literal: true

require 'spec_helper'
require 'faraday'
require 'fileutils'
require 'tmpdir'

describe Pikuri::Memory::Mem0Server do
  let(:cache_dir) { Dir.mktmpdir('pikuri-mem0-server-spec-') }
  after { FileUtils.remove_entry(cache_dir) }

  # Stub the subprocess seam: capture every git/docker invocation (argv +
  # env), return planned [exit, stdout] results in FIFO order. Mirrors
  # pikuri-vectordb's chroma_server_spec.
  let(:calls) { [] }
  let(:planned) { [] }

  # Faraday stub for the /docs heartbeat poll.
  let(:health_stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:health_conn) do
    Faraday.new { |f| f.adapter :test, health_stubs }
  end

  before do
    calls_ref = calls
    plans_ref = planned

    fake_proc = Class.new do
      def initialize(exit_status, output)
        @exit_status = exit_status
        @output = output
      end

      def wait
        status = Struct.new(:exitstatus) do
          def success? = exitstatus.zero?
        end.new(@exit_status)
        Struct.new(:output, :status).new(@output, status)
      end
    end

    Pikuri::Subprocess.singleton_class.send(:alias_method, :__orig_spawn, :spawn)
    Pikuri::Subprocess.define_singleton_method(:spawn) do |*argv, **kw|
      calls_ref << { argv: argv, env: kw[:env] || {} }
      plan = plans_ref.shift
      raise Errno::ENOENT, argv.first if plan == :enoent

      exit_status, output = plan
      fake_proc.new(exit_status, output)
    end
  end

  after do
    Pikuri::Subprocess.singleton_class.send(:alias_method, :spawn, :__orig_spawn)
    Pikuri::Subprocess.singleton_class.send(:remove_method, :__orig_spawn)
  end

  # Track servers so the suite doesn't leave any registered with the
  # process-global Finalizers (which would fire a real `docker compose
  # down` at process exit against the unstubbed seam).
  let(:built) { [] }
  after { built.each { |s| Pikuri::Finalizers.unregister(s) } }

  def build_server(**overrides)
    server = Pikuri::Memory::Mem0Server.new(
      router_url: 'http://router:8080/v1',
      llm_model: 'qwen2.5-7b',
      embedder_model: 'nomic',
      cache_dir: cache_dir,
      healthcheck_timeout: 1,
      connection: health_conn,
      **overrides
    )
    built << server
    server
  end

  describe '#initialize / accessors' do
    it 'exposes endpoint from the port' do
      assert_equal 'http://localhost:8888', build_server.endpoint
      assert_equal 'http://localhost:9000', build_server(port: 9000).endpoint
    end

    it 'roots the checkout under <cache>/temp/git and data under <cache>/data' do
      server = build_server
      assert_equal File.join(cache_dir, 'temp', 'git'), server.checkout_dir.to_s
      assert_equal File.join(cache_dir, 'data'), server.data_dir.to_s
    end

    it 'derives a default cache dir under XDG_CACHE_HOME / pikuri / mem0' do
      assert_match(%r{/pikuri/mem0\z}, build_server.default_cache_dir)
    end
  end

  describe '#client' do
    it 'returns a Mem0Client pointed at this server' do
      client = build_server(port: 9876).client
      assert_kind_of Pikuri::Memory::Mem0Client, client
      assert_equal 'http://localhost:9876', client.endpoint
    end
  end

  describe '#ensure_running!' do
    it 'clones+patches a fresh checkout, brings the stack up, then heartbeats' do
      planned.replace([
                        [0, ''],   # git init
                        [0, ''],   # git remote add origin
                        [0, ''],   # git fetch --depth 1 origin <ref>
                        [0, ''],   # git checkout --detach FETCH_HEAD
                        [1, ''],   # git apply --reverse --check -> not yet applied
                        [0, ''],   # git apply <patch>
                        [0, '']    # docker compose up -d --build
                      ])
      health_stubs.get('/docs') { [200, {}, 'ok'] }

      build_server.ensure_running!

      argvs = calls.map { |c| c[:argv] }
      assert(argvs.any? { |a| a[0] == 'git' && a[1] == 'fetch' })
      assert(argvs.any? { |a| a[0] == 'git' && a[1] == 'apply' && a.last.end_with?('.patch') })
      up = argvs.find { |a| a[0] == 'docker' && a.include?('up') }
      refute_nil up
      assert_equal %w[docker compose -p pikuri-internal-mem0 -f], up[0, 5]
      assert_equal %w[up -d --build], up.last(3)
    end

    it 'passes the checkout path + router/model wiring as compose env' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [0, '']])
      health_stubs.get('/docs') { [200, {}, 'ok'] }

      build_server.ensure_running!

      up = calls.find { |c| c[:argv].include?('up') }
      env = up[:env]
      assert_equal File.join(cache_dir, 'temp', 'git'), env['PIKURI_MEM0_SRC']
      assert_equal File.join(cache_dir, 'data'), env['PIKURI_DATA_DIR']
      assert_equal 'http://router:8080/v1', env['PIKURI_ROUTER_URL']
      assert_equal 'qwen2.5-7b', env['PIKURI_LLM_MODEL']
      assert_equal 'nomic', env['PIKURI_EMBEDDER_MODEL']
      assert_equal '768', env['PIKURI_EMBEDDING_DIMS']
    end

    it 'skips cloning when the checkout is already at the pinned ref' do
      FileUtils.mkdir_p(File.join(cache_dir, 'temp', 'git', '.git'))
      planned.replace([
                        [0, Pikuri::Memory::Mem0Server::MEM0_REF], # git rev-parse HEAD
                        [0, ''],                                   # git apply --reverse --check -> already applied
                        [0, '']                                    # docker compose up
                      ])
      health_stubs.get('/docs') { [200, {}, 'ok'] }

      build_server.ensure_running!

      argvs = calls.map { |c| c[:argv] }
      refute(argvs.any? { |a| a[0] == 'git' && a[1] == 'fetch' }, 'should not re-fetch an up-to-date checkout')
      assert(argvs.any? { |a| a[0] == 'docker' && a.include?('up') })
    end

    it 'raises fail-loud when the patch neither applies nor is present' do
      planned.replace([
                        [0, ''], [0, ''], [0, ''], [0, ''], # clone steps
                        [1, ''],                            # reverse --check -> not applied
                        [1, 'patch does not apply']         # git apply -> fails
                      ])

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/failed to apply/, err.message)
    end

    it 'raises on healthcheck timeout' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [0, '']])
      health_stubs.get('/docs') { [503, {}, 'starting'] }

      err = assert_raises(RuntimeError) { build_server.ensure_running! }
      assert_match(/did not become healthy/, err.message)
    end
  end

  describe '#close' do
    it 'runs docker compose down and is idempotent' do
      planned.replace([[0, ''], [0, ''], [0, ''], [0, ''], [1, ''], [0, ''], [0, '']])
      health_stubs.get('/docs') { [200, {}, 'ok'] }
      server = build_server
      server.ensure_running!

      planned.replace([[0, '']]) # docker compose down
      server.close
      server.close # no second down

      downs = calls.select { |c| c[:argv].include?('down') }
      assert_equal 1, downs.size
      assert_equal %w[docker compose], downs.first[:argv][0, 2]
    end
  end
end
