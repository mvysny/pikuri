# frozen_string_literal: true

require 'agent'

RSpec.describe Agent::Listener::StepLimit do
  let(:fake_chat_class) do
    Class.new do
      attr_reader :listeners

      def initialize
        @listeners = []
      end

      def before_tool_call(&b)
        @listeners << b
      end

      def fire
        @listeners.each { |cb| cb.call(nil) }
      end
    end
  end

  let(:fake_chat) { fake_chat_class.new }

  describe '#initialize' do
    it 'rejects non-positive max' do
      assert_raises(ArgumentError) { described_class.new(max: 0) }
      assert_raises(ArgumentError) { described_class.new(max: -1) }
    end
  end

  describe '#attach' do
    it 'wires a single before_tool_call callback' do
      described_class.new(max: 3).attach(fake_chat)

      assert_equal 1, fake_chat.listeners.size
    end
  end

  describe 'counting' do
    it 'raises Exceeded once tool-call count exceeds max' do
      described_class.new(max: 2).attach(fake_chat)

      fake_chat.fire
      fake_chat.fire

      err = assert_raises(described_class::Exceeded) { fake_chat.fire }
      assert_equal 2, err.max_steps
      assert_includes err.message, 'exceeded 2 steps'
    end

    it 'resets the counter on Message::User so a fresh turn can spend the budget again' do
      limiter = described_class.new(max: 1)
      limiter.attach(fake_chat)

      fake_chat.fire
      assert_raises(described_class::Exceeded) { fake_chat.fire }

      limiter.on_message(Agent::Message::User.new(content: 'next turn'))

      fake_chat.fire # budget refreshed; first call after reset succeeds
      assert_raises(described_class::Exceeded) { fake_chat.fire }
    end

    it 'ignores non-User messages' do
      limiter = described_class.new(max: 1)
      limiter.attach(fake_chat)
      fake_chat.fire # uses the one allowed call

      # These should NOT reset the budget.
      limiter.on_message(Agent::Message::Assistant.new(content: 'hi'))
      limiter.on_message(Agent::Message::ToolCall.new(name: 'echo', arguments: {}))
      limiter.on_message(Agent::Message::ToolResult.new(content: 'done'))
      limiter.on_message(Agent::Message::Thinking.new(content: 'pondering'))

      assert_raises(described_class::Exceeded) { fake_chat.fire }
    end
  end

  describe '#for_sub_agent' do
    it 'returns a fresh StepLimit at the caller-supplied max_steps' do
      original = described_class.new(max: 99)
      derived  = original.for_sub_agent(max_steps: 5)

      refute_same original, derived
      assert_equal 'StepLimit(max=5)', derived.to_s
    end

    it 'ignores unrelated params forwarded by ListenerList#for_sub_agent' do
      derived = described_class.new(max: 99).for_sub_agent(max_steps: 4, anything_else: :nope)
      assert_equal 'StepLimit(max=4)', derived.to_s
    end

    it 'defaults max_steps to the receiver\'s own cap when the key is absent' do
      derived = described_class.new(max: 99).for_sub_agent
      assert_equal 'StepLimit(max=99)', derived.to_s
    end

    it 'rejects non-positive max_steps via StepLimit#initialize' do
      assert_raises(ArgumentError) { described_class.new(max: 99).for_sub_agent(max_steps: 0) }
    end

    it 'does not share its mutable counter with the parent' do
      parent = described_class.new(max: 4)
      parent_chat = fake_chat_class.new
      parent.attach(parent_chat)

      derived = parent.for_sub_agent(max_steps: 4)
      derived_chat = fake_chat_class.new
      derived.attach(derived_chat)

      # Burn 3 calls on the parent (under its cap).
      3.times { parent_chat.fire }

      # The derived chat hasn't seen any tool calls yet, so 3 must land
      # without raising — they would already trip if the counter were shared.
      3.times { derived_chat.fire }
    end
  end

  describe '#to_s' do
    it 'renders the configured cap' do
      assert_equal 'StepLimit(max=20)', described_class.new(max: 20).to_s
    end
  end
end
