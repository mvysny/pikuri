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
      Pikuri::Agent::Event::ToolCall.new(tool_call_id: 'c1', name: 'echo', arguments: { 'text' => 'hi' },
                                         display_name: 'Echo', argument: 'hi'),
      Pikuri::Agent::Event::ToolResult.new(tool_call_id: 'c1', name: 'echo', content: 'done',
                                           summary: 'Returned 4 bytes')
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
