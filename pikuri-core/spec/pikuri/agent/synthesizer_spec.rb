# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Synthesizer do
  describe '.build_prompt' do
    it 'wraps the user question and an empty Evidence section when no messages exist' do
      result = described_class.build_prompt(parent_messages: [], user_message: 'why is the sky blue?')

      assert_includes result, 'Question: why is the sky blue?'
      assert_includes result, 'Evidence gathered:'
    end

    it 'pairs each tool call with its matching tool-role result in chronological order' do
      tc1 = RubyLLM::ToolCall.new(id: 'c1', name: 'web_search',
                                  arguments: { 'query' => 'population of Reykjavik' })
      tc2 = RubyLLM::ToolCall.new(id: 'c2', name: 'web_search',
                                  arguments: { 'query' => 'population of Helsinki' })

      messages = [
        RubyLLM::Message.new(role: :user, content: 'compare two cities'),
        RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { 'c1' => tc1 }),
        RubyLLM::Message.new(role: :tool, content: 'Reykjavik ~ 130,000', tool_call_id: 'c1'),
        RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { 'c2' => tc2 }),
        RubyLLM::Message.new(role: :tool, content: 'Helsinki ~ 650,000', tool_call_id: 'c2')
      ]

      result = described_class.build_prompt(parent_messages: messages, user_message: 'compare two cities')

      # Reykjavik pair before Helsinki pair, both quote-formatted.
      reykjavik_call = result.index('Tool call: web_search(query="population of Reykjavik")')
      reykjavik_res  = result.index('Tool result: Reykjavik ~ 130,000')
      helsinki_call  = result.index('Tool call: web_search(query="population of Helsinki")')
      helsinki_res   = result.index('Tool result: Helsinki ~ 650,000')

      refute_nil reykjavik_call, "expected Reykjavik tool call to appear in:\n#{result}"
      refute_nil helsinki_call,  "expected Helsinki tool call to appear in:\n#{result}"
      assert reykjavik_call < reykjavik_res
      assert reykjavik_res  < helsinki_call
      assert helsinki_call  < helsinki_res
    end

    it 'drops tool calls that have no matching tool-role result (the call that triggered exhaustion)' do
      tc_done = RubyLLM::ToolCall.new(id: 'done', name: 'fetch',
                                      arguments: { 'url' => 'https://example.com' })
      tc_stranded = RubyLLM::ToolCall.new(id: 'stranded', name: 'web_search',
                                          arguments: { 'query' => 'never executed' })

      messages = [
        RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { 'done' => tc_done }),
        RubyLLM::Message.new(role: :tool, content: 'fetched body', tool_call_id: 'done'),
        # The exhausting tool call was emitted but never produced a :tool message.
        RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { 'stranded' => tc_stranded })
      ]

      result = described_class.build_prompt(parent_messages: messages, user_message: 'q?')

      assert_includes result, 'fetched body'
      refute_includes result, 'never executed', "stranded tool call should have been dropped from:\n#{result}"
    end

    it 'preserves non-empty assistant text content as Note lines' do
      messages = [
        RubyLLM::Message.new(role: :assistant, content: 'Plan: search for the answer.')
      ]

      result = described_class.build_prompt(parent_messages: messages, user_message: 'q?')

      assert_includes result, 'Note: Plan: search for the answer.'
    end

    it 'ignores user-role messages in parent_messages (the question is passed explicitly)' do
      messages = [
        RubyLLM::Message.new(role: :user, content: 'the original question')
      ]

      result = described_class.build_prompt(parent_messages: messages, user_message: 'q?')

      refute_includes result, 'Note: the original question'
    end
  end

  describe '.run' do
    # Synth chat fake: records what Synthesizer + Agent.wire_chat poke
    # at it, and on +#ask+ appends a synthetic assistant message so the
    # return-value lookup at the end of +.run+ has something to find.
    let(:synth_chat_class) do
      Class.new do
        attr_reader :asks, :instructions, :messages, :hooks, :stream_block

        def initialize
          @asks = []
          @messages = []
          @hooks = Hash.new { |h, k| h[k] = [] }
          @stream_block = nil
        end

        def with_instructions(text)
          @instructions = text
          self
        end

        def after_message(&b);     @hooks[:after_message] << b;     self; end
        def before_tool_call(&b);  @hooks[:before_tool_call] << b;  self; end
        def after_tool_result(&b); @hooks[:after_tool_result] << b; self; end

        def ask(prompt, &block)
          @asks << prompt
          @stream_block = block
          @messages << RubyLLM::Message.new(role: :assistant, content: 'rescued answer')
          nil
        end
      end
    end

    let(:synth_chat) { synth_chat_class.new }
    let(:listener)   { Pikuri::Agent::Listener::InMemoryEventList.new }
    let(:listeners)  { Pikuri::Agent::ListenerList.new([listener]) }

    it 'sets the synth system prompt on the chat' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listeners)

      assert_equal Pikuri::Agent::Synthesizer::SYSTEM_PROMPT, synth_chat.instructions
    end

    it 'wires the event stream on the synth chat (exactly one callback per channel)' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listeners)

      assert_equal 1, synth_chat.hooks[:after_message].size
      assert_equal 1, synth_chat.hooks[:before_tool_call].size
      assert_equal 1, synth_chat.hooks[:after_tool_result].size
    end

    it 'asks the chat with the build_prompt output' do
      expected = described_class.build_prompt(parent_messages: [], user_message: 'q?')
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listeners)

      assert_equal [expected], synth_chat.asks
    end

    it "returns the synth's final assistant content" do
      result = described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listeners)

      assert_equal 'rescued answer', result
    end

    it 'does not pass a streaming block when streaming: defaults to false' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listeners)

      assert_nil synth_chat.stream_block,
                 'expected non-streaming Synthesizer.run to call chat.ask without a block'
    end

    it 'passes a streaming block to the synth chat when streaming: true so synth deltas reach listeners' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?',
                          listeners: listeners, streaming: true)

      refute_nil synth_chat.stream_block, 'expected Synthesizer.run to pass a streaming block to chat.ask'

      chunk = Struct.new(:content, :thinking).new('synth-frag', nil)
      synth_chat.stream_block.call(chunk)

      assert_includes listener.events, Pikuri::Agent::Event::AssistantDelta.new(content: 'synth-frag')
    end

    it 'passes step_limit and cancellable through to wire_chat so the synth respects them' do
      cancel = Pikuri::Agent::Control::Cancellable.new
      step   = Pikuri::Agent::Control::StepLimit.new(max: 1)

      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?',
                          listeners: listeners, step_limit: step, cancellable: cancel)

      # Cancellation: trip the flag and fire before_tool_call — the
      # wired callback must call check! and raise.
      cancel.cancel!
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        synth_chat.hooks[:before_tool_call].each { |cb| cb.call(RubyLLM::ToolCall.new(id: 'x', name: 'n', arguments: {})) }
      end
    end
  end
end
