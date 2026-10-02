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
    # probe's own HTTP is exercised in context_window_detector_spec. Counts its
    # calls, because half of what this section asserts is a probe *not* paid —
    # +n_ctx: nil, total_slots: nil+ is the failed probe, equal to Props::NONE.
    def stub_props(n_ctx: 16_384, total_slots: 4)
      probes = @probes = []
      props = Pikuri::Agent::ContextWindowDetector::Props.new(n_ctx: n_ctx, total_slots: total_slots)
      @original_detect = Pikuri::Agent::ContextWindowDetector.method(:detect)
      # A local, not @probes: the block's self is the detector class.
      Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect) do |probed, **_|
        probes << probed.model
        props
      end
    end

    def probe_count
      @probes.length
    end

    # The probe waits for the first turn, so every agent here is served one.
    def served(transport)
      agent(transport).tap { |a| a.run_loop(user_message: 'hi') }
    end

    it 'probes nothing at construction' do
      stub_props
      built = agent(transport(context_window: nil))

      assert_equal 0, probe_count
      assert_nil built.context_window_cap
      refute permits.sized?(server)
    ensure
      built&.close
    end

    # The reason the probe waits: against a router, /props?model=<id> loads that
    # model, and a host switching before its first turn would load one for nothing.
    it 'probes only the model switched to before the first turn' do
      stub_props
      built = agent(transport(model: 'boot-model', context_window: nil))
      built.run_loop(user_message: 'hi', transport: transport(model: 'chosen-model', context_window: nil))

      assert_equal ['chosen-model'], @probes
      assert_equal 16_384, built.context_window_cap
    ensure
      built&.close
    end

    after do
      next unless @original_detect

      Pikuri::Agent::ContextWindowDetector.define_singleton_method(:detect, @original_detect)
    end

    it 'seeds the permit size and the context cap from one probe' do
      stub_props
      # context_window: nil is what leaves the probe to run.
      built = served(transport(context_window: nil))

      assert_equal 16_384, built.context_window_cap
      assert_equal 4, permits.for(server).permits
    ensure
      built&.close
    end

    it 'leaves a host-set limit alone' do
      stub_props
      permits.limit(server, 1)
      built = served(transport(context_window: nil))

      assert_equal 1, permits.for(server).permits
    ensure
      built&.close
    end

    # The two facts in one document are independent: the cap the host stated
    # wins over the probed n_ctx and says nothing about the server's slots.
    it 'sizes the server even when the transport carries an explicit cap' do
      stub_props
      built = served(transport(context_window: 8192))

      assert_equal 8192, built.context_window_cap
      assert_equal 4, permits.for(server).permits
      assert_equal 1, probe_count
    ensure
      built&.close
    end

    it 'skips the probe when the cap is stated and the server is already sized' do
      stub_props
      permits.limit(server, 2)
      built = served(transport(context_window: 8192))

      assert_equal 8192, built.context_window_cap
      assert_equal 2, permits.for(server).permits
      assert_equal 0, probe_count, 'nothing left to learn, and it asked anyway'
    ensure
      built&.close
    end

    it 'probes a shared server once across capped agents — the registry is the memo' do
      stub_props
      built = Array.new(3) { served(transport(context_window: 8192)) }

      assert_equal 4, permits.for(server).permits
      assert_equal 1, probe_count
    ensure
      built&.each(&:close)
    end

    # The deliberate boundary: n_ctx is a live reading (restart llama-server
    # with a different -c and the next agent sees it), so an agent that needs
    # one always probes. Only the slot count is remembered.
    it 'still probes per agent when no cap is stated' do
      stub_props
      built = Array.new(3) { served(transport(context_window: nil)) }

      assert_equal [16_384] * 3, built.map(&:context_window_cap)
      assert_equal 3, probe_count
    ensure
      built&.each(&:close)
    end

    # The shape SubAgentTool spawns with: the parent's resolved cap rides the
    # transport, and the parent's probe already sized the server.
    it 'costs a sub-agent spawn no probe of its own' do
      stub_props
      parent = served(transport(context_window: nil))
      # A fresh script on the same server: the parent's own one is spent.
      child = served(transport(context_window: parent.context_window_cap))

      assert_equal 16_384, child.context_window_cap
      assert_equal 4, permits.for(server).permits
      assert_equal 1, probe_count
    ensure
      parent&.close
      child&.close
    end

    # "Answered, no slots" is an old llama.cpp, and it will not start reporting
    # one while it runs — so it is recorded as unlimited rather than re-asked.
    it 'records an answer that carried no slot count' do
      stub_props(n_ctx: 8192, total_slots: nil)
      first = served(transport(context_window: 4096))
      second = served(transport(context_window: 4096))

      assert_same permits::UNLIMITED, permits.for(server)
      assert_equal({ permits.key_for(server) => nil }, permits.sizes)
      assert_equal 1, probe_count
      assert_equal 4096, second.context_window_cap
    ensure
      first&.close
      second&.close
    end

    # A failure is not an answer: a server that was merely booting when the
    # first agent asked gets asked again.
    it 'asks again after a probe that failed' do
      stub_props(n_ctx: nil, total_slots: nil)
      built = Array.new(2) { served(transport(context_window: 4096)) }

      assert_equal({}, permits.sizes)
      assert_equal 2, probe_count
    ensure
      built&.each(&:close)
    end
  end
end
