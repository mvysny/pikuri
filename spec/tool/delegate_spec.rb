# frozen_string_literal: true

require 'tool/delegate'
require 'chat_response'

RSpec.describe '.delegate' do
  # Stand-in for {OpenAIClient}: records every +chat+ call (the conversation
  # log it was called with and the +tools+ kwarg) and returns a canned
  # {ChatResponse}. Keeps the spec network-free.
  let(:fake_client_class) do
    Class.new do
      attr_reader :calls

      def initialize(response:)
        @response = response
        @calls = []
      end

      def chat(log, tools: [])
        @calls << { log: log, tools: tools }
        @response
      end
    end
  end

  let(:dummy_tool) do
    Tool.new(
      name: 'dummy',
      description: 'dummy',
      parameters: Tool::Parameters.build { |p| p.required_string :x, 'x' },
      execute: ->(x:) { x }
    )
  end

  let(:stop_response) do
    ChatResponse.new(
      finish_reason: :stop,
      message: 'sub-agent reply',
      reasoning: nil,
      tool_calls: []
    )
  end

  describe 'tool shape' do
    it 'returns a Tool named "delegate" with a required `task` string parameter' do
      client = fake_client_class.new(response: stop_response)
      tool = Tool.delegate(client: client, system_prompt: 'sp', tools: [])

      assert_kind_of Tool, tool
      assert_equal 'delegate', tool.name
      schema = tool.parameters.to_h
      assert_equal ['task'], schema[:required]
      assert_equal 'string', schema[:properties][:task][:type]
    end
  end

  describe 'execution' do
    it 'runs the sub-agent loop and returns its final assistant message' do
      client = fake_client_class.new(response: stop_response)
      tool = Tool.delegate(client: client, system_prompt: 'system!', tools: [dummy_tool])

      result = tool.run('task' => 'do the thing')

      assert_equal 'sub-agent reply', result
    end

    it 'sends the system prompt and the task as the sub-agent\'s first two messages' do
      client = fake_client_class.new(response: stop_response)
      tool = Tool.delegate(client: client, system_prompt: 'be terse', tools: [])
      tool.run('task' => 'count to three')

      assert_equal 1, client.calls.size
      messages = client.calls.first[:log].to_a
      assert_equal :system, messages[0].role
      assert_equal 'be terse', messages[0].content
      assert_equal :user, messages[1].role
      assert_equal 'count to three', messages[1].content
    end

    it 'advertises exactly the configured tool list to the sub-agent' do
      client = fake_client_class.new(response: stop_response)
      tool = Tool.delegate(client: client, system_prompt: 'sp', tools: [dummy_tool])
      tool.run('task' => 'go')

      assert_equal [dummy_tool], client.calls.first[:tools]
    end
  end
end
