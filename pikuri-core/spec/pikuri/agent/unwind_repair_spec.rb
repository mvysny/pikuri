# frozen_string_literal: true

require 'pikuri/testing'

# An unwind out of a tool batch leaves the assistant's tool_calls message with
# no :tool reply, which OpenAI and Anthropic 400 on and a local llama.cpp
# silently improvises around — so these specs assert the *wire body of the next
# turn*, not just the event stream. See Agent#run_loop's "Repairing an unwound
# tool batch".
RSpec.describe 'Pikuri::Agent unwound tool batch' do
  # Serves the scripted responses and keeps every request body, so a spec can
  # read exactly what the provider would have received.
  def recording_transport(captured, &script_block)
    script = Pikuri::Testing::Script.new
    script_block.call(script)
    base = Pikuri::Testing.build_adapter(script.responses)
    recorder = Class.new(base) do
      define_method(:call) { |env| captured << JSON.parse(env.body.to_s) and super(env) }
    end
    Pikuri::Agent::ChatTransport.new(
      model: 'fake-model', provider: :openai, assume_model_exists: true,
      api_base: 'http://fake.invalid/v1', api_key: 'not-needed',
      context_window: 8192, faraday_adapter: recorder
    )
  end

  # A no-arg tool whose body the spec supplies, so each case can raise, cancel,
  # or simply succeed from inside a real tool call.
  def probe_tool(name, &body)
    Pikuri::Tool.new(name: name, description: 'probe',
                     parameters: Pikuri::Tool::Parameters.build { |p| p.optional_string :x, 'x' },
                     execute: ->(x: nil) { body.call(x) })
  end

  # The tool results answering the last assistant turn, in order.
  def answers(agent)
    messages = agent.export_history.messages
    opener = messages.rindex { |m| m.role == 'assistant' && !m.tool_calls.empty? }
    messages[(opener + 1)..].select { |m| m.role == 'tool' }.map(&:content)
  end

  # Every tool_call id in the last assistant message has a :tool reply — the
  # shape a provider accepts.
  def assert_batch_answered(body)
    opener = body['messages'].select { |m| m['role'] == 'assistant' && m['tool_calls'] }.last
    refute_nil opener, 'expected an assistant turn carrying tool_calls'
    answered = body['messages'].filter_map { |m| m['tool_call_id'] if m['role'] == 'tool' }
    assert_equal opener['tool_calls'].map { |c| c['id'] }, answered
  end

  it 'blames the raising call and marks its siblings unrun, leaving a sendable conversation' do
    captured = []
    transport = recording_transport(captured) do |llm|
      llm.tool_batch(['boom', { x: 'a' }], ['boom', { x: 'b' }])
      llm.reply('recovered')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test') do |c|
      c.add_tool(probe_tool('boom') { raise TypeError, 'no implicit conversion' })
    end

    assert_raises(TypeError) { agent.run_loop(user_message: 'go') }

    assert_equal ['Error: TypeError: no implicit conversion',
                  Pikuri::Agent::FAILED_SKIPPED_RESULT], answers(agent)

    # The point of the whole exercise: the *next* turn is well-formed.
    agent.run_loop(user_message: 'and now?')
    assert_batch_answered(captured.last)
  ensure
    agent&.close
  end

  it 'distinguishes the cancelled call from the ones that never started' do
    captured = []
    cancellable = Pikuri::Agent::Control::Cancellable.new
    transport = recording_transport(captured) do |llm|
      llm.tool_batch(['probe', { x: 'a' }], ['probe', { x: 'b' }], ['probe', { x: 'c' }])
      llm.reply('recovered')
    end
    # The first call trips the flag and returns; the second raises at its
    # before_tool_call boundary, and the third never runs.
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test',
                              cancellable: cancellable) do |c|
      c.add_tool(probe_tool('probe') do |x|
        cancellable.cancel! if x == 'a'
        "ran #{x}"
      end)
    end

    assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { agent.run_loop(user_message: 'go') }

    assert_equal ['ran a', Pikuri::Agent::CANCELLED_RESULT, Pikuri::Agent::CANCELLED_SKIPPED_RESULT],
                 answers(agent)

    agent.run_loop(user_message: 'and now?')
    assert_batch_answered(captured.last)
  ensure
    agent&.close
  end

  it 'blames an exhausted budget on no call in particular' do
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_batch(['probe', { x: 'a' }], ['probe', { x: 'b' }], ['probe', { x: 'c' }])
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test',
                              step_limit: Pikuri::Agent::Control::StepLimit.new(max: 1)) do |c|
      c.add_tool(probe_tool('probe') { 'ok' })
    end

    assert_raises(Pikuri::Agent::Control::StepLimit::Exceeded) { agent.run_loop(user_message: 'go') }

    assert_equal ['ok', Pikuri::Agent::STEP_BUDGET_RESULT, Pikuri::Agent::STEP_BUDGET_RESULT],
                 answers(agent)
  ensure
    agent&.close
  end

  # $! is nil in an ensure once a rescue clause has completed normally, so this
  # is the one unwind whose cause has to be carried across by hand — and the
  # only sign of getting it wrong is the wording of a message nothing else reads.
  it 'still knows the cause when the budget was rescued into a synthesized answer' do
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_batch(['probe', { x: 'a' }], ['probe', { x: 'b' }])
      llm.reply('synthesized')
    end
    limit = Pikuri::Agent::Control::StepLimit.new(max: 1, on_exhausted: :synthesize)
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test', step_limit: limit) do |c|
      c.add_tool(probe_tool('probe') { 'ok' })
    end

    agent.run_loop(user_message: 'go')

    assert_equal 'synthesized', agent.last_assistant_content
    assert_equal ['ok', Pikuri::Agent::STEP_BUDGET_RESULT], answers(agent)
  ensure
    agent&.close
  end

  it 'emits each synthesized observation as a ToolResult so a host can render it' do
    events = []
    listener = Class.new(Pikuri::Agent::Listener::Base) do
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:on_event) { |e| @sink << e.content if e.is_a?(Pikuri::Agent::Event::ToolResult) }
    end
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_batch(['boom', { x: 'a' }], ['boom', { x: 'b' }])
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test') do |c|
      c.add_tool(probe_tool('boom') { raise TypeError, 'nope' })
      c.add_listener listener.new(events)
    end

    assert_raises(TypeError) { agent.run_loop(user_message: 'go') }

    assert_equal ['Error: TypeError: nope', Pikuri::Agent::FAILED_SKIPPED_RESULT], events
  ensure
    agent&.close
  end

  it 'marks a repaired call Interrupted, naming the call it answered' do
    events = []
    listener = Class.new(Pikuri::Agent::Listener::Base) do
      define_method(:initialize) { |sink| @sink = sink }
      define_method(:on_event) { |e| @sink << e if e.is_a?(Pikuri::Agent::Event::ToolResult) }
    end
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_batch(['boom', { x: 'a' }], ['boom', { x: 'b' }])
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test') do |c|
      c.add_tool(probe_tool('boom') { raise TypeError, 'nope' })
      c.add_listener listener.new(events)
    end

    assert_raises(TypeError) { agent.run_loop(user_message: 'go') }

    repaired = events.last
    assert_equal Pikuri::Agent::INTERRUPTED_SUMMARY, repaired.summary
    assert_equal 'boom', repaired.name
    refute_nil repaired.tool_call_id
  ensure
    agent&.close
  end

  it 'leaves a turn that answered every call alone' do
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.tool_batch(['probe', { x: 'a' }], ['probe', { x: 'b' }])
      llm.reply('done')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test') do |c|
      c.add_tool(probe_tool('probe') { |x| "ran #{x}" })
    end

    agent.run_loop(user_message: 'go')

    assert_equal ['ran a', 'ran b'], answers(agent)
  ensure
    agent&.close
  end
end
