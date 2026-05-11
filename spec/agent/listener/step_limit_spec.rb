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

  describe '#to_s' do
    it 'renders the configured cap' do
      assert_equal 'StepLimit(max=20)', described_class.new(max: 20).to_s
    end
  end
end
