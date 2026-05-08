# frozen_string_literal: true

require 'openai_client'

RSpec.describe '.request_body' do
  let(:weather_tool) do
    Tool.new(
      name: 'get_weather',
      description: 'Gets the weather.',
      parameters: Tool::Parameters.build { |p| p.required_string :location, 'City and country.' },
      execute: ->(location:) { "weather: #{location}" }
    )
  end

  describe 'required envelope' do
    it 'includes the model and a messages array' do
      log = ChatLog.new.user('hello')
      body = OpenAIClient.request_body(log, tools: [], model: 'gpt-x')
      assert_equal 'gpt-x', body[:model]
      assert_equal [{ role: 'user', content: 'hello' }], body[:messages]
    end

    it 'omits the tools key entirely when no tools are advertised' do
      body = OpenAIClient.request_body(ChatLog.new.user('hi'), tools: [], model: 'm')
      refute body.key?(:tools), 'tools key should not be present for an empty tool list'
    end

    it 'serializes each tool through Tool#to_openai_schema' do
      body = OpenAIClient.request_body(ChatLog.new.user('hi'), tools: [weather_tool], model: 'm')
      assert_equal [weather_tool.to_openai_schema], body[:tools]
    end
  end

  describe 'message wire shapes' do
    it 'serializes :system and :user as plain {role, content}' do
      log = ChatLog.new
      log.system('be brief')
      log.user('what is 2+2?')
      body = OpenAIClient.request_body(log, tools: [], model: 'm')
      assert_equal(
        [
          { role: 'system', content: 'be brief' },
          { role: 'user', content: 'what is 2+2?' }
        ],
        body[:messages]
      )
    end

    it 'serializes a content-only assistant turn without a tool_calls key' do
      log = ChatLog.new.assistant(content: 'four')
      body = OpenAIClient.request_body(log, tools: [], model: 'm')
      msg = body[:messages].first
      assert_equal 'assistant', msg[:role]
      assert_equal 'four', msg[:content]
      refute msg.key?(:tool_calls)
    end

    it 'serializes assistant tool_calls in OpenAI function shape with JSON-encoded arguments' do
      tc = ChatResponse::ToolCall.new(
        tool: weather_tool, arguments: { 'location' => 'Tokyo, Japan' }, id: 'call_1'
      )
      log = ChatLog.new.assistant(content: '', tool_calls: [tc])
      body = OpenAIClient.request_body(log, tools: [weather_tool], model: 'm')
      msg = body[:messages].first
      assert_equal 'assistant', msg[:role]
      assert_equal '', msg[:content]
      assert_equal 1, msg[:tool_calls].size
      wire = msg[:tool_calls].first
      assert_equal 'function', wire[:type]
      assert_equal 'call_1', wire[:id]
      assert_equal 'get_weather', wire[:function][:name]
      assert_equal({ 'location' => 'Tokyo, Japan' }, JSON.parse(wire[:function][:arguments]))
    end

    it 'serializes :tool observations with role, content, and tool_call_id' do
      log = ChatLog.new.tool('Sunny, 22°C', tool_call_id: 'call_1')
      body = OpenAIClient.request_body(log, tools: [], model: 'm')
      assert_equal(
        [{ role: 'tool', content: 'Sunny, 22°C', tool_call_id: 'call_1' }],
        body[:messages]
      )
    end

    it 'replays a full tool-call round trip in order' do
      tc = ChatResponse::ToolCall.new(
        tool: weather_tool, arguments: { 'location' => 'Tokyo, Japan' }, id: 'call_1'
      )
      log = ChatLog.new
      log.system('helpful assistant')
      log.user('weather in Tokyo?')
      log.assistant(content: '', tool_calls: [tc])
      log.tool('Sunny, 22°C', tool_call_id: 'call_1')

      body = OpenAIClient.request_body(log, tools: [weather_tool], model: 'm')
      roles = body[:messages].map { |m| m[:role] }
      assert_equal %w[system user assistant tool], roles
      assert_equal 'call_1', body[:messages][2][:tool_calls].first[:id]
      assert_equal 'call_1', body[:messages][3][:tool_call_id]
    end
  end
end
