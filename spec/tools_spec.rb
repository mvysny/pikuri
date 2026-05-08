# frozen_string_literal: true

require 'tools'

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

    it 'raises ValidationError for invalid arguments instead of calling execute' do
      called = false
      tool_with_spy = described_class.new(
        name: 'spy',
        description: 'spy',
        parameters: Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { called = true; text }
      )
      assert_raises(Tool::Parameters::ValidationError) { tool_with_spy.run({}) }
      refute called, 'execute must not be called when validation fails'
    end
  end

end

RSpec.describe 'WEB_SEARCH_TOOL' do
  it 'is advertised to the LLM as `web_search`' do
    assert_equal 'web_search', WEB_SEARCH_TOOL.name
  end

  it 'declares a required string `query` parameter' do
    schema = WEB_SEARCH_TOOL.parameters.to_h
    assert_equal({ type: 'string', description: 'The search query to perform.' },
                 schema[:properties][:query])
    assert_equal ['query'], schema[:required]
  end
end
