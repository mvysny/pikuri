# frozen_string_literal: true

RSpec.describe Pikuri::Agent::RequestThrottle do
  after { Pikuri::Agent::ServerPermits.reset! }

  let(:permits) { Pikuri::Agent::ServerPermits }
  let(:base) { 'http://x:8080/v1' }
  let(:cancelled) { Pikuri::Agent::Control::Cancellable::Cancelled }

  # Records every event it is handed and yields, like the instrumenter a Rails
  # host installs.
  let(:recorder_class) do
    Class.new do
      attr_reader :events

      def initialize
        @events = []
      end

      def instrument(name, payload = nil)
        @events << [name, payload]
        block_given? ? yield : nil
      end
    end
  end

  def throttle(key: base, cancellable: nil, chain: nil)
    described_class.new(key: key, cancellable: cancellable, chain: chain)
  end

  it 'returns the block value, gated event or not' do
    permits.limit(base, 1)
    gate = throttle

    assert_equal :a, gate.instrument('request.ruby_llm', { url: '/chat/completions' }) { :a }
    assert_equal :b, gate.instrument('chat.ruby_llm', {}) { :b }
  end

  it 'holds one permit per request.ruby_llm block' do
    permits.limit(base, 2)
    gate = throttle
    lock = Mutex.new
    in_flight = 0
    peak = 0

    6.times.map do
      Thread.new do
        gate.instrument('request.ruby_llm', {}) do
          lock.synchronize { in_flight += 1; peak = [peak, in_flight].max }
          sleep 0.02
          lock.synchronize { in_flight -= 1 }
        end
      end
    end.each(&:join)

    assert_equal 2, peak
  end

  # The deadlock the design turns on: chat.ruby_llm wraps ruby_llm's whole
  # recursive loop — tool calls, and therefore a sub-agent's own requests,
  # included. Gating it under one permit would park the child forever behind
  # its parent.
  it 'leaves every other event ungated, so a nested request still gets a permit' do
    permits.limit(base, 1)
    gate = throttle
    inner = nil

    gate.instrument('chat.ruby_llm', {}) do
      gate.instrument('request.ruby_llm', {}) { nil }
      # ... the parent's tool runs here, and spawns a child agent:
      gate.instrument('chat.ruby_llm', {}) do
        inner = gate.instrument('request.ruby_llm', {}) { :child_completed }
      end
    end

    assert_equal :child_completed, inner
  end

  it 'raises Cancelled rather than sending a request parked behind a permit' do
    permits.limit(base, 1)
    cancellable = Pikuri::Agent::Control::Cancellable.new
    gate = throttle(cancellable: cancellable)
    sent = []
    hold = Queue.new

    holder = Thread.new { gate.instrument('request.ruby_llm', {}) { hold.pop } }
    sleep 0.005 while permits.for(base).available.positive?

    waiter = Thread.new do
      gate.instrument('request.ruby_llm', {}) { sent << :sent }
    rescue cancelled
      :cancelled
    end
    cancellable.cancel!

    # Cut short mid-wait, while the holder still holds — and nothing was sent.
    assert_equal :cancelled, waiter.value
    assert_equal [], sent

    hold << :go
    holder.join
  end

  describe 'chaining an inherited instrumenter' do
    it 'delegates every event, so a host instrumenter is not clobbered' do
      permits.limit(base, 1)
      chain = recorder_class.new
      gate = throttle(chain: chain)

      assert_equal :ok, gate.instrument('request.ruby_llm', { url: '/x' }) { :ok }
      gate.instrument('tool_call.ruby_llm', { tool_call: 'read' }) { nil }

      assert_equal [['request.ruby_llm', { url: '/x' }], ['tool_call.ruby_llm', { tool_call: 'read' }]],
                   chain.events
    end

    it 'forwards a blockless call and answers nil with no chain' do
      chain = recorder_class.new

      assert_nil throttle(chain: chain).instrument('request.ruby_llm', { url: '/x' })
      assert_equal [['request.ruby_llm', { url: '/x' }]], chain.events
      assert_nil throttle.instrument('request.ruby_llm', { url: '/x' })
    end

    it 'drops a chain that does not answer #instrument, as ruby_llm does' do
      gate = throttle(chain: Object.new)

      assert_equal :ok, gate.instrument('request.ruby_llm', {}) { :ok }
    end
  end

  describe 'an unsized or unkeyed server' do
    it 'passes straight through' do
      gate = throttle(key: nil)
      lock = Mutex.new
      in_flight = 0
      peak = 0

      3.times.map do
        Thread.new do
          gate.instrument('request.ruby_llm', {}) do
            lock.synchronize { in_flight += 1; peak = [peak, in_flight].max }
            sleep 0.02
            lock.synchronize { in_flight -= 1 }
          end
        end
      end.each(&:join)

      assert_equal 3, peak
      assert_equal 'RequestThrottle(unlimited: unlimited)', gate.to_s
    end

    it 'picks up a limit set after the agent was built' do
      gate = throttle
      assert_same Pikuri::Agent::ServerPermits::UNLIMITED, Pikuri::Agent::ServerPermits.for(base)

      permits.limit(base, 1)

      assert_equal 'RequestThrottle(http://x:8080/v1: 1/1 permits)', gate.to_s
    end
  end
end
