# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Listener::MessageListener do
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

  # Recording subclass: appends every {Pikuri::Agent::Message} and every
  # {Pikuri::Agent::Tokens} the abstract dispatch builds, so specs can assert
  # on the variant chosen, the fields populated, and the per-channel
  # routing (messages vs. tokens).
  let(:listener_class) do
    Class.new(described_class) do
      attr_reader :messages, :tokens_seen

      def initialize
        super
        @messages = []
        @tokens_seen = []
      end

      def on_message(msg)
        @messages << msg
      end

      def on_tokens(tokens)
        @tokens_seen << tokens
      end
    end
  end

  let(:fake_chat) { fake_chat_class.new }
  let(:listener) { listener_class.new }

  # A token block with every field nil, the shape we get from a
  # +RubyLLM::Message+ built without a +tokens:+ option (the common
  # case in these specs — the provider didn't report).
  let(:nil_tokens) do
    Pikuri::Agent::Tokens.new(
      input: nil, output: nil, cached: nil, cache_creation: nil,
      thinking: nil, model_id: nil
    )
  end

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
          Pikuri::Agent::Message::Thinking.new(content: 'pondered'),
          Pikuri::Agent::Message::Assistant.new(content: 'hello')
        ],
        listener.messages
      )
    end

    it 'skips Thinking when the thinking block is empty' do
      thinking = RubyLLM::Thinking.new(text: '')
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi', thinking: thinking)

      fake_chat.fire(:after_message, msg)

      assert_equal [Pikuri::Agent::Message::Assistant.new(content: 'hi')], listener.messages
    end

    it 'skips Thinking when thinking is absent' do
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi')

      fake_chat.fire(:after_message, msg)

      assert_equal [Pikuri::Agent::Message::Assistant.new(content: 'hi')], listener.messages
    end

    it 'skips Assistant when content is empty' do
      thinking = RubyLLM::Thinking.new(text: 'just thinking')
      msg = RubyLLM::Message.new(role: :assistant, content: '', thinking: thinking)

      fake_chat.fire(:after_message, msg)

      assert_equal [Pikuri::Agent::Message::Thinking.new(content: 'just thinking')], listener.messages
    end

    it 'ignores non-assistant messages entirely' do
      msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'c1')

      fake_chat.fire(:after_message, msg)

      assert_equal [], listener.messages
      assert_equal [], listener.tokens_seen
    end
  end

  describe 'after_message tokens dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits Tokens once per assistant turn' do
      msg = RubyLLM::Message.new(role: :assistant, content: 'hi')

      fake_chat.fire(:after_message, msg)

      assert_equal [nil_tokens], listener.tokens_seen
    end

    it 'emits Tokens even for a pure tool-call turn with empty content' do
      # ruby_llm fires after_message for tool-call turns too; content is
      # empty there, but the input/output token counts on those turns
      # are exactly what we want to track for context-window growth.
      msg = RubyLLM::Message.new(role: :assistant, content: '')

      fake_chat.fire(:after_message, msg)

      assert_equal [], listener.messages, 'no Message variant should flow for empty content + no thinking'
      assert_equal [nil_tokens], listener.tokens_seen
    end

    it 'populates Tokens fields from the underlying RubyLLM::Message' do
      msg = RubyLLM::Message.new(
        role: :assistant, content: 'reply', model_id: 'qwen3-35b',
        input_tokens: 12_453, output_tokens: 320,
        cached_tokens: 12_000, cache_creation_tokens: 256,
        thinking_tokens: 80
      )

      fake_chat.fire(:after_message, msg)

      assert_equal 1, listener.tokens_seen.size
      tokens = listener.tokens_seen.first
      assert_equal 12_453,    tokens.input
      assert_equal 320,       tokens.output
      assert_equal 12_000,    tokens.cached
      assert_equal 256,       tokens.cache_creation
      assert_equal 80,        tokens.thinking
      assert_equal 'qwen3-35b', tokens.model_id
    end

    it 'does not emit Tokens for non-assistant messages' do
      msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'c1')

      fake_chat.fire(:after_message, msg)

      assert_equal [], listener.tokens_seen
    end
  end

  describe 'before_tool_call dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits a ToolCall carrying name and arguments' do
      tc = RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' })

      fake_chat.fire(:before_tool_call, tc)

      assert_equal(
        [Pikuri::Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' })],
        listener.messages
      )
    end
  end

  describe 'after_tool_result dispatch' do
    before { listener.attach(fake_chat) }

    it 'emits a ToolResult carrying the observation' do
      fake_chat.fire(:after_tool_result, '42')

      assert_equal [Pikuri::Agent::Message::ToolResult.new(content: '42')], listener.messages
    end
  end

  describe 'default #on_message' do
    it 'is a no-op so listeners can override partially' do
      base = described_class.new

      assert_nil base.on_message(Pikuri::Agent::Message::User.new(content: 'hi'))
      assert_nil base.on_message(Pikuri::Agent::Message::ToolResult.new(content: '42'))
    end
  end

  describe 'default #on_tokens' do
    it 'is a no-op so listeners that do not care about usage can ignore it' do
      base = described_class.new

      assert_nil base.on_tokens(nil_tokens)
    end
  end
end
