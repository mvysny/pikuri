# frozen_string_literal: true

require 'json'
require 'pikuri/testing' # opt-in scaffolding, not loaded by pikuri-core boot

# What `ChatTransport#params` has to earn: the table reaches the *request body*,
# unchanged, and follows the transport across a model switch. Asserted on the
# bytes on the wire, since a parameter that is silently not applied is the whole
# failure mode this channel exists to avoid.
RSpec.describe 'Pikuri::Agent request params' do
  # A {Pikuri::Testing.fake_transport} whose adapter records every outbound
  # request body *as sent* — the raw JSON, not a re-parse, so a key emitted
  # twice is still visible.
  def recording_transport(captured, params: {}, model: 'fake-model', &script_block)
    fake = Pikuri::Testing.fake_transport(model: model, params: params, &script_block)
    recorder = Class.new(fake.faraday_adapter) do
      define_method(:call) do |env|
        captured << env.body.to_s
        super(env)
      end
    end
    fake.with(faraday_adapter: recorder)
  end

  def raw_body_for(params:)
    captured = []
    transport = recording_transport(captured, params: params) { |llm| llm.reply('ok') }
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
    agent.run_loop(user_message: 'hi')
    captured.last
  ensure
    agent&.close
  end

  def body_for(params:)
    JSON.parse(raw_body_for(params: params))
  end

  it 'sends a params table as top-level request keys, verbatim' do
    body = body_for(params: { 'chat_template_kwargs' => { 'enable_thinking' => false } })
    assert_equal({ 'enable_thinking' => false }, body['chat_template_kwargs'])
  end

  it 'sends nothing extra when the table is empty' do
    refute_includes body_for(params: {}).keys, 'chat_template_kwargs'
  end

  it 'leaves the payload ruby_llm built otherwise intact' do
    body = body_for(params: { 'min_p' => 0.05 })
    assert_equal 'fake-model', body['model']
    assert_equal 'hi', body['messages'].last['content']
    assert_equal 0.05, body['min_p']
  end

  # The merge is unguarded on purpose, so overriding a key ruby_llm itself set
  # is reachable — and it is the case that pins the symbolizing: a string-keyed
  # table merging *beside* ruby_llm's symbol key would emit the JSON name twice
  # and leave which one wins to the server's parser. Hence the assertion on the
  # raw bytes: a re-parsed body has already collapsed the duplicate.
  it 'overrides a key ruby_llm already set, rather than sending it twice' do
    raw = raw_body_for(params: { 'model' => 'override-me' })
    assert_equal 1, raw.scan('"model"').size
    assert_equal 'override-me', JSON.parse(raw)['model']
  end

  it 'keeps the params across a model switch on the same transport shape' do
    captured = []
    transport = recording_transport(captured, params: { 'min_p' => 0.05 }) do |llm|
      llm.reply('one')
      llm.reply('two')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
    agent.run_loop(user_message: 'hi')
    agent.run_loop(user_message: 'again', transport: transport.with(model: 'other-model'))
    last = JSON.parse(captured.last)
    assert_equal 0.05, last['min_p']
    assert_equal 'other-model', last['model']
  ensure
    agent&.close
  end

  it 'drops the params when the switch is to a connection carrying none' do
    captured = []
    transport = recording_transport(captured, params: { 'min_p' => 0.05 }) do |llm|
      llm.reply('one')
      llm.reply('two')
    end
    agent = Pikuri::Agent.new(transport: transport, system_prompt: 'test agent')
    agent.run_loop(user_message: 'hi')
    agent.run_loop(user_message: 'again', transport: transport.with(model: 'plain', params: {}))
    refute_includes JSON.parse(captured.last).keys, 'min_p'
  ensure
    agent&.close
  end
end
