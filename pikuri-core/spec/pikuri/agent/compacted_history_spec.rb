# frozen_string_literal: true

require 'json'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# {Pikuri::Agent::Configurator#replace_compacted_history}: the conversation
# shrinks in place while the agent's wiring stands, asserted on the next
# request body — what the model actually sees.
RSpec.describe 'Pikuri::Agent compacted history' do
  # A fake transport that records every request body, then serves the script.
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

  # A summary standing in for everything before the conversation's last
  # message, which it keeps as-is, ids included.
  def compact(history)
    summary = Pikuri::Agent::History::Message.new(
      id: Pikuri::Agent::History.mint_id, role: 'user', kind: 'reference',
      content: 'Summary: the user asked for 2 + 2; it is 4.'
    )
    Pikuri::Agent::History.new(messages: [summary, history.messages.last])
  end

  # [role, content] of each message a request body carried.
  def wire(body)
    body['messages'].map { |m| [m['role'], m['content']] }
  end

  let(:captured) { [] }
  let(:recorder) { Pikuri::Agent::Listener::InMemoryEventList.new }

  after { @agent&.close }

  # Two turns, the first with a tool call. Answers the agent's Configurator.
  def converse
    transport = recording_transport(captured) do |llm|
      llm.tool_call('calculator', expression: '2 + 2')
      llm.reply('The answer is 4.')
      llm.reply('Yes, still 4.')
      llm.reply('Twice that is 8.')
    end
    configurator = nil
    @agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
      configurator = c
      c.add_tool Pikuri::Tool::CALCULATOR
      c.add_listener recorder
    end
    @agent.run_loop(user_message: 'What is 2 + 2?')
    @agent.run_loop(user_message: 'Are you sure?')
    configurator
  end

  it 'sends the compacted conversation next turn, tools and system prompt unchanged' do
    c = converse
    before = captured.last
    c.replace_compacted_history(compact(@agent.export_history))
    @agent.run_loop(user_message: 'And twice that?')

    assert_equal [['system', 'test agent'],
                  ['user', 'Summary: the user asked for 2 + 2; it is 4.'],
                  ['assistant', 'Yes, still 4.'],
                  ['user', 'And twice that?']],
                 wire(captured.last)
    assert_equal before['tools'], captured.last['tools']
  end

  it 'emits HistoryCompacted with the message counts' do
    c = converse
    c.replace_compacted_history(compact(@agent.export_history))

    assert_equal [Pikuri::Agent::Event::HistoryCompacted.new(messages_before: 6, messages_after: 2)],
                 recorder.events.grep(Pikuri::Agent::Event::HistoryCompacted)
  end

  it 'keeps the ids it was handed, so the next export carries them' do
    c = converse
    compacted = compact(@agent.export_history)
    c.replace_compacted_history(compacted)

    assert_equal compacted.messages.map(&:id), @agent.export_history.messages.map(&:id)
  end

  it 'compacts from on_user_message, before the turn goes out' do
    compactor = Class.new do
      include Pikuri::Agent::Extension

      def configure(c)
        @c = c
      end

      def on_user_message(_content, _attachments)
        @c.replace_compacted_history(Pikuri::Agent::History.new(messages: [@c.agent.export_history.messages.last]))
        nil
      end
    end
    transport = recording_transport(captured) do |llm|
      llm.reply('Hello.')
      llm.reply('Fine.')
    end
    @agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
      c.add_extension compactor.new
    end
    @agent.run_loop(user_message: 'Hi.')
    @agent.run_loop(user_message: 'How are you?')

    assert_equal [%w[system test\ agent], ['user', 'How are you?']], wire(captured.last)
  end

  describe 'refuses' do
    it 'a history that drops the conversation\'s last message, leaving it untouched' do
      c = converse
      history = @agent.export_history
      err = assert_raises(ArgumentError) do
        c.replace_compacted_history(Pikuri::Agent::History.new(messages: history.messages[0..-2]))
      end

      assert_match(/must end with the conversation's last message/, err.message)
      assert_equal history, @agent.export_history
    end

    it 'a tool result whose call was cut away' do
      c = converse
      messages = @agent.export_history.messages
      result = messages.find { |m| m.role == 'tool' }
      err = assert_raises(ArgumentError) do
        c.replace_compacted_history(Pikuri::Agent::History.new(messages: [result, messages.last]))
      end

      assert_match(/a call the assistant turn before it did not make/, err.message)
    end

    it 'while a tool batch is open' do
      transport = recording_transport(captured) do |llm|
        llm.tool_call('calculator', expression: '2 + 2')
        llm.reply('4.')
      end
      configurator = nil
      compact_on_call = Class.new(Pikuri::Agent::Listener::Base) do
        define_method(:on_event) do |event|
          next unless event.is_a?(Pikuri::Agent::Event::ToolCall)

          configurator.replace_compacted_history(Pikuri::Agent::History.new(messages: []))
        end
      end
      @agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent') do |c|
        configurator = c
        c.add_tool Pikuri::Tool::CALCULATOR
        c.add_listener compact_on_call.new
      end

      err = assert_raises(RuntimeError) { @agent.run_loop(user_message: 'What is 2 + 2?') }
      assert_match(/tool batch is open: calculator/, err.message)
    end

    it 'inside the Agent.new block' do
      err = assert_raises(RuntimeError) do
        Pikuri::Agent.new(transport: Pikuri::Testing.fake_transport, system_prompt: '') do |c|
          c.replace_compacted_history(Pikuri::Agent::History.new(messages: []))
        end
      end
      assert_match(/before Agent.new returned/, err.message)
    end

    it 'anything but a History' do
      c = converse
      assert_raises(ArgumentError) { c.replace_compacted_history([]) }
    end
  end

  it 'leaves TokenLog\'s snapshot for the next reply to correct' do
    log = Pikuri::Agent::Listener::TokenLog.new
    log.on_event(Pikuri::Agent::Event::Tokens.new(input: 30_000, output: 720, cached: 0,
                                                  cache_creation: 0, thinking: nil, model_id: 'm'))
    log.on_event(Pikuri::Agent::Event::HistoryCompacted.new(messages_before: 40, messages_after: 3))

    assert_equal 'compacted: 40 → 3 msgs, ctx was 30.0k', log.status_line
    assert_equal 30_720, log.context_window_size
  end
end
