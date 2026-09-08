# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Listener::RateLimited do
  let(:inner) { Pikuri::Agent::Listener::InMemoryEventList.new }
  let(:clock_time) { [0.0] }
  let(:clock) { -> { clock_time[0] } }
  let(:listener) { described_class.new(inner, fps: 10, clock: clock) }

  def advance(seconds)
    clock_time[0] += seconds
  end

  describe 'coalescing AssistantDelta within a period' do
    it 'flushes the very first delta immediately (construction-time tick has already passed)' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'hello'))
      assert_equal [Pikuri::Agent::Event::AssistantDelta.new(content: 'hello')], inner.events
    end

    it 'buffers further deltas within the same period without emitting' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'hel'))
      advance(0.05)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'lo'))
      advance(0.02)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '!'))

      # Only the first delta has been flushed; "lo!" is still buffered.
      assert_equal 1, inner.events.size
      assert_equal 'hel', inner.events.first.content
    end

    it 'coalesces buffered deltas into a single event on the next tick' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'hel'))
      advance(0.05)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'lo'))
      advance(0.06) # crosses the 0.1 boundary
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: '!'))

      contents = inner.events.map(&:content)
      assert_equal %w[hel lo!], contents
    end
  end

  describe 'per-stream buffering' do
    it 'keeps assistant and thinking buffers independent and emits them as separate events' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'T1'))
      advance(0.02)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A2'))
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'T2'))
      advance(0.1) # crosses the next tick
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A3'))

      # 'A1' flushes at the construction tick; 'T1' was first to arrive
      # after that flush and stays buffered, joining 'T2' before the next
      # tick. 'A2' was also buffered; on the next tick the thinking and
      # assistant buffers drain independently.
      assistant = inner.events.grep(Pikuri::Agent::Event::AssistantDelta).map(&:content)
      thinking  = inner.events.grep(Pikuri::Agent::Event::ThinkingDelta).map(&:content)
      assert_equal %w[A1 A2A3], assistant
      assert_equal %w[T1T2], thinking
    end
  end

  describe 'tick alignment (no startup-latency drift)' do
    # With fps: 1 the tick schedule is anchored to construction time
    # (clock_time[0] = 0.0). A delta arriving after a long startup gap
    # should flush immediately (the 0.0 tick already passed), and the
    # schedule for subsequent flushes is "every 1.0 after that
    # boundary," not "1.0 after the first delta."
    let(:listener) { described_class.new(inner, fps: 1, clock: clock) }

    it 'flushes the first delta immediately even after a long startup idle' do
      advance(5.0)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'go'))
      assert_equal [Pikuri::Agent::Event::AssistantDelta.new(content: 'go')], inner.events
    end

    it 'preserves the configured rate after a long pause (catches up past missed ticks)' do
      advance(5.0)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'a'))
      # The catch-up advanced the next-tick boundary to t=6.0; further
      # deltas in (5.0, 6.0) must stay buffered.
      advance(0.5)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'b'))
      advance(0.4)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'c'))

      assert_equal 1, inner.events.size
      assert_equal 'a', inner.events.first.content
    end
  end

  describe 'flush_pending_on_non_delta: true (default)' do
    it 'emits pending coalesced content before the non-delta event flows through' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A2'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'final'))

      types = inner.events.map(&:class)
      contents = inner.events.map(&:content)
      assert_equal [
        Pikuri::Agent::Event::AssistantDelta,
        Pikuri::Agent::Event::AssistantDelta,
        Pikuri::Agent::Event::Assistant
      ], types
      assert_equal %w[A1 A2 final], contents
    end

    it 'drains thinking buffer before assistant buffer before forwarding the non-delta event' do
      # Cross a tick boundary first so internal state is clean; then buffer
      # one delta per stream within the next period — the non-delta event
      # must drain both in order (thinking, then assistant).
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'T1'))
      advance(0.2)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A2'))
      # Both buffers now empty. Stay inside the next period.
      listener.on_event(Pikuri::Agent::Event::ThinkingDelta.new(content: 'T2'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A3'))
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: 'do', arguments: {},
                                                     display_name: 'Do', argument: ''))

      tail = inner.events.last(3)
      assert_kind_of Pikuri::Agent::Event::ThinkingDelta, tail[0]
      assert_equal 'T2', tail[0].content
      assert_kind_of Pikuri::Agent::Event::AssistantDelta, tail[1]
      assert_equal 'A3', tail[1].content
      assert_kind_of Pikuri::Agent::Event::ToolCall, tail[2]
    end

    it 'does not emit empty-buffer deltas before the non-delta event' do
      listener.on_event(Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: 'echo', arguments: {},
                                                           display_name: 'Echo', argument: ''))
      assert_equal 1, inner.events.size
      assert_kind_of Pikuri::Agent::Event::ToolCall, inner.events.first
    end
  end

  describe 'flush_pending_on_non_delta: false' do
    let(:listener) do
      described_class.new(inner, fps: 10, flush_pending_on_non_delta: false, clock: clock)
    end

    it 'drops pending coalesced content silently' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      # 'A2' buffered inside the same period.
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A2'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'final'))

      # 'A1' flushed at construction tick; 'A2' was buffered and dropped.
      contents = inner.events.map(&:content)
      assert_equal %w[A1 final], contents
    end

    it 'still forwards the non-delta event' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'final'))

      assert_kind_of Pikuri::Agent::Event::Assistant, inner.events.last
      assert_equal 'final', inner.events.last.content
    end

    it 'clears the buffer so the next stream starts fresh' do
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A1'))
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'A2-dropped'))
      listener.on_event(Pikuri::Agent::Event::Assistant.new(content: 'first'))
      # New stream begins; advance past the tick boundary so the first
      # delta of the new stream flushes through cleanly.
      advance(0.2)
      listener.on_event(Pikuri::Agent::Event::AssistantDelta.new(content: 'B1'))

      # 'A2-dropped' must NOT prefix 'B1'.
      assistant_deltas = inner.events.grep(Pikuri::Agent::Event::AssistantDelta).map(&:content)
      assert_equal %w[A1 B1], assistant_deltas
    end
  end

  describe 'pass-through of non-delta events' do
    [
      Pikuri::Agent::Event::UserTurn.new(content: 'hi'),
      Pikuri::Agent::Event::Thinking.new(content: 'pondered'),
      Pikuri::Agent::Event::Assistant.new(content: 'reply'),
      Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: 'echo', arguments: { 'text' => 'hi' },
                                         display_name: 'Echo', argument: 'hi'),
      Pikuri::Agent::Event::ToolResult.new(tool_call_id: 'c1', name: 'echo', content: 'done',
                                           summary: 'Returned 4 bytes'),
      Pikuri::Agent::Event::Cancelled.new,
      Pikuri::Agent::Event::ContextCap.new(cap: 32_768),
      Pikuri::Agent::Event::Tokens.new(input: 1, output: 1, cached: nil,
                                       cache_creation: nil, thinking: nil, model_id: nil)
    ].each do |event|
      it "forwards #{event.class.name.split('::').last} unchanged" do
        listener.on_event(event)
        assert_equal [event], inner.events
      end
    end
  end

  describe '#for_sub_agent' do
    it 'wraps the inner listener\'s sub-agent variant in a fresh RateLimited' do
      inner_terminal = Pikuri::Agent::Listener::Terminal.new
      wrapped = described_class.new(inner_terminal, fps: 10, clock: clock)
      derived = wrapped.for_sub_agent

      assert_kind_of described_class, derived
      refute_same wrapped, derived
    end

    it 'preserves the fps and policy on the sub-agent variant' do
      inner_terminal = Pikuri::Agent::Listener::Terminal.new
      wrapped = described_class.new(inner_terminal, fps: 7, flush_pending_on_non_delta: false, clock: clock)
      derived = wrapped.for_sub_agent

      assert_match(/7fps/, derived.to_s)
      assert_match(/drop/, derived.to_s)
    end

    it 'falls back to wrapping the inner listener as-is when it does not define for_sub_agent' do
      # InMemoryEventList has no for_sub_agent — wrapper must still
      # produce a usable RateLimited (keeping the parent listener
      # reachable from the sub-agent's stream).
      derived = listener.for_sub_agent
      assert_kind_of described_class, derived
    end

    it 'returns nil when the inner listener\'s for_sub_agent returned nil' do
      stub_inner = Object.new
      stub_inner.define_singleton_method(:for_sub_agent) { |**| nil }
      stub_inner.define_singleton_method(:on_event) { |_event| }
      wrapped = described_class.new(stub_inner, fps: 10, clock: clock)

      assert_nil wrapped.for_sub_agent
    end
  end

  describe '#to_s' do
    it 'embeds the fps, policy, and inner listener label' do
      assert_equal 'RateLimited(10fps, flush, InMemoryEventList)', listener.to_s
    end

    it 'renders the drop policy when flush_pending_on_non_delta is false' do
      drop_listener = described_class.new(inner, fps: 15, flush_pending_on_non_delta: false, clock: clock)
      assert_equal 'RateLimited(15fps, drop, InMemoryEventList)', drop_listener.to_s
    end
  end

  describe 'argument validation' do
    it 'raises ArgumentError on non-positive fps' do
      assert_raises(ArgumentError) { described_class.new(inner, fps: 0, clock: clock) }
      assert_raises(ArgumentError) { described_class.new(inner, fps: -1, clock: clock) }
    end
  end
end
