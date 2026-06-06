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

  # Execution-side coverage (the synth running as a nested tools-free
  # Agent, listener propagation, the FallbackNotice, cancellation
  # precedence) lives in agent_spec.rb's "step-exhaustion policy"
  # describe — Synthesizer itself is a pure prompt builder.
end
