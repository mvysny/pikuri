# frozen_string_literal: true

require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# Exercises the fake-transport seam end to end: a REAL Pikuri::Agent + REAL
# ruby_llm loop + REAL tools, driven by scripted HTTP. These are the three
# spikes (canned reply, tool round-trip, SSE streaming) turned into pins.
RSpec.describe Pikuri::Testing do
  # Records the whole Event stream so we can assert on what the agent emitted.
  let(:capture_class) do
    Class.new(Pikuri::Agent::Listener::Base) do
      attr_reader :events

      def initialize
        @events = []
      end

      def for_sub_agent(**) = self
      def on_event(event) = (@events << event)
    end
  end

  def build_agent(transport, listener)
    Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
      c.add_listener listener
      c.add_tool Pikuri::Tool::CALCULATOR
    end
  end

  it 'runs a canned reply through the real loop (L0)' do
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport { |llm| llm.reply('hello from the fake') }
    agent = build_agent(transport, listener)

    agent.run_loop(user_message: 'hi')

    answer = listener.events.grep(Pikuri::Agent::Event::Assistant).last
    assert_equal 'hello from the fake', answer.content
  ensure
    agent&.close
  end

  it 'drives a real tool round-trip: fake tool_call → real calculator → fake final answer (L1)' do
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('The answer is 4.')
    end
    agent = build_agent(transport, listener)

    agent.run_loop(user_message: 'What is 2 + 2?')

    call = listener.events.grep(Pikuri::Agent::Event::ToolCall).first
    result = listener.events.grep(Pikuri::Agent::Event::ToolResult).first
    answer = listener.events.grep(Pikuri::Agent::Event::Assistant).last

    assert_equal 'calculator', call.name
    assert_equal({ 'expression' => '2 + 2' }, call.arguments)
    assert_includes result.content.to_s, '4' # the REAL calculator computed it
    assert_equal 'The answer is 4.', answer.content
  ensure
    agent&.close
  end

  it 'streams text through the real streaming path: deltas + assembled final (L2)' do
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport { |llm| llm.stream('The ', 'answer ', 'is ', '4.') }
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent', streaming: true) do |c|
      c.add_listener listener
    end

    agent.run_loop(user_message: 'What is 2 + 2?')

    deltas = listener.events.grep(Pikuri::Agent::Event::AssistantDelta).map(&:content)
    final = listener.events.grep(Pikuri::Agent::Event::Assistant).last

    assert_equal ['The ', 'answer ', 'is ', '4.'], deltas
    assert_equal 'The answer is 4.', final.content
  ensure
    agent&.close
  end

  it 'keeps the adapter per-context: the global RubyLLM config is untouched' do
    before = RubyLLM.config.faraday_adapter
    transport = Pikuri::Testing.fake_transport { |llm| llm.reply('x') }
    agent = build_agent(transport, capture_class.new)
    agent.run_loop(user_message: 'hi')

    assert_equal before, RubyLLM.config.faraday_adapter
    refute_equal before, transport.faraday_adapter
  ensure
    agent&.close
  end

  it 'honours an api_base override so a fake can impersonate a configured connection' do
    transport = Pikuri::Testing.fake_transport(model: 'qwen3', api_base: 'http://mavi-fw:8080/v1') do |llm|
      llm.reply('x')
    end
    assert_equal 'http://mavi-fw:8080/v1', transport.api_base
    assert_equal 'qwen3', transport.model
  end

  it 'holds a turn open via a Gate until released (mid-turn gating)' do
    gate = Pikuri::Testing::Gate.new
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport(gate: gate) { |llm| llm.reply('done') }
    agent = build_agent(transport, listener)

    gate.block!
    worker = Thread.new { agent.run_loop(user_message: 'work') }
    # The turn parks inside the adapter: no assistant answer yet.
    sleep 0.05
    assert_nil listener.events.grep(Pikuri::Agent::Event::Assistant).last, 'turn should be parked'
    assert worker.alive?, 'worker should be blocked on the gate'

    gate.release!
    worker.join(2)
    assert_equal 'done', listener.events.grep(Pikuri::Agent::Event::Assistant).last&.content
  ensure
    gate.release!
    worker&.join(2)
    agent&.close
  end

  # What the fake transport is uniquely good for: asserting the *payload*, not
  # just the events. An interloper injection appended between an assistant's
  # tool_calls message and the tool message answering it is rejected by OpenAI
  # and Anthropic, and silently mangled by a local chat template — and no
  # event-level assertion can see it, because the listener order looks right
  # either way.
  describe 'message order on the wire' do
    # Serves the scripted responses and keeps every request body, so a spec can
    # read exactly what the provider would have received.
    def recording_transport(captured, &script_block)
      script = Pikuri::Testing::Script.new
      script_block.call(script)
      base = Pikuri::Testing.build_adapter(script.responses)
      recorder = Class.new(base) do
        define_method(:call) do |env|
          captured << JSON.parse(env.body.to_s)
          super(env)
        end
      end
      Pikuri::Agent::ChatTransport.new(
        model: 'fake-model', provider: :openai, assume_model_exists: true,
        api_base: 'http://fake.invalid/v1', api_key: 'not-needed',
        context_window: 8192, faraday_adapter: recorder
      )
    end

    it 'keeps an injected reference block out of a tool call/result pair, as a wrapped :user turn' do
      captured = []
      interloper = Pikuri::Agent::Control::Interloper.new
      transport = recording_transport(captured) do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
      end
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent',
                                interloper: interloper) do |c|
        c.add_tool Pikuri::Tool::CALCULATOR
        # Enqueue from inside the turn, the way a path-activation listener does.
        c.add_listener(Class.new(Pikuri::Agent::Listener::Base) do
          define_method(:initialize) { |i| @interloper = i }
          define_method(:on_event) do |event|
            @interloper.inject_system_message('reference text') if event.is_a?(Pikuri::Agent::Event::ToolCall)
          end
        end.new(interloper))
      end

      agent.run_loop(user_message: 'What is 2 + 2?')

      messages = captured.last['messages']
      roles = messages.map { |m| m['role'] }
      # The block lands *after* the :tool message answering the call, never
      # between the assistant's tool_calls and that result.
      assert_equal %w[system user assistant tool user], roles
      # Exactly one system message, and it is the prompt at index 0. This is the
      # assertion the eaten-injection bug needed: a mid-conversation :system
      # message is in the payload, renders in the listener stream, and sits in
      # the history — and some chat templates never show it to the model.
      assert_equal 0, roles.rindex('system')
      assert_equal "<system-reminder>\nreference text\n</system-reminder>", messages.last['content']
    ensure
      agent&.close
    end

    it 'sends a :system message as the system role, not OpenAI\'s newer developer role' do
      captured = []
      transport = recording_transport(captured) { |llm| llm.reply('hi') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')

      agent.run_loop(user_message: 'hi')

      # A local llama.cpp hands the role straight to the model's chat template,
      # and no Qwen/Llama template has seen `developer`.
      assert_equal 'system', captured.first['messages'].first['role']
    ensure
      agent&.close
    end
  end

  it 'raises a clear error when the script runs dry' do
    listener = capture_class.new
    # Only one turn scripted, but a tool_call forces a second request.
    transport = Pikuri::Testing.fake_transport { |llm| llm.tool_call('calculator', expression: '2 + 2') }
    agent = build_agent(transport, listener)

    error = assert_raises(RuntimeError) { agent.run_loop(user_message: 'What is 2 + 2?') }
    assert_includes error.message, 'no scripted response left'
  ensure
    agent&.close
  end
end
