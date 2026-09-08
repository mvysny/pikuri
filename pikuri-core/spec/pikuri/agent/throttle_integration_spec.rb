# frozen_string_literal: true

require 'timeout'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# What the Faraday-adapter approach could not test: the throttle and the
# scripted fake adapter coexist (the throttle rides the +instrumenter+ slot,
# the fake the +faraday_adapter+ one), so a REAL Agent + REAL ruby_llm loop can
# be run against canned HTTP with permits in force.
RSpec.describe 'Agent request throttling' do
  after { Pikuri::Agent::ServerPermits.reset! }

  let(:permits) { Pikuri::Agent::ServerPermits }
  # One server for every agent here, so they share one permit queue.
  let(:server) { 'http://throttled.invalid/v1' }

  # Counts how many requests are inside the HTTP call at once. +Gate#await+
  # runs inside the adapter's +#call+, hence inside the +request.ruby_llm+
  # block — so this measures exactly what the permit is supposed to bound.
  let(:counting_gate_class) do
    Class.new(Pikuri::Testing::Gate) do
      attr_reader :peak, :in_flight

      def initialize
        super
        @counter = Mutex.new
        @in_flight = 0
        @peak = 0
      end

      def await
        @counter.synchronize { @in_flight += 1; @peak = [@peak, @in_flight].max }
        super
      ensure
        @counter.synchronize { @in_flight -= 1 }
      end
    end
  end

  def transport(gate: nil, **kwargs)
    Pikuri::Testing.fake_transport(api_base: server, gate: gate, **kwargs) do |llm|
      llm.reply('done')
    end
  end

  def agent(transport)
    Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, 'condition never became true'
  end

  it 'keeps in-flight requests at or below the limit across four agents' do
    permits.limit(server, 2)
    gate = counting_gate_class.new
    gate.block!
    agents = Array.new(4) { agent(transport(gate: gate)) }

    workers = agents.map { |a| Thread.new { a.run_loop(user_message: 'hi') } }
    # Two requests reach the wire and park in the adapter; the other two are
    # parked on a permit, so they never arrive.
    wait_until { gate.in_flight == 2 }
    sleep 0.1
    assert_equal 2, gate.in_flight, 'a third request got past the permits'
    assert workers.all?(&:alive?)

    gate.release!
    workers.each { |w| w.join(10) or raise 'a turn never finished' }

    assert_equal 2, gate.peak
    assert_equal ['done'] * 4, agents.map(&:last_assistant_content)
  ensure
    gate&.release!
    agents&.each(&:close)
  end

  it 'lets all four fly when the server is unsized' do
    gate = counting_gate_class.new
    gate.block!
    agents = Array.new(4) { agent(transport(gate: gate)) }

    workers = agents.map { |a| Thread.new { a.run_loop(user_message: 'hi') } }
    wait_until { gate.in_flight == 4 }

    gate.release!
    workers.each { |w| w.join(10) or raise 'a turn never finished' }

    assert_equal 4, gate.peak
  ensure
    gate&.release!
    agents&.each(&:close)
  end

  # The invariant a later "why not acquire once per turn?" tidy-up would break:
  # a permit is scoped to one HTTP request precisely so a parent holds nothing
  # while its tool runs, and the sub-agent that tool spawns can get a permit of
  # its own. Under one permit, a whole-turn acquire deadlocks here.
  it 'completes a parent whose tool spawns a sub-agent under a single permit' do
    permits.limit(server, 1)
    child = agent(transport)
    spawner = Pikuri::Tool.new(
      name: 'spawn', description: 'run the child agent',
      parameters: Pikuri::Tool::Parameters::EMPTY,
      execute: lambda {
        child.run_loop(user_message: 'go')
        child.last_assistant_content
      }
    )
    parent_transport = Pikuri::Testing.fake_transport(api_base: server) do |llm|
      llm.tool_call('spawn')
      llm.reply('child said: done')
    end
    parent = Pikuri::Agent.new(transport: parent_transport, system_prompt: 'parent') do |c|
      c.add_tool spawner
    end

    Timeout.timeout(15) { parent.run_loop(user_message: 'delegate') }

    assert_equal 'done', child.last_assistant_content
    assert_equal 'child said: done', parent.last_assistant_content
  ensure
    parent&.close
    child&.close
  end

  describe 'sizing from the /props probe' do
    # Stand in for a llama.cpp answering /props with a slot count; the real
    # probe's own HTTP is exercised in context_window_detector_spec.
    def stub_props(n_ctx: 16_384, total_slots: 4)
      @original_detect = Pikuri::Agent::ContextWindowDetector.method(:detect)
      props = Pikuri::Agent::ContextWindowDetector::Props.new(n_ctx: n_ctx, total_slots: total_slots)
      Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect) { |*_, **_| props }
    end

    after do
      next unless @original_detect

      Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect, @original_detect)
    end

    it 'seeds the permit size and the context cap from one probe' do
      stub_props
      # context_window: nil is what leaves the probe to run.
      built = agent(transport(context_window: nil))

      assert_equal 16_384, built.context_window_cap
      assert_equal 4, permits.for(server).permits
    ensure
      built&.close
    end

    it 'leaves a host-set limit alone' do
      stub_props
      permits.limit(server, 1)
      built = agent(transport(context_window: nil))

      assert_equal 1, permits.for(server).permits
    ensure
      built&.close
    end

    it 'does not size the server when the transport carries an explicit cap' do
      stub_props
      built = agent(transport(context_window: 8192))

      assert_equal 8192, built.context_window_cap
      assert_equal({}, permits.sizes)
    ensure
      built&.close
    end
  end
end
