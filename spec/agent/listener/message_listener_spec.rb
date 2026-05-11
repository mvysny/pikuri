# frozen_string_literal: true

require 'agent'

RSpec.describe Agent::Listener::MessageListener do
  # Tiny fake chat: captures every block attached to each callback so
  # the spec can fire them with synthetic +RubyLLM::Message+/+ToolCall+
  # payloads. Same shape pikuri's other specs use.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :listeners

      def initialize
        @listeners = Hash.new { |h, k| h[k] = [] }
      end

      def after_message(&b);     @listeners[:after_message] << b;     end
      def before_tool_call(&b);  @listeners[:before_tool_call] << b;  end
      def after_tool_result(&b); @listeners[:after_tool_result] << b; end

      def fire(name, *args)
        @listeners[name].each { |cb| cb.call(*args) }
      end
    end
  end

  # Recording subclass: appends every {Agent::Message} the abstract
  # dispatch builds, so specs can assert on the variant chosen and the
  # fields populated.
  let(:listener_class) do
    Class.new(described_class) do
      attr_reader :messages

      def initialize
        super
        @messages = []
      end

      def on_message(msg)
        @messages << msg
      end
    end
  end

  let(:fake_chat) { fake_chat_class.new }
  let(:listener) { listener_class.new }

  describe '#attach' do
    it 'wires after_message, before_tool_call, and after_tool_result on the chat' do
      listener.attach(fake_chat)

      assert_equal 1, fake_chat.listeners[:after_message].size
      assert_equal 1, fake_chat.listeners[:before_tool_call].size
      assert_equal 1, fake_chat.listeners[:after_tool_result].size
    end
  end

  describe 'after_message dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits Thinking then Assistant for an assistant message with both' do
      thinking = RubyLLM::Thinking.new(text: 'pondered')
      msg = RubyLLM::Message.new(role: :assistant, content: 'hello', thinking: thinking)

      fake_chat.fire(:after_message, msg)

      assert_equal(
        [
          Agent::Message::Thinking.new(content: 'pondered'),
          Agent::Message::Assistant.new(content: 'hello')
        ],
        listener.messages
      )
    end

    it 'skips Thinking when the thinking block is empty' do
      thinking = RubyLLM::Thinking.new(text: '')
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi', thinking: thinking)

      fake_chat.fire(:after_message, msg)

      assert_equal [Agent::Message::Assistant.new(content: 'hi')], listener.messages
    end

    it 'skips Thinking when thinking is absent' do
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi')

      fake_chat.fire(:after_message, msg)

      assert_equal [Agent::Message::Assistant.new(content: 'hi')], listener.messages
    end

    it 'skips Assistant when content is empty' do
      thinking = RubyLLM::Thinking.new(text: 'just thinking')
      msg = RubyLLM::Message.new(role: :assistant, content: '', thinking: thinking)

      fake_chat.fire(:after_message, msg)

      assert_equal [Agent::Message::Thinking.new(content: 'just thinking')], listener.messages
    end

    it 'ignores non-assistant messages entirely' do
      msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'c1')

      fake_chat.fire(:after_message, msg)

      assert_equal [], listener.messages
    end
  end

  describe 'before_tool_call dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits a ToolCall carrying name and arguments' do
      tc = RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' })

      fake_chat.fire(:before_tool_call, tc)

      assert_equal(
        [Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' })],
        listener.messages
      )
    end
  end

  describe 'after_tool_result dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits a ToolResult carrying the observation' do
      fake_chat.fire(:after_tool_result, '42')

      assert_equal [Agent::Message::ToolResult.new(content: '42')], listener.messages
    end
  end

  describe 'default #on_message' do
    it 'is a no-op so listeners can override partially' do
      base = described_class.new

      assert_nil base.on_message(Agent::Message::User.new(content: 'hi'))
      assert_nil base.on_message(Agent::Message::ToolResult.new(content: '42'))
    end
  end
end
