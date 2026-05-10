# frozen_string_literal: true

require 'tool'

RSpec.describe Tool do
  let(:tool) do
    described_class.new(
      name: 'echo',
      description: 'Echoes the input back.',
      parameters: Tool::Parameters.build { |p| p.required_string :text, 'Text to echo.' },
      execute: ->(text:) { "echo: #{text}" }
    )
  end

  describe '#run' do
    it 'validates and forwards kwargs to the execute Proc' do
      assert_equal 'echo: hi', tool.run('text' => 'hi')
    end

    it 'returns an "Error: ..." string for invalid arguments and does not call execute' do
      called = false
      tool_with_spy = described_class.new(
        name: 'spy',
        description: 'spy',
        parameters: Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { called = true; text }
      )
      result = tool_with_spy.run({})
      assert result.start_with?('Error:'), "expected error string, got #{result.inspect}"
      assert_includes result, '`text`'
      refute called, 'execute must not be called when validation fails'
    end

    it 'lets non-ValidationError exceptions from execute bubble up' do
      tool_that_blows_up = described_class.new(
        name: 'boom',
        description: 'boom',
        parameters: Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { _ = text; raise 'parser bug' }
      )
      assert_raises(RuntimeError) { tool_that_blows_up.run('text' => 'hi') }
    end
  end

  describe 'RubyLLM::Tool integration' do
    # Same shape ruby_llm's Chat will see: it does `tool.new` and then routes
    # tool calls through `instance.call(args)`. We bypass Chat here and drive
    # `Tool#call` directly so the test stays network-free and pinned to the
    # exact integration seam.

    it 'is a RubyLLM::Tool subclass that advertises pikuri\'s schema' do
      assert_operator tool, :<, RubyLLM::Tool
      schema = tool.new.params_schema
      assert_equal 'echo', tool.name
      assert_equal 'Echoes the input back.', tool.description
      assert_equal 'object', schema['type']
      assert_equal 'string', schema['properties']['text']['type']
      assert_equal ['text'], schema['required']
    end

    it 'routes a valid Chat#call through to the execute Proc' do
      assert_equal 'echo: hello', tool.new.call('text' => 'hello')
    end

    it 'lets pikuri\'s validator (not ruby_llm\'s) produce the LLM-facing error' do
      typed = described_class.new(
        name: 'add_one',
        description: 'Adds one.',
        parameters: Tool::Parameters.build { |p| p.required_integer :count, 'A whole number.' },
        execute: ->(count:) { (count + 1).to_s }
      )

      missing = typed.new.call({})
      assert missing.start_with?('Error:'), "expected pikuri-style error, got #{missing.inspect}"
      assert_includes missing, 'Missing required parameter `count`'

      mistyped = typed.new.call('count' => 'banana')
      assert mistyped.start_with?('Error:'), "expected pikuri-style error, got #{mistyped.inspect}"
      assert_includes mistyped, '`count`'
      assert_includes mistyped, 'integer'

      misspelled = typed.new.call('counts' => 1)
      assert_includes misspelled, 'Did you mean `count`?'
    end
  end
end
