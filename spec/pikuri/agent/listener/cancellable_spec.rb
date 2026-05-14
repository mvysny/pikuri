# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Listener::Cancellable do
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
    it 'starts in the armed (not-cancelled) state' do
      refute described_class.new.cancelled?
    end
  end

  describe '#attach' do
    it 'wires a single before_tool_call callback' do
      described_class.new.attach(fake_chat)

      assert_equal 1, fake_chat.listeners.size
    end
  end

  describe '#cancel!' do
    it 'flips the flag observable via #cancelled?' do
      flag = described_class.new
      flag.cancel!
      assert flag.cancelled?
    end

    it 'is idempotent — repeated calls are safe' do
      flag = described_class.new
      flag.cancel!
      flag.cancel!
      assert flag.cancelled?
    end
  end

  describe 'cancellation' do
    it 'does not raise on before_tool_call while armed' do
      described_class.new.attach(fake_chat)

      fake_chat.fire # no raise
    end

    it 'raises Cancelled on the next before_tool_call after #cancel!' do
      flag = described_class.new
      flag.attach(fake_chat)

      flag.cancel!

      assert_raises(described_class::Cancelled) { fake_chat.fire }
    end

    it 'keeps raising on every subsequent before_tool_call until reset' do
      flag = described_class.new
      flag.attach(fake_chat)
      flag.cancel!

      assert_raises(described_class::Cancelled) { fake_chat.fire }
      # The flag stays tripped — a second call must still raise.
      assert_raises(described_class::Cancelled) { fake_chat.fire }
    end

    it 'resets the flag on Message::User so a fresh turn starts clean' do
      flag = described_class.new
      flag.attach(fake_chat)
      flag.cancel!

      assert_raises(described_class::Cancelled) { fake_chat.fire }

      flag.on_message(Pikuri::Agent::Message::User.new(content: 'next turn'))

      refute flag.cancelled?
      fake_chat.fire # clean — no raise
    end

    it 'ignores non-User messages' do
      flag = described_class.new
      flag.attach(fake_chat)
      flag.cancel!

      # None of these should clear the flag.
      flag.on_message(Pikuri::Agent::Message::Assistant.new(content: 'hi'))
      flag.on_message(Pikuri::Agent::Message::ToolCall.new(name: 'echo', arguments: {}))
      flag.on_message(Pikuri::Agent::Message::ToolResult.new(content: 'done'))
      flag.on_message(Pikuri::Agent::Message::Thinking.new(content: 'pondering'))

      assert flag.cancelled?
      assert_raises(described_class::Cancelled) { fake_chat.fire }
    end
  end

  describe 'cross-thread cancellation' do
    it 'a #cancel! from another thread is observed at the next before_tool_call' do
      flag = described_class.new
      flag.attach(fake_chat)

      Thread.new { flag.cancel! }.join

      assert_raises(described_class::Cancelled) { fake_chat.fire }
    end
  end

  describe '#for_sub_agent' do
    it 'returns the receiver itself — shared by reference across the tree' do
      flag = described_class.new
      assert_same flag, flag.for_sub_agent
      assert_same flag, flag.for_sub_agent(max_steps: 5, anything_else: :nope)
    end

    it 'cancelling the parent cancels the sub-agent instance' do
      parent = described_class.new
      derived = parent.for_sub_agent(max_steps: 4)

      parent.cancel!

      assert derived.cancelled?
    end

    it 'sub-agent attaches to its own chat and raises after parent cancels' do
      parent = described_class.new
      parent_chat = fake_chat_class.new
      parent.attach(parent_chat)

      derived = parent.for_sub_agent
      derived_chat = fake_chat_class.new
      derived.attach(derived_chat)

      parent.cancel!

      assert_raises(described_class::Cancelled) { parent_chat.fire }
      assert_raises(described_class::Cancelled) { derived_chat.fire }
    end
  end

  describe '#to_s' do
    it 'renders the armed state when no cancel has happened' do
      assert_equal 'Cancellable(armed)', described_class.new.to_s
    end

    it 'renders the cancelled state after #cancel!' do
      flag = described_class.new
      flag.cancel!
      assert_equal 'Cancellable(cancelled)', flag.to_s
    end
  end
end
