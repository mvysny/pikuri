# frozen_string_literal: true

require 'agent'

RSpec.describe Agent::Synthesizer do
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
    # Synth chat fake: records what Synthesizer pokes at it, and on
    # +#ask+ appends a synthetic assistant message so the return-value
    # lookup at the end of +.run+ has something to find.
    let(:synth_chat_class) do
      Class.new do
        attr_reader :asks, :instructions, :messages, :attach_count

        def initialize
          @asks = []
          @messages = []
          @attach_count = 0
        end

        def with_instructions(text)
          @instructions = text
          self
        end

        def after_message(&_);     @attach_count += 1; end
        def before_tool_call(&_);  @attach_count += 1; end
        def after_tool_result(&_); @attach_count += 1; end

        def ask(prompt)
          @asks << prompt
          @messages << RubyLLM::Message.new(role: :assistant, content: 'rescued answer')
          nil
        end
      end
    end

    let(:synth_chat)    { synth_chat_class.new }
    let(:listener)      { Agent::Listener::InMemoryList.new }
    let(:listener_list) { Agent::ListenerList.new([listener]) }

    it 'sets the synth system prompt on the chat' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listener_list)

      assert_equal Agent::Synthesizer::SYSTEM_PROMPT, synth_chat.instructions
    end

    it 'attaches every listener to the synth chat' do
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listener_list)

      # InMemoryList (a MessageListener) wires three Chat callbacks.
      assert_equal 3, synth_chat.attach_count
    end

    it 'asks the chat with the build_prompt output' do
      expected = described_class.build_prompt(parent_messages: [], user_message: 'q?')
      described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listener_list)

      assert_equal [expected], synth_chat.asks
    end

    it "returns the synth's final assistant content" do
      result = described_class.run(chat: synth_chat, parent_messages: [], user_message: 'q?', listeners: listener_list)

      assert_equal 'rescued answer', result
    end
  end
end
