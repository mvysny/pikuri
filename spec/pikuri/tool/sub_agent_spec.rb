# frozen_string_literal: true

RSpec.describe Pikuri::Tool::SubAgent do
  # Minimal stand-in for +RubyLLM::Chat+: records what +Pikuri::Agent+ configures
  # on it, drops a canned assistant +Message+ into +messages+ on +ask+, and
  # exposes +calls+ for assertions. Keeps sub-agent specs network-free.
  # +RubyLLM::Model::Info+ stand-in just so +Pikuri::Agent#initialize+ can read
  # +@chat.model.context_window+ for {Pikuri::Agent::ContextWindowDetector}.
  fake_model = Struct.new(:context_window).new(nil)

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions

      define_method(:initialize) do |reply: 'sub-agent reply'|
        @tools = []
        @asks = []
        @messages = []
        @reply = reply
        @model_info = captured_model
      end

      def model
        @model_info
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
    Pikuri::Tool.new(
      name: 'dummy',
      description: 'dummy',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :x, 'x' },
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

  let(:parent_listeners) do
    Pikuri::Agent::ListenerList.new([
      Pikuri::Agent::Listener::InMemoryList.new,
      Pikuri::Agent::Listener::StepLimit.new(max: 99)
    ])
  end

  # Build a minimal parent Pikuri::Agent against the fake +RubyLLM.chat+ stubbed
  # in the outer +before+. Each spec uses this to get an +Pikuri::Agent+ the
  # factory can read +transport+/+system_prompt+/+tools+/+listeners+/
  # +context_window_cap+/+name+ off of.
  def build_parent(system_prompt: 'sp', tools: [], listeners: parent_listeners, name: '')
    Pikuri::Agent.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt: system_prompt,
      tools: tools,
      listeners: listeners,
      name: name
    )
  end

  describe 'tool shape' do
    it 'returns a Pikuri::Tool named "sub_agent" with a required `task` string parameter' do
      tool = Pikuri::Tool::SubAgent.new(build_parent)

      assert_kind_of Pikuri::Tool, tool
      assert_equal 'sub_agent', tool.name
      schema = tool.parameters.to_h
      assert_equal ['task'], schema[:required]
      assert_equal 'string', schema[:properties][:task][:type]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      tool = Pikuri::Tool::SubAgent.new(build_parent(system_prompt: 'system!', tools: [dummy_tool]))

      result = tool.run('task' => 'do the thing')

      # The parent build also went through the stubbed +RubyLLM.chat+, so
      # the captured chats list contains [parent, sub]. Inspect the last.
      assert_equal 'sub-agent reply', result
    end

    it "configures the sub-agent's chat with the system prompt and asks it the task" do
      tool = Pikuri::Tool::SubAgent.new(build_parent(system_prompt: 'be terse'))
      tool.run('task' => 'count to three')

      # Two chats now: the parent's (built by +build_parent+) and the
      # sub's (built by the factory's +execute+ lambda). The sub is last.
      sub_chat = @fake_chats.last
      assert_equal 'be terse', sub_chat.instructions
      assert_equal ['count to three'], sub_chat.asks
    end

    it 'advertises exactly the parent-snapshot tool list to the sub-agent' do
      tool = Pikuri::Tool::SubAgent.new(build_parent(tools: [dummy_tool]))
      tool.run('task' => 'go')

      sub_chat = @fake_chats.last
      assert_equal 1, sub_chat.tools.size
      wired = sub_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 'dummy', wired.name
    end
  end

  describe 'sub-agent naming' do
    # Capture every kwarg handed to Pikuri::Agent.new so the spec can read the
    # generated +name:+ without having to introspect a built Pikuri::Agent. The
    # underlying chat is still the fake from the outer +before+, so the
    # constructed agents are inert (their +run_loop+ resolves through
    # the fake chat which records but doesn't drive a real loop).
    def with_captured_agent_new
      received = []
      original_new = Pikuri::Agent.method(:new)
      Pikuri::Agent.define_singleton_method(:new) do |**kwargs|
        received << kwargs
        original_new.call(**kwargs).tap do |a|
          a.define_singleton_method(:run_loop)               { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end
      begin
        yield received
      ensure
        Pikuri::Agent.define_singleton_method(:new) { |**kw| original_new.call(**kw) }
      end
    end

    it 'generates monotonic flat names when the parent has no name' do
      tool = Pikuri::Tool::SubAgent.new(build_parent)

      with_captured_agent_new do |kwargs|
        tool.run('task' => 'first')
        tool.run('task' => 'second')
        tool.run('task' => 'third')

        assert_equal ['sub_agent 0', 'sub_agent 1', 'sub_agent 2'], kwargs.map { |kw| kw[:name] }
      end
    end

    it 'generates hierarchical names when the parent has a name' do
      tool = Pikuri::Tool::SubAgent.new(build_parent(name: 'sub_agent 0'))

      with_captured_agent_new do |kwargs|
        tool.run('task' => 'a')
        tool.run('task' => 'b')

        assert_equal ['sub_agent 0_0', 'sub_agent 0_1'], kwargs.map { |kw| kw[:name] }
      end
    end

    it 'threads max_steps and the generated name to listeners.for_sub_agent' do
      # Spy that records every for_sub_agent call's kwargs. Stays
      # ListenerList-shaped so the +execute+ lambda can keep calling
      # +.for_sub_agent+ on the result if it had to (it doesn't, but
      # the API surface still has to match). Also satisfies the
      # +Pikuri::Agent+ constructor's +attach+ / +context_window_cap=+ calls.
      recorded = []
      spy = Class.new do
        define_method(:initialize) { |out| @out = out }
        def attach(_); end
        def on_message(_); end
        def context_window_cap=(_); end
        define_method(:for_sub_agent) do |**params|
          @out << params
          self
        end
      end.new(recorded)

      tool = Pikuri::Tool::SubAgent.new(build_parent(listeners: spy), max_steps: 7)

      with_captured_agent_new do |_|
        tool.run('task' => 'go')
      end

      assert_equal [{ max_steps: 7, name: 'sub_agent 0' }], recorded
    end
  end
end
