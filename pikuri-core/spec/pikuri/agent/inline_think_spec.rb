# frozen_string_literal: true

require 'pikuri/testing'

# A server that leaves reasoning inline in +content+ (llama.cpp with
# +--reasoning-format none+, a template that does not split it out) must still
# surface it as thinking, not as answer text. Driven over the wire through the
# fake transport, so the whole path from the HTTP body to the events is covered.
RSpec.describe Pikuri::Agent, 'inline <think> tags' do
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

  def contents(listener, event_class)
    listener.events.grep(event_class).map(&:content)
  end

  it 'lifts a non-streamed <think> block out of the reply into Thinking' do
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport { |llm| llm.reply("<think>reasoning</think>\nanswer") }
    agent = Pikuri::Agent.new(transport:, system_prompt: 'test') { |c| c.add_listener listener }

    agent.run_loop(user_message: 'hi')

    assert_equal ['reasoning'], contents(listener, Pikuri::Agent::Event::Thinking)
    assert_equal ['answer'], contents(listener, Pikuri::Agent::Event::Assistant)
    assert_equal 'answer', agent.last_assistant_content
  ensure
    agent&.close
  end

  it 'replays the split turn without the tags, and exports the reasoning as thinking' do
    requests = []
    script = Pikuri::Testing::Script.new
    script.reply("<think>reasoning</think>\nanswer")
    script.reply('second')
    recorder = Class.new(Pikuri::Testing.build_adapter(script.responses)) do
      define_method(:call) do |env|
        requests << JSON.parse(env.body.to_s)
        super(env)
      end
    end
    transport = Pikuri::Testing.fake_transport.with(faraday_adapter: recorder)
    agent = Pikuri::Agent.new(transport:, system_prompt: 'test')

    agent.run_loop(user_message: 'one')
    agent.run_loop(user_message: 'two')

    replayed = requests.last['messages'].find { |m| m['role'] == 'assistant' }
    assert_equal 'answer', replayed['content']
    exported = agent.export_history.messages.find { |m| m.role == 'assistant' }
    assert_equal 'reasoning', exported.thinking.text
  ensure
    agent&.close
  end

  it 'lifts the tags out of a loaded history, so a model switch withholds the reasoning' do
    requests = []
    script = Pikuri::Testing::Script.new
    script.reply('second')
    recorder = Class.new(Pikuri::Testing.build_adapter(script.responses)) do
      define_method(:call) do |env|
        requests << JSON.parse(env.body.to_s)
        super(env)
      end
    end
    transport = Pikuri::Testing.fake_transport.with(faraday_adapter: recorder)
    agent = Pikuri::Agent.new(transport:, system_prompt: 'test')
    history = Pikuri::Agent::History.new(messages: [
      Pikuri::Agent::History::Message.new(id: 'u', role: 'user', content: 'one'),
      Pikuri::Agent::History::Message.new(id: 'a', role: 'assistant', model_id: 'another-model',
                                          content: "<think>reasoning</think>\nanswer")
    ])

    agent.load_history!(history)
    agent.run_loop(user_message: 'two')

    replayed = requests.last['messages'].find { |m| m['role'] == 'assistant' }
    assert_equal 'answer', replayed['content']
    refute_includes JSON.generate(requests.last), 'reasoning'
    exported = agent.export_history.messages.find { |m| m.role == 'assistant' }
    assert_equal 'reasoning', exported.thinking.text
  ensure
    agent&.close
  end

  it 'routes a streamed <think> block to ThinkingDelta, even with tags split across chunks' do
    listener = capture_class.new
    transport = Pikuri::Testing.fake_transport do |llm|
      llm.stream('<thi', 'nk>reas', 'oning</th', "ink>\nans", 'wer')
    end
    agent = Pikuri::Agent.new(transport:, system_prompt: 'test', streaming: true) do |c|
      c.add_listener listener
    end

    agent.run_loop(user_message: 'hi')

    # Deltas only, joined: how a shell slices them is not the contract, but no
    # fragment of a tag may reach either stream.
    assert_equal 'reasoning', contents(listener, Pikuri::Agent::Event::ThinkingDelta).join
    assert_equal 'answer', contents(listener, Pikuri::Agent::Event::AssistantDelta).join
    assert_equal ['reasoning'], contents(listener, Pikuri::Agent::Event::Thinking)
    assert_equal ['answer'], contents(listener, Pikuri::Agent::Event::Assistant)
  ensure
    agent&.close
  end
end
