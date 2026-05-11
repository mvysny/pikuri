# frozen_string_literal: true

require 'agent'

RSpec.describe Agent::Listener::InMemoryList do
  let(:listener) { described_class.new }

  it 'starts with no events' do
    assert_equal [], listener.events
  end

  it 'appends every message it receives, preserving order' do
    sequence = [
      Agent::Message::User.new(content: 'hi'),
      Agent::Message::Thinking.new(content: 'pondered'),
      Agent::Message::Assistant.new(content: 'reply'),
      Agent::Message::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }),
      Agent::Message::ToolResult.new(content: 'done')
    ]
    sequence.each { |m| listener.on_message(m) }

    assert_equal sequence, listener.events
  end

  describe '#to_s' do
    it 'renders as "InMemoryList"' do
      assert_equal 'InMemoryList', described_class.new.to_s
    end
  end
end
