# frozen_string_literal: true

require 'json'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# The claim {Pikuri::Agent#load_history!} has to earn: reloading an exported
# conversation produces *no observable change to the model*. Asserted where it
# actually matters — the bytes on the wire — using the fake transport, so the
# whole property is pinned offline.
RSpec.describe 'Pikuri::Agent history round trip' do
  # Records every outbound request body, then serves the scripted replies.
  def recording_transport(captured, model: 'fake-model', &script_block)
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
      model: model, provider: :openai, assume_model_exists: true,
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

  describe 'a user-attached image' do
    let(:png) { (+"\x89PNG\r\n\x1a\n").b + ('pixels' * 8).b }
    let(:image) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: png) }

    # Each turn's request body, after an optional reload between the turns.
    # +text+ is the first turn's text; +nil+ makes it attachment-only.
    def bodies(text:, &reload)
      captured = []
      transport = recording_transport(captured) do |llm|
        llm.reply('Red on the left, blue on the right.')
        llm.reply('Yes.')
      end
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
      agent.run_loop(user_message: text, attachments: [image])
      reload&.call(agent)
      agent.run_loop(user_message: 'Are you sure?')
      captured
    ensure
      agent&.close
    end

    def user_content(body) = body['messages'].find { |m| m['role'] == 'user' }['content']

    it 'reaches the wire as an image_url part beside the text' do
      first = user_content(bodies(text: "What's in it?").first)

      assert_equal({ 'type' => 'text', 'text' => "What's in it?" }, first[0])
      assert_equal 'image_url', first[1]['type']
      assert_equal "data:image/png;base64,#{[png].pack('m0')}", first[1]['image_url']['url']
    end

    it 'sends no text part on an attachment-only turn, before and after a reload' do
      plain = bodies(text: nil)
      reloaded = bodies(text: nil) { |a| a.load_history!(Pikuri::Agent::History.parse(a.export_history.to_json)) }

      assert_equal ['image_url'], user_content(plain.first).map { |p| p['type'] }
      assert_equal plain.last, reloaded.last
    end

    it 'sends byte-identical requests after a save to disk and a load back' do
      Dir.mktmpdir do |dir|
        plain = bodies(text: "What's in it?")
        reloaded = bodies(text: "What's in it?") do |a|
          a.export_history.save(dir)
          a.load_history!(Pikuri::Agent::History.load(dir))
        end

        assert_equal plain.last, reloaded.last
      end
    end
  end

  # A thinking block belongs to the model that produced it: replayed to another
  # one it lands in a slot the receiver reads as its own scratchpad. So it is
  # withheld from the *wire* while staying in the *record*.
  # See design/decisions.md D_thinking_block_replay.
  describe 'thinking blocks and a model switch' do
    H = Pikuri::Agent::History unless defined?(H)

    def history_from(model_id)
      H.new(messages: [
              H::Message.new(id: 'm1', role: 'user', content: 'hi'),
              H::Message.new(id: 'm2', role: 'assistant', content: 'hello', model_id: model_id,
                             thinking: H::Thinking.new(text: 'private reasoning', signature: 'SIG'))
            ])
    end

    # The assistant turn as the provider saw it on the next request.
    def replayed_assistant(captured)
      captured.last['messages'].find { |m| m['role'] == 'assistant' }
    end

    it 'withholds a foreign turn\'s thinking from the wire' do
      captured = []
      transport = recording_transport(captured) { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
      agent.load_history!(history_from('some-other-model'))
      agent.run_loop(user_message: 'and?')

      msg = replayed_assistant(captured)
      assert_equal 'hello', msg['content']
      refute msg.key?('reasoning_content'), 'foreign reasoning reached the provider'
      refute msg.key?('reasoning_signature')
    end

    it "replays the same model's own thinking, since attribution still holds" do
      captured = []
      transport = recording_transport(captured) { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
      agent.load_history!(history_from('fake-model'))
      agent.run_loop(user_message: 'and?')

      assert_equal 'private reasoning', replayed_assistant(captured)['reasoning_content']
    end

    it 'treats unrecorded provenance as foreign rather than assuming a match' do
      captured = []
      transport = recording_transport(captured) { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
      agent.load_history!(history_from(nil))
      agent.run_loop(user_message: 'and?')

      refute replayed_assistant(captured).key?('reasoning_content')
    end

    it 'keeps a withheld block in the record, so save/load cycles do not erode it' do
      transport = recording_transport([]) { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
      agent.load_history!(history_from('some-other-model'))

      2.times do
        exported = agent.export_history.messages.find { |m| m.role == 'assistant' }
        assert_equal 'private reasoning', exported.thinking.text
        assert_equal 'SIG', exported.thinking.signature
        agent.load_history!(agent.export_history)
      end
    ensure
      agent&.close
    end

    it 'strips thinking on a switch mid-conversation, which load time cannot cover' do
      captured = []
      first = recording_transport(captured) { |llm| llm.reply('ok') }
      agent = Pikuri::Agent.new(transport: first, system_prompt: 'test agent')
      agent.load_history!(history_from('fake-model'))
      agent.run_loop(user_message: 'and?')
      assert_equal 'private reasoning', replayed_assistant(captured)['reasoning_content'],
                   'precondition: its own model replays it'

      second = recording_transport(captured, model: 'other-fake-model') { |llm| llm.reply('ok') }
      agent.run_loop(user_message: 'still?', transport: second)

      refute replayed_assistant(captured).key?('reasoning_content')
      # and the record still has it, re-keyed onto the rebuilt message
      assert_equal 'private reasoning',
                   agent.export_history.messages.find { |m| m.role == 'assistant' }.thinking.text
    ensure
      agent&.close
    end

    it 'keeps message ids stable when a switch rebuilds the message' do
      captured = []
      agent = Pikuri::Agent.new(transport: recording_transport(captured) { |llm| llm.reply('ok') },
                                system_prompt: 'test agent')
      agent.load_history!(history_from('fake-model'))
      before = agent.export_history.messages.map(&:id)

      second = recording_transport(captured, model: 'other-fake-model') { |llm| llm.reply('ok') }
      agent.run_loop(user_message: 'switch', transport: second)

      assert_equal before, agent.export_history.messages.map(&:id).first(before.size)
    ensure
      agent&.close
    end
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

    it 'keeps the display strings, which nothing could recompute on reload' do
      agent.run_loop(user_message: 'What is 2 + 2?')
      history = agent.export_history

      call = history.messages[1].tool_calls.first
      assert_equal 'Calculator', call.display_name
      assert_equal '2 + 2', call.argument
      assert_equal '4', history.messages[2].summary
    end

    it 'round-trips the display strings through the JSON and back out again' do
      agent.run_loop(user_message: 'What is 2 + 2?')
      reloaded = Pikuri::Agent::History.parse(agent.export_history.to_json)

      agent.load_history!(reloaded)
      again = agent.export_history

      assert_equal 'Calculator', again.messages[1].tool_calls.first.display_name
      assert_equal '2 + 2', again.messages[1].tool_calls.first.argument
      assert_equal '4', again.messages[2].summary
    end

    it 'loads a pre-summary file with nils rather than refusing it' do
      agent.run_loop(user_message: 'What is 2 + 2?')
      raw = agent.export_history.to_h
      raw['messages'].each do |m|
        m.delete('summary')
        (m['tool_calls'] || []).each { |c| c.delete('display_name') && c.delete('argument') }
      end

      old = Pikuri::Agent::History.from_h(raw)

      assert_nil old.messages[1].tool_calls.first.display_name
      assert_nil old.messages[2].summary
      # And an absent string is simply absent again on the way out.
      refute_includes old.to_h['messages'][2].keys, 'summary'
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
