# frozen_string_literal: true

require 'agent'

RSpec.describe Agent do
  # Minimal stand-in for +RubyLLM::Chat+ that captures every listener pikuri
  # registers, lets the spec fire them with synthetic +Message+/+ToolCall+
  # objects, and records what +Agent+ configures (system prompt, tools,
  # +ask+ calls). Lets us pin the listener wiring without going anywhere
  # near a real provider.
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

      def before_message(&block); @listeners[:before_message] << block; self; end
      def after_message(&block);  @listeners[:after_message]  << block; self; end
      def before_tool_call(&block); @listeners[:before_tool_call] << block; self; end
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

  let(:fake_chat) { fake_chat_class.new }

  before do
    captured = fake_chat
    @original_chat = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |**_| captured }

    # TTY::Markdown.parse calls ioctl on $stdout to detect terminal width,
    # which StringIO does not support — so swap it for a passthrough while
    # the spec runs.
    @original_md_parse = TTY::Markdown.method(:parse)
    TTY::Markdown.define_singleton_method(:parse) { |text, **| text }
  end

  after do
    original = @original_chat
    RubyLLM.define_singleton_method(:chat) { |**kwargs| original.call(**kwargs) }

    md_original = @original_md_parse
    TTY::Markdown.define_singleton_method(:parse) { |*args, **kwargs| md_original.call(*args, **kwargs) }
  end

  describe '#initialize' do
    it 'registers system prompt and tools on the underlying chat' do
      tool = Tool.new(
        name: 't', description: 'd',
        parameters: Tool::Parameters.build { |p| p.required_string :x, 'x' },
        execute: ->(x:) { x }
      )
      Agent.new(model: 'm', system_prompt: 'be terse', tools: [tool])

      assert_equal 'be terse', fake_chat.instructions
      assert_equal 1, fake_chat.tools.size
      wired = fake_chat.tools.first
      assert_operator wired, :<, RubyLLM::Tool
      assert_equal 't', wired.name
    end

    it 'rejects non-positive max_steps' do
      assert_raises(ArgumentError) { Agent.new(system_prompt: 's', max_steps: 0) }
      assert_raises(ArgumentError) { Agent.new(system_prompt: 's', max_steps: -1) }
    end
  end

  describe '#run_loop' do
    it 'forwards user_message to chat.ask' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      agent.run_loop(user_message: 'hello?')

      assert_equal ['hello?'], fake_chat.asks
    end
  end

  describe 'after_message listener' do
    it 'prints assistant content as Markdown and reasoning as dim text' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      _ = agent
      msg = fake_chat.add_assistant('**hi**', thinking: 'pondered')

      out, _err = capture_subprocess_stdio { fake_chat.fire(:after_message, msg) }

      assert_includes out, 'pondered'
      assert_includes out, 'hi'
    end

    it 'ignores tool-role messages' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      _ = agent
      tool_msg = RubyLLM::Message.new(role: :tool, content: 'observation', tool_call_id: 'call_1')

      out, _err = capture_subprocess_stdio { fake_chat.fire(:after_message, tool_msg) }

      assert_equal '', out
    end
  end

  describe 'before_tool_call listener' do
    let(:tool_call) { RubyLLM::ToolCall.new(id: 'c1', name: 'echo', arguments: { 'text' => 'hi' }) }

    it 'prints the tool invocation in cyan' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      _ = agent

      out, _err = capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }

      assert_includes out, 'echo'
      assert_includes out, 'text='
    end

    it 'raises once max_steps tool calls have been made' do
      agent = Agent.new(model: 'm', system_prompt: 's', max_steps: 2)
      _ = agent

      capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }
      capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }

      err = assert_raises(RuntimeError) do
        capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }
      end
      assert_includes err.message, 'exceeded 2 steps'
    end

    it 'resets the step counter between run_loop invocations' do
      agent = Agent.new(model: 'm', system_prompt: 's', max_steps: 1)

      agent.run_loop(user_message: 'first')
      capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }

      agent.run_loop(user_message: 'second')
      capture_subprocess_stdio { fake_chat.fire(:before_tool_call, tool_call) }
    end
  end

  describe 'after_tool_result listener' do
    it 'prints the result' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      _ = agent

      out, _err = capture_subprocess_stdio { fake_chat.fire(:after_tool_result, '42') }

      assert_includes out, '42'
    end
  end

  describe '#last_assistant_content' do
    it 'returns the most recent assistant message content' do
      agent = Agent.new(model: 'm', system_prompt: 's')
      fake_chat.add_assistant('first')
      fake_chat.add_assistant('second')

      assert_equal 'second', agent.last_assistant_content
    end

    it 'returns nil when no assistant message has been produced yet' do
      agent = Agent.new(model: 'm', system_prompt: 's')

      assert_nil agent.last_assistant_content
    end
  end

  # Cheap stdout capture — the rspec/minitest combination here doesn't
  # bring in capture_subprocess_io, so we redirect $stdout to a StringIO.
  def capture_subprocess_stdio
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    [captured.string, '']
  ensure
    $stdout = original
  end
end
