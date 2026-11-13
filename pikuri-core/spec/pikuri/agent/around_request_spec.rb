# frozen_string_literal: true

require 'timeout'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# The +around_request:+ hook rides ruby_llm's +instrumenter+ slot and the
# scripted fake its +faraday_adapter+ one, so a REAL Agent + REAL ruby_llm loop
# runs against canned HTTP with a hook in force. The hook here is a spec-local
# counting semaphore — the throttle a host would hang on the seam.
RSpec.describe 'Agent around_request' do
  let(:server) { 'http://throttled.invalid/v1' }

  # A cancellable counting semaphore, keyed on nothing: every agent here dials
  # one server.
  let(:permits_class) do
    Class.new do
      attr_reader :calls

      def initialize(permits)
        @available = permits
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @calls = []
      end

      def call(api_base, cancellable)
        @mutex.synchronize do
          @calls << [api_base, cancellable]
          loop do
            cancellable&.check!
            break if @available.positive?

            @cv.wait(@mutex, 0.01)
          end
          @available -= 1
        end
        begin
          yield
        ensure
          @mutex.synchronize { @available += 1; @cv.broadcast }
        end
      end
    end
  end

  # Counts how many requests are inside the HTTP call at once. +Gate#await+
  # runs inside the adapter's +#call+, hence inside the +request.ruby_llm+
  # block — so this measures exactly what the hook brackets.
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

  def transport(gate: nil, api_base: server, **kwargs)
    Pikuri::Testing.fake_transport(api_base: api_base, gate: gate, **kwargs) do |llm|
      llm.reply('done')
    end
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.005 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert yield, 'condition never became true'
  end

  it 'brackets every HTTP request, handed the dialed base and the cancellable' do
    hook = permits_class.new(1)
    cancel = Pikuri::Agent::Control::Cancellable.new
    two_requests = Pikuri::Testing.fake_transport(api_base: server) do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('4')
    end
    agent = Pikuri::Agent.new(transport: two_requests, system_prompt: 's',
                              cancellable: cancel, around_request: hook) do |c|
      c.add_tool Pikuri::Tool::CALCULATOR
    end

    agent.run_loop(user_message: '2 + 2?')

    assert_equal [[server, cancel]] * 2, hook.calls
  ensure
    agent&.close
  end

  it 'keeps in-flight requests at or below what the hook allows across four agents' do
    hook = permits_class.new(2)
    gate = counting_gate_class.new
    gate.block!
    agents = Array.new(4) do
      Pikuri::Agent.new(transport: transport(gate: gate), system_prompt: 's', around_request: hook)
    end

    workers = agents.map { |a| Thread.new { a.run_loop(user_message: 'hi') } }
    # Two requests reach the wire and park in the adapter; the other two are
    # parked in the hook, so they never arrive.
    wait_until { gate.in_flight == 2 }
    sleep 0.1
    assert_equal 2, gate.in_flight, 'a third request got past the hook'

    gate.release!
    workers.each { |w| w.join(10) or raise 'a turn never finished' }

    assert_equal 2, gate.peak
    assert_equal ['done'] * 4, agents.map(&:last_assistant_content)
  ensure
    gate&.release!
    agents&.each(&:close)
  end

  # On the agent, not the transport, so a switch keeps it — and the hook
  # learns the new server per call.
  it 'survives a model switch, handed the new server' do
    hook = permits_class.new(1)
    other = 'http://other.invalid/v1'
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 's', around_request: hook)

    agent.run_loop(user_message: 'a')
    agent.run_loop(user_message: 'b', transport: transport(api_base: other, model: 'other-model'))

    assert_equal [server, other], hook.calls.map(&:first)
  ensure
    agent&.close
  end

  # Return, then Escape: a cancel sent before run_loop costs no prefill — and
  # with no hook to check the token, run_loop's own check has to catch it.
  it 'ends a turn cancelled before run_loop before any request is served' do
    gate = counting_gate_class.new
    cancel = Pikuri::Agent::Control::Cancellable.new
    built = Pikuri::Agent.new(transport: transport(gate: gate), system_prompt: 's', cancellable: cancel)

    cancel.cancel!
    assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
      built.run_loop(user_message: 'wrong question')
    end
    assert_equal 0, gate.peak

    # The scripted reply is still unserved: the next armed turn gets it.
    cancel.reset!
    built.run_loop(user_message: 'right question')
    assert_equal 'done', built.last_assistant_content
  ensure
    built&.close
  end

  # The invariant a later "why not wrap the whole turn?" tidy-up would break:
  # the hook brackets one HTTP request precisely so a parent holds nothing
  # while its tool runs, and the sub-agent that tool spawns gets a permit of its
  # own. Under one permit, a whole-turn bracket deadlocks here.
  it 'completes a parent whose tool spawns a sub-agent under a single permit' do
    hook = permits_class.new(1)
    child = Pikuri::Agent.new(transport: transport, system_prompt: 'child', around_request: hook)
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
    parent = Pikuri::Agent.new(transport: parent_transport, system_prompt: 'parent', around_request: hook) do |c|
      c.add_tool spawner
    end

    Timeout.timeout(15) { parent.run_loop(user_message: 'delegate') }

    assert_equal 'done', child.last_assistant_content
    assert_equal 'child said: done', parent.last_assistant_content
    assert_equal 3, hook.calls.size
  ensure
    parent&.close
    child&.close
  end
end
