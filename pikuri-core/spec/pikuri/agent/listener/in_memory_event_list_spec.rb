# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Listener::InMemoryEventList do
  let(:listener) { described_class.new }

  it 'starts with no events' do
    assert_equal [], listener.events
  end

  it 'appends every event it receives, preserving order' do
    sequence = [
      Pikuri::Agent::Event::UserTurn.new(content: 'hi'),
      Pikuri::Agent::Event::Thinking.new(content: 'pondered'),
      Pikuri::Agent::Event::Assistant.new(content: 'reply'),
      Pikuri::Agent::Event::ToolCall.new(name: 'echo', arguments: { 'text' => 'hi' }),
      Pikuri::Agent::Event::ToolResult.new(content: 'done')
    ]
    sequence.each { |e| listener.on_event(e) }

    assert_equal sequence, listener.events
  end

  describe '#to_s' do
    it 'renders as "InMemoryEventList"' do
      assert_equal 'InMemoryEventList', described_class.new.to_s
    end
  end
end
