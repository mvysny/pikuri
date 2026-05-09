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
end
