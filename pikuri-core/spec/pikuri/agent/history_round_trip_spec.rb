# frozen_string_literal: true

require 'json'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# The claim {Pikuri::Agent#load_history!} has to earn: reloading an exported
# conversation produces *no observable change to the model*. Asserted where it
# actually matters — the bytes on the wire — using the fake transport, so the
# whole property is pinned offline.
RSpec.describe 'Pikuri::Agent history round trip' do
  # Records every outbound request body, then serves the scripted replies.
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

  # Runs a tool-using conversation, then one more turn, and returns the request
  # body of that final turn — the thing the model actually sees.
  def final_body(reload:)
    captured = []
    transport = recording_transport(captured) do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('The answer is 4.')
      llm.reply('Yes, still 4.')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
      c.add_tool Pikuri::Tool::CALCULATOR
    end
    agent.run_loop(user_message: 'What is 2 + 2?')
    agent.load_history!(agent.export_history) if reload
    agent.run_loop(user_message: 'Are you sure?')
    captured.last
  ensure
    agent&.close
  end

  it 'sends byte-identical requests with and without a save/reload in between' do
    assert_equal final_body(reload: false), final_body(reload: true)
  end

  it 'survives the JSON encoding too, not just the in-memory value' do
    captured = []
    transport = recording_transport(captured) do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('The answer is 4.')
      llm.reply('Yes, still 4.')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
      c.add_tool Pikuri::Tool::CALCULATOR
    end
    agent.run_loop(user_message: 'What is 2 + 2?')
    agent.load_history!(Pikuri::Agent::History.parse(agent.export_history.to_json))
    agent.run_loop(user_message: 'Are you sure?')

    assert_equal final_body(reload: false), captured.last
  ensure
    agent&.close
  end

  describe 'what the export carries' do
    let(:agent) do
      transport = Pikuri::Testing.fake_transport do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('The answer is 4.')
      end
      Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
        c.add_tool Pikuri::Tool::CALCULATOR
      end
    end

    after { agent.close }

    it 'excludes the system prompt, so a reload gets a freshly assembled one' do
      agent.run_loop(user_message: 'What is 2 + 2?')

      refute_includes agent.export_history.messages.map(&:role), 'system'
    end

    it 'keeps the tool call paired with its result' do
      agent.run_loop(user_message: 'What is 2 + 2?')
      history = agent.export_history

      assert_equal %w[user assistant tool assistant], history.messages.map(&:role)
      call = history.messages[1].tool_calls.first
      assert_equal 'calculator', call.name
      assert_equal call.id, history.messages[2].tool_call_id
      # And the pairing survives the format's own validator.
      assert_equal history, Pikuri::Agent::History.parse(history.to_json)
    end

    it 'mints a stable id per message: exporting twice does not renumber' do
      agent.run_loop(user_message: 'What is 2 + 2?')

      assert_equal agent.export_history.messages.map(&:id), agent.export_history.messages.map(&:id)
    end

    it 'preserves ids across a reload, so a host reference stays valid' do
      agent.run_loop(user_message: 'What is 2 + 2?')
      before = agent.export_history

      agent.load_history!(before)

      assert_equal before.messages.map(&:id), agent.export_history.messages.map(&:id)
    end
  end

  describe 'kinds' do
    it 'marks an injected reference block, distinguishing it from a typed turn' do
      interloper = Pikuri::Agent::Control::Interloper.new
      transport = Pikuri::Testing.fake_transport { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent', interloper: interloper)
      interloper.inject_system_message('recalled memory')

      agent.run_loop(user_message: 'hello')

      kinds = agent.export_history.messages.map { |m| [m.role, m.kind] }
      assert_includes kinds, %w[user reference]
      assert_includes kinds, %w[user user]
    ensure
      agent&.close
    end
  end

  describe 'load_history!' do
    let(:agent) do
      transport = Pikuri::Testing.fake_transport { |llm| llm.reply('ok') }
      Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
    end

    after { agent.close }

    it 'refuses anything but a History, naming the parsing doors' do
      e = assert_raises(ArgumentError) { agent.load_history!([{ 'role' => 'user' }]) }
      assert_match(/History\.parse/, e.message)
    end

    it 'is idempotent across repeated calls, as a conversation switcher needs' do
      history = Pikuri::Agent::History.new(messages: [
                                             Pikuri::Agent::History::Message.new(id: 'm1', role: 'user',
                                                                                 content: 'hi')
                                           ])

      3.times { assert_equal 1, agent.load_history!(history) }
      assert_equal history, agent.export_history
    end

    it 'repairs an interrupted tool call on the way in' do
      history = Pikuri::Agent::History.new(messages: [
                                             Pikuri::Agent::History::Message.new(
                                               id: 'm1', role: 'assistant', content: '',
                                               tool_calls: [Pikuri::Agent::History::ToolCall.new(
                                                 id: 'c1', name: 'read', arguments: {}
                                               )]
                                             )
                                           ])

      assert_equal 2, agent.load_history!(history)
      restored = agent.export_history
      assert_equal 'c1', restored.messages.last.tool_call_id
      assert_equal Pikuri::Agent::History::INTERRUPTED_RESULT, restored.messages.last.content
    end

    it 'drops a thinking signature minted by a different model, keeping the text' do
      history = Pikuri::Agent::History.new(messages: [
                                             Pikuri::Agent::History::Message.new(
                                               id: 'm1', role: 'assistant', content: 'hi',
                                               model_id: 'some-other-model',
                                               thinking: Pikuri::Agent::History::Thinking.new(
                                                 text: 'ponder', signature: 'SIG=='
                                               )
                                             )
                                           ])

      agent.load_history!(history)

      thinking = agent.export_history.messages.first.thinking
      assert_equal 'ponder', thinking.text
      assert_nil thinking.signature
    end

    it 'keeps the signature when the model still matches' do
      history = Pikuri::Agent::History.new(messages: [
                                             Pikuri::Agent::History::Message.new(
                                               id: 'm1', role: 'assistant', content: 'hi',
                                               model_id: 'fake-model',
                                               thinking: Pikuri::Agent::History::Thinking.new(
                                                 text: 'ponder', signature: 'SIG=='
                                               )
                                             )
                                           ])

      agent.load_history!(history)

      assert_equal 'SIG==', agent.export_history.messages.first.thinking.signature
    end

    it 'emits Reset then HistoryLoaded, so a listener stops reporting an empty conversation' do
      events = []
      transport = Pikuri::Testing.fake_transport { |llm| llm.reply('ok') }
      listener = Class.new(Pikuri::Agent::Listener::Base) do
        define_method(:initialize) { |sink| @sink = sink }
        define_method(:on_event) { |e| @sink << e }
      end.new(events)
      loaded = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
        c.add_listener(listener)
      end

      loaded.load_history!(Pikuri::Agent::History.new(messages: [
                                                        Pikuri::Agent::History::Message.new(
                                                          id: 'm1', role: 'assistant', content: 'hi',
                                                          model_id: 'fake-model',
                                                          tokens: Pikuri::Agent::History::Tokens.new(
                                                            input: 900, output: 100, cached: 20,
                                                            cache_creation: nil, thinking: nil
                                                          )
                                                        )
                                                      ]))

      kinds = events.map(&:class)
      assert_equal [Pikuri::Agent::Event::Reset, Pikuri::Agent::Event::HistoryLoaded],
                   kinds.select { |k| [Pikuri::Agent::Event::Reset, Pikuri::Agent::Event::HistoryLoaded].include?(k) }
      history_loaded = events.find { |e| e.is_a?(Pikuri::Agent::Event::HistoryLoaded) }
      assert_equal 1, history_loaded.messages
      assert_equal 900, history_loaded.tokens.input
    ensure
      loaded&.close
    end
  end

  describe 'TokenLog seeding' do
    it 'reseeds the context readout from a restored history instead of showing zero' do
      log = Pikuri::Agent::Listener::TokenLog.new
      log.on_event(Pikuri::Agent::Event::ContextCap.new(cap: 32_768))
      log.on_event(Pikuri::Agent::Event::Reset.new)
      assert_equal 'TokenLog(ctx=0.0k/32.0k)', log.to_s

      log.on_event(Pikuri::Agent::Event::HistoryLoaded.new(
                     messages: 12,
                     tokens: Pikuri::Agent::Event::Tokens.new(
                       input: 8000, output: 200, cached: 192, cache_creation: nil,
                       thinking: nil, model_id: 'fake-model'
                     )
                   ))

      assert_equal 'TokenLog(ctx=8.2k/32.0k)', log.to_s
    end

    it 'leaves the snapshot alone when the history carried no usage' do
      log = Pikuri::Agent::Listener::TokenLog.new
      log.on_event(Pikuri::Agent::Event::HistoryLoaded.new(messages: 3, tokens: nil))

      assert_equal 'TokenLog(ctx=0.0k)', log.to_s
    end
  end
end
