# frozen_string_literal: true

RSpec.describe Pikuri::Agent::History do
  H = Pikuri::Agent::History unless defined?(H)

  # A conversation exercising every field: a typed user turn, an
  # assistant tool-call turn with thinking + usage, the tool result carrying an
  # image, and an injected reference block.
  let(:png) { (+"\x89PNG\r\n\x1a\n").b + ('payload' * 4).b }
  let(:history) do
    H.new(messages: [
            H::Message.new(id: 'm1', role: 'user', content: 'show me a.png'),
            H::Message.new(id: 'm2', role: 'assistant', content: '', model_id: 'qwen3-35b',
                           tool_calls: [H::ToolCall.new(id: 'call_1', name: 'read',
                                                        arguments: { 'path' => 'a.png' })],
                           thinking: H::Thinking.new(text: 'ponder', signature: 'SIG=='),
                           tokens: H::Tokens.new(input: 100, output: 7, cached: 20,
                                                 cache_creation: nil, thinking: nil)),
            H::Message.new(id: 'm3', role: 'tool', tool_call_id: 'call_1',
                           content: 'Read image: a.png',
                           attachments: [Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png)]),
            H::Message.new(id: 'm4', role: 'user', kind: 'reference',
                           content: '<system-reminder>recalled</system-reminder>')
          ])
  end

  describe 'round-tripping' do
    it 'survives a trip through RubyLLM message objects' do
      back = history.messages.map do |m|
        H::Message.from_ruby_llm(m.to_ruby_llm, id: m.id, kind: m.kind)
      end
      assert_equal history, H.new(messages: back)
    end

    it 'normalizes attachment bytes to binary, so identical content compares equal' do
      utf8 = Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png.dup.force_encoding('UTF-8'))
      assert_equal Pikuri::Attachment.new(mime: 'image/png', filename: 'a.png', bytes: png), utf8
    end
  end

  describe '#repair_interrupted_tool_calls' do
    def assistant(calls)
      H::Message.new(id: 'a', role: 'assistant', content: '',
                     tool_calls: calls.map { |c| H::ToolCall.new(id: c, name: 'read', arguments: {}) })
    end

    it 'is a no-op when every call was answered' do
      h = H.new(messages: [assistant(%w[c1]),
                           H::Message.new(id: 'b', role: 'tool', tool_call_id: 'c1', content: 'ok')])
      assert_same h, h.repair_interrupted_tool_calls
    end

    it 'synthesizes a result for a call that never got one' do
      repaired = H.new(messages: [assistant(%w[c1])]).repair_interrupted_tool_calls

      assert_equal %w[assistant tool], repaired.messages.map(&:role)
      assert_equal 'c1', repaired.messages.last.tool_call_id
      assert_equal H::INTERRUPTED_RESULT, repaired.messages.last.content
    end

    it 'fills only the unanswered calls of a partly-answered batch, after the real results' do
      h = H.new(messages: [assistant(%w[c1 c2 c3]),
                           H::Message.new(id: 'b', role: 'tool', tool_call_id: 'c2', content: 'ok')])

      repaired = h.repair_interrupted_tool_calls

      # The answering run stays contiguous, real results first.
      assert_equal %w[assistant tool tool tool], repaired.messages.map(&:role)
      assert_equal %w[c2 c1 c3], repaired.messages.drop(1).map(&:tool_call_id)
      assert_equal ['ok'], repaired.messages.drop(1).map(&:content).uniq - [H::INTERRUPTED_RESULT]
    end

  end

  describe '.mint_id' do
    it 'sorts in mint order, so ordering falls out of the id itself' do
      ids = Array.new(50) { H.mint_id }
      assert_equal ids, ids.sort
      assert_equal ids.size, ids.uniq.size
    end
  end
end
