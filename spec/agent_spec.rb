# frozen_string_literal: true

require 'agent'

RSpec.describe Agent do
  # Minimal stand-in for +RubyLLM::Chat+ that captures every listener
  # pikuri registers, lets the spec fire them with synthetic
  # +Message+/+ToolCall+ payloads, and records what +Agent+ configures
  # (system prompt, tools, +ask+ calls). Lets us pin the agent-level
  # wiring without going anywhere near a real provider.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions, :listeners

      def initialize
        @tools = []
        @asks = []
        @messages = []
        @listeners = Hash.new { |h, k| h[k] = [] }
      end

      def with_instructions(text)
        @instructions = text
        self
      end

      def with_tool(tool)
        @tools << tool
        self
      end

      def after_message(&block);     @listeners[:after_message] << block;     self; end
      def before_tool_call(&block);  @listeners[:before_tool_call] << block;  self; end
      def after_tool_result(&block); @listeners[:after_tool_result] << block; self; end

      def ask(message)
        @asks << message
        nil
      end

      def fire(name, *args)
        @listeners[name].each { |cb| cb.call(*args) }
      end

      def add_assistant(content, thinking: nil)
        thinking_obj = thinking ? RubyLLM::Thinking.new(text: thinking) : nil
        msg = RubyLLM::Message.new(role: :assistant, content: content, thinking: thinking_obj)
        @messages << msg
        msg
      end
    end
  end

  let(:fake_chat)    { fake_chat_class.new }
  let(:in_memory)    { Agent::Listener::InMemoryList.new }
  let(:step_limit_2) { Agent::Listener::StepLimit.new(max: 2) }

  before do
    captured = fake_chat
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**_| captured }
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }
  end

  describe '#initialize' do
    it 'registers system prompt and tools on the underlying chat' do
      tool = Tool.new(
        name: 't', description: 'd',
        parameters: Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
      Agent.new(model: 'm', system_prompt: 'be terse', tools: [tool], listeners: [in_memory])

      assert_equal 'be terse', fake_chat.instructions
      assert_equal 1, fake_chat.tools.size
      wired = fake_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 't', wired.name
    end

    it 'attaches every listener in the supplied list to the chat' do
      Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory, step_limit_2])

      # InMemoryList (a MessageListener) wires after_message +
      # before_tool_call + after_tool_result; StepLimit adds its own
      # before_tool_call. Expect 2 before_tool_call callbacks and 1 of
      # the other two.
      assert_equal 1, fake_chat.listeners[:after_message].size
      assert_equal 2, fake_chat.listeners[:before_tool_call].size
      assert_equal 1, fake_chat.listeners[:after_tool_result].size
    end

    it 'defaults the listener list to Terminal + StepLimit(max=20)' do
      agent = Agent.new(model: 'm', system_prompt: 's')

      assert_equal 2, agent.listeners.size
      assert_kind_of Agent::Listener::Terminal,  agent.listeners[0]
      assert_kind_of Agent::Listener::StepLimit, agent.listeners[1]
    end
  end

  describe '#run_loop' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'forwards user_message to chat.ask' do
      agent = Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory])
      agent.run_loop(user_message: 'hello?')

      assert_equal ['hello?'], fake_chat.asks
    end

    it 'emits a Message::User to every listener before asking the chat' do
      agent = Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory])
      agent.run_loop(user_message: 'hello?')

      assert_includes in_memory.events, Agent::Message::User.new(content: 'hello?')
    end

    it "resets the step counter between turns via StepLimit's User reset" do
      agent = Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory, step_limit_2])

      # Burn the budget on turn 1.
      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)

      agent.run_loop(user_message: 'turn 2 starts now')

      # Two fresh tool calls land without raising — counter was reset
      # when StepLimit#on_message received the new Message::User.
      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)
    end
  end

  describe 'listener routing' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' }) }

    before do
      Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory])
    end

    it 'forwards assistant messages as Thinking + Assistant' do
      msg = fake_chat.add_assistant('**hi**', thinking: 'pondered')
      fake_chat.fire(:after_message, msg)

      assert_equal(
        [
          Agent::Message::Thinking.new(content: 'pondered'),
          Agent::Message::Assistant.new(content: '**hi**')
        ],
        in_memory.events
      )
    end

    it 'skips tool-role messages entirely' do
      tool_msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'call_1')

      fake_chat.fire(:after_message, tool_msg)

      assert_equal [], in_memory.events
    end

    it 'forwards tool calls as ToolCall with name and arguments' do
      fake_chat.fire(:before_tool_call, tool_call)

      assert_equal(
        [Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' })],
        in_memory.events
      )
    end

    it 'forwards tool results as ToolResult' do
      fake_chat.fire(:after_tool_result, '42')

      assert_equal [Agent::Message::ToolResult.new(content: '42')], in_memory.events
    end
  end

  describe 'step-limit enforcement at the Agent level' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'raises Listener::StepLimit::Exceeded once the cap is exceeded' do
      Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory, step_limit_2])

      fake_chat.fire(:before_tool_call, tool_call)
      fake_chat.fire(:before_tool_call, tool_call)

      err = assert_raises(Agent::Listener::StepLimit::Exceeded) do
        fake_chat.fire(:before_tool_call, tool_call)
      end
      assert_equal 2, err.max_steps
    end
  end

  describe '#last_assistant_content' do
    it 'returns the most recent assistant message content' do
      agent = Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory])
      fake_chat.add_assistant('first')
      fake_chat.add_assistant('second')

      assert_equal 'second', agent.last_assistant_content
    end

    it 'returns nil when no assistant message has been produced yet' do
      agent = Agent.new(model: 'm', system_prompt: 's', listeners: [in_memory])

      assert_nil agent.last_assistant_content
    end
  end

  describe '#to_s' do
    it 'renders model, tool count, and listener list as a one-liner' do
      tool = Tool.new(
        name: 't', description: 'd',
        parameters: Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
      agent = Agent.new(model: 'm', system_prompt: 's', tools: [tool],
                        listeners: [in_memory, step_limit_2])

      assert_equal 'Agent(model=m, tools=1, listeners=[InMemoryList, StepLimit(max=2)])',
                   agent.to_s
    end
  end
end
