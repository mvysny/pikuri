# frozen_string_literal: true

require 'tool/sub_agent'

RSpec.describe '.sub_agent' do
  # Minimal stand-in for +RubyLLM::Chat+: records what +Agent+ configures
  # on it, drops a canned assistant +Message+ into +messages+ on +ask+, and
  # exposes +calls+ for assertions. Keeps sub-agent specs network-free.
  let(:fake_chat_class) do
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions

      def initialize(reply: 'sub-agent reply')
        @tools = []
        @asks = []
        @messages = []
        @reply = reply
      end

      def with_instructions(text)
        @instructions = text
        self
      end

      def with_tool(tool)
        @tools << tool
        self
      end

      def before_message(&); self; end
      def after_message(&); self; end
      def before_tool_call(&); self; end
      def after_tool_result(&); self; end

      def ask(message)
        @asks << message
        @messages << RubyLLM::Message.new(role: :assistant, content: @reply)
        @messages.last
      end
    end
  end

  let(:dummy_tool) do
    Tool.new(
      name: 'dummy',
      description: 'dummy',
      parameters: Tool::Parameters.build { |p| p.required_string :x, 'x' },
      execute: ->(x:) { x }
    )
  end

  before do
    @fake_chats = []
    fake_class = fake_chat_class
    captured = @fake_chats
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) do |**_|
      chat = fake_class.new
      captured << chat
      chat
    end
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }
  end

  describe 'tool shape' do
    it 'returns a Tool named "sub_agent" with a required `task` string parameter' do
      tool = Tool.sub_agent(model: 'm', system_prompt: 'sp', tools: [])

      assert_kind_of Tool, tool
      assert_equal 'sub_agent', tool.name
      schema = tool.parameters.to_h
      assert_equal ['task'], schema[:required]
      assert_equal 'string', schema[:properties][:task][:type]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      tool = Tool.sub_agent(model: 'm', system_prompt: 'system!', tools: [dummy_tool])

      result = tool.run('task' => 'do the thing')

      assert_equal 'sub-agent reply', result
    end

    it 'configures the sub-agent\'s chat with the system prompt and asks it the task' do
      tool = Tool.sub_agent(model: 'm', system_prompt: 'be terse', tools: [])
      tool.run('task' => 'count to three')

      assert_equal 1, @fake_chats.size
      sub_chat = @fake_chats.first
      assert_equal 'be terse', sub_chat.instructions
      assert_equal ['count to three'], sub_chat.asks
    end

    it 'advertises exactly the configured tool list to the sub-agent' do
      tool = Tool.sub_agent(model: 'm', system_prompt: 'sp', tools: [dummy_tool])
      tool.run('task' => 'go')

      sub_chat = @fake_chats.first
      assert_equal 1, sub_chat.tools.size
      wired = sub_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 'dummy', wired.name
    end
  end
end
