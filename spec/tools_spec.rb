# frozen_string_literal: true

require 'tools'

RSpec.describe Tool::Parameters do
  let(:single_required) do
    described_class.build { |p| p.required_string :query, 'The search query.' }
  end

  let(:mixed) do
    described_class.build do |p|
      p.required_string :query, 'The search query.'
      p.optional_string :region, 'Optional region code.'
    end
  end

  describe '.build / #to_h' do
    it 'serializes to OpenAI JSON-Schema shape' do
      assert_equal(
        {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'The search query.' }
          },
          required: ['query']
        },
        single_required.to_h
      )
    end

    it 'lists required and optional fields correctly' do
      schema = mixed.to_h
      assert_equal %i[query region], schema[:properties].keys
      assert_equal ['query'], schema[:required]
    end

    it 'returns an empty schema when no fields are declared' do
      empty = described_class.build { |_p| }
      assert_equal({ type: 'object', properties: {}, required: [] }, empty.to_h)
    end
  end

  describe 'freeze after build' do
    it 'freezes the builder' do
      assert single_required.frozen?
    end

    it 'raises FrozenError on post-build required_string' do
      assert_raises(FrozenError) { single_required.required_string(:foo, 'bar') }
    end

    it 'raises FrozenError on post-build optional_string' do
      assert_raises(FrozenError) { single_required.optional_string(:foo, 'bar') }
    end
  end

  describe '#validate (happy paths)' do
    it 'accepts string-keyed input and returns symbol-keyed kwargs' do
      assert_equal({ query: 'cats' }, single_required.validate('query' => 'cats'))
    end

    it 'accepts symbol-keyed input and returns symbol-keyed kwargs' do
      assert_equal({ query: 'dogs' }, single_required.validate(query: 'dogs'))
    end

    it 'allows omitting optional fields' do
      assert_equal({ query: 'cats' }, mixed.validate('query' => 'cats'))
    end

    it 'passes optional fields through when present' do
      assert_equal(
        { query: 'cats', region: 'us-en' },
        mixed.validate('query' => 'cats', 'region' => 'us-en')
      )
    end

    it 'returns an empty hash for a no-field schema given an empty input' do
      empty = described_class.build { |_p| }
      assert_equal({}, empty.validate({}))
    end
  end

  describe '#validate (sad paths)' do
    it 'raises ValidationError when input is not a Hash' do
      err = assert_raises(Tool::Parameters::ValidationError) do
        single_required.validate('just a string')
      end
      assert_includes err.message, 'must be an object'
      assert_includes err.message, 'String'
    end

    it 'raises with a typed, described complaint when a required field is missing' do
      err = assert_raises(Tool::Parameters::ValidationError) { single_required.validate({}) }
      assert_includes err.message, 'Missing required parameter `query`'
      assert_includes err.message, '(string)'
      assert_includes err.message, 'The search query.'
    end

    it 'raises with a DidYouMean suggestion for typo unknown keys' do
      err = assert_raises(Tool::Parameters::ValidationError) do
        single_required.validate('qury' => 'cats')
      end
      assert_includes err.message, 'Unknown parameter `qury`'
      assert_includes err.message, 'Did you mean `query`?'
    end

    it 'lists valid parameters when an unknown key has no close match' do
      err = assert_raises(Tool::Parameters::ValidationError) do
        single_required.validate('totally_unrelated' => 'cats')
      end
      assert_includes err.message, 'Unknown parameter `totally_unrelated`'
      assert_includes err.message, 'Valid parameters: `query`'
    end

    it 'raises with the actual class and value for type mismatches' do
      err = assert_raises(Tool::Parameters::ValidationError) do
        single_required.validate('query' => 42)
      end
      assert_includes err.message, 'Parameter `query` must be a string'
      assert_includes err.message, 'got Integer: 42'
    end

    it 'collects multiple problems in a single error message' do
      err = assert_raises(Tool::Parameters::ValidationError) do
        single_required.validate('qury' => 42, 'extra' => 'x')
      end
      assert_includes err.message, 'Unknown parameter `qury`'
      assert_includes err.message, 'Unknown parameter `extra`'
      assert_includes err.message, 'Missing required parameter `query`'
    end

    it 'reprints the schema beneath the diff so the LLM sees the contract' do
      err = assert_raises(Tool::Parameters::ValidationError) { single_required.validate({}) }
      assert_includes err.message, 'Expected schema:'
      assert_includes err.message, '`query` (string, required): The search query.'
    end

    it 'marks optional fields as optional in the reprinted schema' do
      err = assert_raises(Tool::Parameters::ValidationError) { mixed.validate({}) }
      assert_includes err.message, '`region` (string, optional): Optional region code.'
    end
  end
end

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

  describe '#to_openai_schema' do
    it 'wraps the schema in an OpenAI function-tool envelope' do
      schema = tool.to_openai_schema
      assert_equal 'function', schema[:type]
      assert_equal 'echo', schema[:function][:name]
      assert_equal 'Echoes the input back.', schema[:function][:description]
      assert_equal 'object', schema[:function][:parameters][:type]
      assert_equal ['text'], schema[:function][:parameters][:required]
    end
  end
end

RSpec.describe 'WEB_SEARCH_TOOL' do
  it 'is advertised to the LLM as `web_search`' do
    assert_equal 'web_search', WEB_SEARCH_TOOL.name
  end

  it 'declares a required string `query` parameter' do
    schema = WEB_SEARCH_TOOL.to_openai_schema[:function][:parameters]
    assert_equal({ type: 'string', description: 'The search query to perform.' },
                 schema[:properties][:query])
    assert_equal ['query'], schema[:required]
  end
end
