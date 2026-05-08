# frozen_string_literal: true

require 'json'
require 'chat_response'

RSpec.describe ChatParser do
  let(:get_weather) do
    Tool.new(
      name: 'get_weather',
      description: 'Gets the current weather for a location.',
      parameters: Tool::Parameters.build do |p|
        p.required_string :location, 'City and country, e.g. "Tokyo, Japan".'
        p.optional_string :unit, 'Temperature unit (celsius or fahrenheit).'
      end,
      execute: ->(location:, unit: nil) { "weather(#{location}, #{unit.inspect})" }
    )
  end

  let(:create_event) do
    Tool.new(
      name: 'create_calendar_event',
      description: 'Creates a calendar event.',
      parameters: Tool::Parameters.build do |p|
        p.required_string :title, 'Event title.'
        p.required_string :date, 'Date in ISO 8601 format.'
        p.required_string :time, '24h time, e.g. 14:00.'
        p.required_integer :duration_minutes, 'Duration in minutes.'
      end,
      execute: ->(**) { 'created' }
    )
  end

  let(:parser) { described_class.new(tools: [get_weather, create_event]) }

  describe '#parse on the formatted fixture' do
    let(:body) do
      path = File.expand_path('fixtures/llm_response_1.formatted.json', __dir__)
      JSON.parse(File.read(path))
    end
    let(:response) { parser.parse(body) }

    it 'recognizes the tool_calls finish reason' do
      assert_equal :tool_calls, response.finish_reason
    end

    it 'preserves the empty assistant message text' do
      assert_equal '', response.message
    end

    it 'preserves the reasoning_content from the thinking model' do
      assert response.reasoning.is_a?(String)
      assert_includes response.reasoning, 'get_weather'
      assert_includes response.reasoning, 'create_calendar_event'
    end

    it 'parses the single tool call into a ToolCall with the resolved Tool' do
      assert_equal 1, response.tool_calls.size
      tc = response.tool_calls[0]
      assert_same get_weather, tc.tool
      assert_equal({ 'location' => 'Tokyo, Japan' }, tc.arguments)
      assert_equal '0rGsHLjAQXxjhvn8IdAPxOLjx8XCvw8H', tc.id
    end

    it 'runs the tool call by validating arguments and calling execute' do
      assert_equal 'weather(Tokyo, Japan, nil)', response.tool_calls[0].run
    end
  end

  describe '#parse on a plain stop response' do
    let(:body) do
      {
        'choices' => [{
          'finish_reason' => 'stop',
          'index' => 0,
          'message' => {
            'role' => 'assistant',
            'content' => 'Hello there.',
            'reasoning_content' => 'thinking...'
          }
        }]
      }
    end

    it 'returns finish_reason :stop with empty tool_calls' do
      response = parser.parse(body)
      assert_equal :stop, response.finish_reason
      assert_equal 'Hello there.', response.message
      assert_equal 'thinking...', response.reasoning
      assert_equal [], response.tool_calls
    end

    it 'tolerates a missing reasoning_content (non-thinking models)' do
      body['choices'][0]['message'].delete('reasoning_content')
      assert_nil parser.parse(body).reasoning
    end
  end

  describe 'loud failures' do
    def tool_calls_body(tool_calls)
      {
        'choices' => [{
          'finish_reason' => 'tool_calls',
          'index' => 0,
          'message' => { 'role' => 'assistant', 'content' => '', 'tool_calls' => tool_calls }
        }]
      }
    end

    it 'raises when finish_reason is tool_calls but tool_calls is empty' do
      err = assert_raises(RuntimeError) { parser.parse(tool_calls_body([])) }
      assert_includes err.message, 'tool_calls is empty'
    end

    it 'raises when finish_reason is tool_calls but tool_calls is missing entirely' do
      body = tool_calls_body([])
      body['choices'][0]['message'].delete('tool_calls')
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'tool_calls is empty or missing'
    end

    it 'raises when a tool_call references a tool not in the parser' do
      body = tool_calls_body([{
        'type' => 'function',
        'id' => 'call_1',
        'function' => { 'name' => 'unknown_tool', 'arguments' => '{}' }
      }])
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'unknown tool `unknown_tool`'
      assert_includes err.message, '`get_weather`'
    end

    it 'raises when function.arguments is not valid JSON' do
      body = tool_calls_body([{
        'type' => 'function',
        'id' => 'call_1',
        'function' => { 'name' => 'get_weather', 'arguments' => '{not json' }
      }])
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'not valid JSON'
    end

    it 'raises when function.arguments decodes to a non-object (e.g. an array)' do
      body = tool_calls_body([{
        'type' => 'function',
        'id' => 'call_1',
        'function' => { 'name' => 'get_weather', 'arguments' => '[]' }
      }])
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'did not decode to an object'
    end

    it 'raises when tool_call.type is not function' do
      body = tool_calls_body([{
        'type' => 'something_else',
        'id' => 'call_1',
        'function' => { 'name' => 'get_weather', 'arguments' => '{}' }
      }])
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'type is not `function`'
    end

    it 'raises when tool_call.id is missing' do
      body = tool_calls_body([{
        'type' => 'function',
        'function' => { 'name' => 'get_weather', 'arguments' => '{}' }
      }])
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'missing id'
    end

    it 'raises on unknown finish_reason' do
      body = { 'choices' => [{ 'finish_reason' => 'wat', 'message' => { 'content' => '' } }] }
      err = assert_raises(RuntimeError) { parser.parse(body) }
      assert_includes err.message, 'Unknown finish_reason `wat`'
    end

    it 'raises when choices is not exactly one element' do
      err = assert_raises(RuntimeError) { parser.parse({ 'choices' => [] }) }
      assert_includes err.message, 'Expected exactly 1 choice'
    end

    it 'raises when the body is not a Hash' do
      assert_raises(RuntimeError) { parser.parse('not a hash') }
    end
  end
end

RSpec.describe ChatResponse::ToolCall do
  it 'forwards #run to Tool#run with the decoded arguments hash' do
    seen = nil
    tool = Tool.new(
      name: 'echo',
      description: 'echo',
      parameters: Tool::Parameters.build { |p| p.required_string :text, 't' },
      execute: ->(text:) { seen = text; "got: #{text}" }
    )
    tc = described_class.new(tool: tool, arguments: { 'text' => 'hi' }, id: 'call_x')
    assert_equal 'got: hi', tc.run
    assert_equal 'hi', seen
  end
end
