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
