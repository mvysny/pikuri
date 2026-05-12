# frozen_string_literal: true

require 'agent'

RSpec.describe Agent do
  # Minimal stand-in for +RubyLLM::Chat+ that captures every listener
  # pikuri registers, lets the spec fire them with synthetic
  # +Message+/+ToolCall+ payloads, and records what +Agent+ configures
  # (system prompt, tools, +ask+ calls). Lets us pin the agent-level
  # wiring without going anywhere near a real provider.
  # +RubyLLM::Model::Info+ stand-in just so +Agent#initialize+ can read
  # +@chat.model.context_window+ for {Agent::ContextWindowDetector}.
  # Returns +nil+, which is what +Model::Info.default+ produces for any
  # model that isn't in ruby_llm's bundled registry — the path our
  # local-llama deployment exercises.
  fake_model = Struct.new(:context_window).new(nil)

  let(:fake_chat_class) do
    captured_model = fake_model
    Class.new do
      attr_reader :tools, :asks, :messages, :instructions, :listeners

      define_method(:initialize) do
        @tools = []
        @asks = []
        @messages = []
        @listeners = Hash.new { |h, k| h[k] = [] }
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
  let(:listener_list) { Agent::ListenerList.new([in_memory, step_limit_2]) }

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
      Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 'be terse', tools: [tool],
                listeners: Agent::ListenerList.new([in_memory]))

      assert_equal 'be terse', fake_chat.instructions
      assert_equal 1, fake_chat.tools.size
      wired = fake_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 't', wired.name
    end

    it 'attaches every listener in the supplied list to the chat' do
      Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [], listeners: listener_list)

      # InMemoryList (a MessageListener) wires after_message +
      # before_tool_call + after_tool_result; StepLimit adds its own
      # before_tool_call. Expect 2 before_tool_call callbacks and 1 of
      # the other two.
      assert_equal 1, fake_chat.listeners[:after_message].size
      assert_equal 2, fake_chat.listeners[:before_tool_call].size
      assert_equal 1, fake_chat.listeners[:after_tool_result].size
    end

    it 'requires listeners: — no silent default' do
      assert_raises(ArgumentError) do
        Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [])
      end
    end

    it 'requires tools: — no silent default' do
      assert_raises(ArgumentError) do
        Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', listeners: listener_list)
      end
    end

    it 'defaults name to empty (main agent)' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]))

      assert_equal '', agent.name
    end

    it 'exposes an explicitly passed name' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]), name: '0_1')

      assert_equal '0_1', agent.name
    end

    describe 'context-window detection' do
      let(:token_log) { Agent::Listener::TokenLog.new }
      let(:list_with_tokens) { Agent::ListenerList.new([in_memory, token_log]) }

      it 'pushes the detected cap onto every TokenLog in the listener list' do
        # No ruby_llm reported value (fake .model.context_window is nil),
        # no probe URL — explicit override wins.
        Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                  listeners: list_with_tokens, context_window: 32_768)

        assert_equal 32_768, token_log.context_window_cap
      end

      it 'falls back to ruby_llm reported value when no override is given' do
        # Rebind the fake_chat's model to one that reports a window.
        fake_chat.instance_variable_set(:@model_info, Struct.new(:context_window).new(200_000))

        Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                  listeners: list_with_tokens)

        assert_equal 200_000, token_log.context_window_cap
      end

      it 'exposes the resolved cap via #context_window_cap' do
        agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                          listeners: list_with_tokens, context_window: 8_192)

        assert_equal 8_192, agent.context_window_cap
      end

      it 'leaves cap nil when nothing produces a value (no override, no registry, no probe URL)' do
        agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                          listeners: list_with_tokens)

        assert_nil agent.context_window_cap
        assert_nil token_log.context_window_cap
      end
    end
  end

  describe '#allow_sub_agent' do
    it "forwards the parent's resolved context_window_cap as the sub-agent tool's override" do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]),
                        context_window: 12_345)
      agent.allow_sub_agent(max_steps: 3)

      # The sub_agent tool is the last one wired onto the chat. We can
      # introspect it by running its execute lambda and seeing what
      # Agent.new is called with — but easier: capture the next
      # +RubyLLM.chat+ call and check its produced agent's cap.
      captured_caps = []
      hook = lambda do |sub_agent|
        captured_caps << sub_agent.context_window_cap
        'sub reply'
      end

      # Stub Agent.new globally just for this test: record the
      # +context_window+ kwarg the sub-agent factory passes.
      original_new = Agent.method(:new)
      received_kwargs = nil
      Agent.define_singleton_method(:new) do |**kwargs|
        received_kwargs = kwargs
        original_new.call(**kwargs).tap do |a|
          a.define_singleton_method(:run_loop) { |**_| nil }
          a.define_singleton_method(:last_assistant_content) { 'sub reply' }
        end
      end

      begin
        sub_tool = agent.instance_variable_get(:@tools).last
        sub_tool.run('task' => 'do the thing')
        assert_equal 12_345, received_kwargs[:context_window]
      ensure
        Agent.define_singleton_method(:new) { |**kw| original_new.call(**kw) }
      end
    end
  end

  describe '#run_loop' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: {}) }

    it 'forwards user_message to chat.ask' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]))
      agent.run_loop(user_message: 'hello?')

      assert_equal ['hello?'], fake_chat.asks
    end

    it 'emits a Message::User to every listener before asking the chat' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]))
      agent.run_loop(user_message: 'hello?')

      assert_includes in_memory.events, Agent::Message::User.new(content: 'hello?')
    end

    it "resets the step counter between turns via StepLimit's User reset" do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [], listeners: listener_list)

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
      Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                listeners: Agent::ListenerList.new([in_memory]))
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
      Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [], listeners: listener_list)

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
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]))
      fake_chat.add_assistant('first')
      fake_chat.add_assistant('second')

      assert_equal 'second', agent.last_assistant_content
    end

    it 'returns nil when no assistant message has been produced yet' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory]))

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
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [tool],
                        listeners: listener_list)

      assert_equal 'Agent(model=m, tools=1, listeners=[InMemoryList, StepLimit(max=2)])',
                   agent.to_s
    end
  end

  describe 'step-exhaustion rescue' do
    # Stub +Agent::Synthesizer.run+ so the rescue branch can be tested
    # without standing up a second fake chat. Captured kwargs let the
    # spec assert on exactly what Agent handed to the synthesizer.
    before do
      @synth_calls = []
      captured = @synth_calls
      @original_run = Agent::Synthesizer.method(:run)
      Agent::Synthesizer.define_singleton_method(:run) do |**kwargs|
        captured << kwargs
        'rescued answer'
      end
    end

    after do
      original = @original_run
      Agent::Synthesizer.define_singleton_method(:run) { |**kw| original.call(**kw) }
    end

    # Helper: arrange for the parent chat's +ask+ to raise once, as if
    # a StepLimit deep inside its +before_tool_call+ tripped.
    def arrange_step_exhaustion(max_steps)
      err = Agent::Listener::StepLimit::Exceeded.new(max_steps)
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        raise err
      end
    end

    it 'catches Exceeded, emits a FallbackNotice, and returns nil from run_loop' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory, Agent::Listener::StepLimit.new(max: 2)]))
      arrange_step_exhaustion(2)

      assert_nil agent.run_loop(user_message: 'compare two cities')

      assert_includes in_memory.events, Agent::Message::User.new(content: 'compare two cities')
      notice = in_memory.events.find { |m| m.is_a?(Agent::Message::FallbackNotice) }
      refute_nil notice, 'expected a FallbackNotice in the listener stream'
      assert_includes notice.reason, 'exhausted 2 steps'
    end

    it 'invokes Synthesizer.run with the parent chat history, a sub-agent-derived listener list, and original question' do
      listeners = Agent::ListenerList.new([in_memory, Agent::Listener::StepLimit.new(max: 2)])
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [], listeners: listeners)
      fake_chat.add_assistant('plan: do stuff')
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'why?')

      assert_equal 1, @synth_calls.size
      call = @synth_calls.first
      refute_nil call[:chat], 'expected a fresh synth chat to be passed'
      assert_equal fake_chat.messages, call[:parent_messages]
      assert_equal 'why?', call[:user_message]

      # The handed-off list is a derived one, not the parent's instance —
      # ListenerList#for_sub_agent returns a new object so the synth
      # chat doesn't share the parent's StepLimit counter, and gets a
      # fresh TokenLog / padded Terminal in passing.
      refute_same listeners, call[:listeners]
      assert_kind_of Agent::ListenerList, call[:listeners]
      assert_equal '[InMemoryList, StepLimit(max=1)]', call[:listeners].to_s
    end

    it "tags the synth's listener name as '<parent>_synthesizer' (or 'synthesizer' for the main agent)" do
      # Use a TokenLog as the visible carrier of the name: ListenerList
      # only retains the kwarg on listeners whose for_sub_agent acts on
      # it, so the derived list's TokenLog#name is the assertable thing.
      parent_log = Agent::Listener::TokenLog.new
      listeners  = Agent::ListenerList.new([parent_log, Agent::Listener::StepLimit.new(max: 2)])
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: listeners)
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      synth_listeners = @synth_calls.first[:listeners].instance_variable_get(:@listeners)
      synth_log = synth_listeners.find { |l| l.is_a?(Agent::Listener::TokenLog) }
      refute_nil synth_log
      assert_equal 'synthesizer', synth_log.name

      # And the parent's TokenLog is untouched.
      assert_equal '', parent_log.name
    end

    it "uses '<parent_name>_synthesizer' when the agent itself has a name" do
      parent_log = Agent::Listener::TokenLog.new
      listeners  = Agent::ListenerList.new([parent_log, Agent::Listener::StepLimit.new(max: 2)])
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: listeners, name: '0_1')
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      synth_listeners = @synth_calls.first[:listeners].instance_variable_get(:@listeners)
      synth_log = synth_listeners.find { |l| l.is_a?(Agent::Listener::TokenLog) }
      assert_equal '0_1_synthesizer', synth_log.name
    end

    it "prefers the synth's answer for last_assistant_content after a rescue" do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory, Agent::Listener::StepLimit.new(max: 2)]))
      arrange_step_exhaustion(2)

      agent.run_loop(user_message: 'q?')

      assert_equal 'rescued answer', agent.last_assistant_content
    end

    it 'clears the prior synth answer at the start of each new turn' do
      agent = Agent.new(transport: Agent::ChatTransport.new(model: 'm'), system_prompt: 's', tools: [],
                        listeners: Agent::ListenerList.new([in_memory, Agent::Listener::StepLimit.new(max: 2)]))
      arrange_step_exhaustion(2)
      agent.run_loop(user_message: 'turn 1')
      assert_equal 'rescued answer', agent.last_assistant_content

      # Make the next turn succeed: replace ask with one that just adds an assistant message.
      fake_chat.define_singleton_method(:ask) do |msg|
        @asks << msg
        @messages << RubyLLM::Message.new(role: :assistant, content: 'normal answer')
      end
      agent.run_loop(user_message: 'turn 2')

      assert_equal 'normal answer', agent.last_assistant_content
    end
  end
end
