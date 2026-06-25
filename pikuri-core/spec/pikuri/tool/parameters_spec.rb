# frozen_string_literal: true

RSpec.describe Pikuri::Tool::Parameters do
  let(:single_required) do
    described_class.build { |p| p.required_string :query, 'The search query.' }
  end

  let(:mixed) do
    described_class.build do |p|
      p.required_string :query, 'The search query.'
      p.optional_string :region, 'Optional region code.'
    end
  end

  describe '.build / #to_openai' do
    it 'serializes to OpenAI JSON-Schema shape' do
      assert_equal(
        {
          type: 'object',
          properties: {
            query: { type: 'string', description: 'The search query.' }
          },
          required: ['query']
        },
        single_required.to_openai
      )
    end

    it 'lists required and optional fields correctly' do
      schema = mixed.to_openai
      assert_equal %i[query region], schema[:properties].keys
      assert_equal ['query'], schema[:required]
    end

    it 'returns an empty schema when no fields are declared' do
      empty = described_class.build { |_p| }
      assert_equal({ type: 'object', properties: {}, required: [] }, empty.to_openai)
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
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        single_required.validate('just a string')
      end
      assert_includes err.message, 'must be an object'
      assert_includes err.message, 'String'
    end

    it 'raises with a typed, described complaint when a required field is missing' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { single_required.validate({}) }
      assert_includes err.message, 'Missing required parameter `query`'
      assert_includes err.message, '(string)'
      assert_includes err.message, 'The search query.'
    end

    it 'raises with a DidYouMean suggestion for typo unknown keys' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        single_required.validate('qury' => 'cats')
      end
      assert_includes err.message, 'Unknown parameter `qury`'
      assert_includes err.message, 'Did you mean `query`?'
    end

    it 'lists valid parameters when an unknown key has no close match' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        single_required.validate('totally_unrelated' => 'cats')
      end
      assert_includes err.message, 'Unknown parameter `totally_unrelated`'
      assert_includes err.message, 'Valid parameters: `query`'
    end

    it 'raises with the actual class and value for type mismatches' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        single_required.validate('query' => 42)
      end
      assert_includes err.message, 'Parameter `query` must be a string'
      assert_includes err.message, 'got Integer: 42'
    end

    it 'collects multiple problems in a single error message' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        single_required.validate('qury' => 42, 'extra' => 'x')
      end
      assert_includes err.message, 'Unknown parameter `qury`'
      assert_includes err.message, 'Unknown parameter `extra`'
      assert_includes err.message, 'Missing required parameter `query`'
    end

    it 'reprints the schema beneath the diff so the LLM sees the contract' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { single_required.validate({}) }
      assert_includes err.message, 'Expected schema:'
      assert_includes err.message, '`query` (string, required): The search query.'
    end

    it 'marks optional fields as optional in the reprinted schema' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { mixed.validate({}) }
      assert_includes err.message, '`region` (string, optional): Optional region code.'
    end
  end

  describe 'integer fields' do
    let(:int_required) do
      described_class.build { |p| p.required_integer :count, 'Number of items.' }
    end

    it 'serializes the integer type in to_openai' do
      schema = int_required.to_openai
      assert_equal 'integer', schema[:properties][:count][:type]
      assert_equal ['count'], schema[:required]
    end

    it 'has an optional_integer variant that does not appear in required' do
      schema = described_class.build { |p| p.optional_integer :count, 'c' }.to_openai
      assert_equal [], schema[:required]
    end

    it 'accepts an Integer as-is' do
      assert_equal({ count: 5 }, int_required.validate('count' => 5))
    end

    it 'accepts a Float with zero fractional part and coerces to Integer' do
      result = int_required.validate('count' => 5.0)
      assert_equal({ count: 5 }, result)
      assert_kind_of Integer, result[:count]
    end

    it 'accepts a numeric String and coerces to Integer' do
      assert_equal({ count: 42 }, int_required.validate('count' => '42'))
    end

    it 'accepts a String "1.0" and coerces to Integer' do
      assert_equal({ count: 1 }, int_required.validate('count' => '1.0'))
    end

    it 'trims whitespace around numeric Strings' do
      assert_equal({ count: 42 }, int_required.validate('count' => '  42  '))
    end

    it 'accepts decimal scientific notation Strings that resolve to whole numbers' do
      assert_equal({ count: 1000 }, int_required.validate('count' => '1e3'))
    end

    it 'accepts signed Strings (+/-)' do
      assert_equal({ count: -42 }, int_required.validate('count' => '-42'))
      assert_equal({ count: 42 }, int_required.validate('count' => '+42'))
    end

    it 'rejects a Float with a non-zero fractional part' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => 1.5) }
      assert_includes err.message, 'Parameter `count` must be an integer'
      assert_includes err.message, 'got Float: 1.5'
    end

    it 'rejects "25abc"' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => '25abc') }
      assert_includes err.message, 'got String: "25abc"'
    end

    it 'rejects an empty String' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => '') }
    end

    it 'rejects a whitespace-only String' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => '   ') }
    end

    it 'rejects "NaN" and "Infinity" Strings' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => 'NaN') }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => 'Infinity') }
    end

    it 'rejects hex Strings like "0x10"' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => '0x10') }
    end

    it 'rejects underscore-separated Strings like "1_000"' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => '1_000') }
    end

    it 'rejects Booleans' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => true) }
    end

    it 'rejects nil' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => nil) }
    end

    it 'rejects Hashes and Arrays' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => [1]) }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { int_required.validate('count' => { 'n' => 1 }) }
    end
  end

  describe 'number fields' do
    let(:num_required) do
      described_class.build { |p| p.required_number :temp, 'Temperature.' }
    end

    it 'serializes the number type in to_openai' do
      schema = num_required.to_openai
      assert_equal 'number', schema[:properties][:temp][:type]
    end

    it 'has an optional_number variant that does not appear in required' do
      schema = described_class.build { |p| p.optional_number :temp, 't' }.to_openai
      assert_equal [], schema[:required]
    end

    it 'accepts an Integer (preserved as Integer)' do
      result = num_required.validate('temp' => 1)
      assert_equal({ temp: 1 }, result)
      assert_kind_of Integer, result[:temp]
    end

    it 'accepts a Float' do
      result = num_required.validate('temp' => 0.7)
      assert_equal({ temp: 0.7 }, result)
      assert_kind_of Float, result[:temp]
    end

    it 'parses a decimal numeric String into a Float' do
      result = num_required.validate('temp' => '0.7')
      assert_equal({ temp: 0.7 }, result)
      assert_kind_of Float, result[:temp]
    end

    it 'trims whitespace around numeric Strings' do
      assert_equal({ temp: 0.7 }, num_required.validate('temp' => '  0.7  '))
    end

    it 'rejects NaN as a Float' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => Float::NAN) }
      assert_includes err.message, 'Parameter `temp` must be a number'
      assert_includes err.message, 'got Float: NaN'
    end

    it 'rejects Infinity as a Float' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => Float::INFINITY) }
    end

    it 'rejects garbage Strings' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => 'abc') }
      assert_includes err.message, 'got String: "abc"'
    end

    it 'rejects "25abc"' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => '25abc') }
    end

    it 'rejects Booleans' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => true) }
    end

    it 'rejects nil' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { num_required.validate('temp' => nil) }
    end
  end

  describe 'boolean fields' do
    let(:bool_required) do
      described_class.build { |p| p.required_boolean :flag, 'Enable the thing.' }
    end

    it 'serializes the boolean type in to_openai' do
      schema = bool_required.to_openai
      assert_equal 'boolean', schema[:properties][:flag][:type]
      assert_equal ['flag'], schema[:required]
    end

    it 'has an optional_boolean variant that does not appear in required' do
      schema = described_class.build { |p| p.optional_boolean :flag, 'f' }.to_openai
      assert_equal [], schema[:required]
    end

    it 'accepts true as-is' do
      assert_equal({ flag: true }, bool_required.validate('flag' => true))
    end

    it 'accepts false as-is' do
      assert_equal({ flag: false }, bool_required.validate('flag' => false))
    end

    it 'accepts the String "true" and coerces to true' do
      assert_equal({ flag: true }, bool_required.validate('flag' => 'true'))
    end

    it 'accepts the String "false" and coerces to false' do
      assert_equal({ flag: false }, bool_required.validate('flag' => 'false'))
    end

    it 'trims whitespace around the boolean String' do
      assert_equal({ flag: true }, bool_required.validate('flag' => '  true  '))
    end

    it 'rejects "True" / "FALSE" (case-sensitive, matching JSON)' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => 'True') }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => 'FALSE') }
    end

    it 'rejects truthy/falsy proxies like "yes" / "1" / 0' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => 'yes') }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => '1') }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => 0) }
    end

    it 'rejects nil' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { bool_required.validate('flag' => nil) }
    end
  end

  describe 'string array fields' do
    let(:array_required) do
      described_class.build { |p| p.required_string_array :items, 'Task contents.' }
    end

    it 'serializes as array-of-strings JSON Schema in to_openai' do
      schema = array_required.to_openai
      assert_equal 'array', schema[:properties][:items][:type]
      assert_equal({ type: 'string' }, schema[:properties][:items][:items])
      assert_equal ['items'], schema[:required]
    end

    it 'accepts an array of strings as-is' do
      assert_equal({ items: %w[a b] }, array_required.validate('items' => %w[a b]))
    end

    it 'accepts an empty array (non-emptiness is the tool layer\'s rule)' do
      assert_equal({ items: [] }, array_required.validate('items' => []))
    end

    it 'rejects a JSON-encoded array String — no in-band parsing' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        array_required.validate('items' => '["a", "b"]')
      end
      assert_match(/must be an array of strings/, err.message)
    end

    it 'auto-converts Integer and Float elements to strings' do
      assert_equal({ items: ['a', '2', '1.5'] }, array_required.validate('items' => ['a', 2, 1.5]))
    end

    it 'rejects boolean, nil, and nested-structure elements, naming the offending index' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        array_required.validate('items' => ['a', true, 'c'])
      end
      assert_match(/element 1 is TrueClass: true/, err.message)
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { array_required.validate('items' => ['a', nil]) }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { array_required.validate('items' => [%w[nested]]) }
    end

    it 'rejects non-finite Float elements' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        array_required.validate('items' => [Float::INFINITY])
      end
      assert_match(/element 0 is Float: Infinity/, err.message)
    end

    it 'rejects nil and bare scalars' do
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { array_required.validate('items' => nil) }
      assert_raises(Pikuri::Tool::Parameters::ValidationError) { array_required.validate('items' => 'a') }
    end

    it 'reports the type as "array of strings" in the missing-parameter message' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { array_required.validate({}) }
      assert_match(/`items` \(array of strings, required\)/, err.message)
      assert_match(/Missing required parameter `items` \(array of strings\)/, err.message)
    end
  end

  describe 'enum fields' do
    let(:enum_required) do
      described_class.build do |p|
        p.required_enum :name, 'Agent persona name.', values: %w[researcher scout]
      end
    end

    describe 'build-time validation' do
      it 'rejects a non-Array values:' do
        err = assert_raises(ArgumentError) do
          described_class.build { |p| p.required_enum :n, 'd', values: 'researcher' }
        end
        assert_includes err.message, 'must be a non-empty Array of non-empty Strings'
      end

      it 'rejects an empty values: list' do
        assert_raises(ArgumentError) do
          described_class.build { |p| p.required_enum :n, 'd', values: [] }
        end
      end

      it 'rejects non-String entries in values:' do
        assert_raises(ArgumentError) do
          described_class.build { |p| p.required_enum :n, 'd', values: [:researcher] }
        end
        assert_raises(ArgumentError) do
          described_class.build { |p| p.required_enum :n, 'd', values: ['ok', nil] }
        end
      end

      it 'rejects an empty-String entry in values:' do
        assert_raises(ArgumentError) do
          described_class.build { |p| p.required_enum :n, 'd', values: ['ok', ''] }
        end
      end

      it 'rejects an Array containing duplicates only if any individual entry is invalid' do
        # duplicates are not specifically forbidden — JSON Schema allows them
        schema = described_class.build { |p| p.required_enum :n, 'd', values: %w[a a] }.to_openai
        assert_equal %w[a a], schema[:properties][:n][:enum]
      end
    end

    describe '#to_openai' do
      it 'emits {type: string, enum: [...], description: ...}' do
        assert_equal(
          {
            type: 'object',
            properties: {
              name: { type: 'string', enum: %w[researcher scout], description: 'Agent persona name.' }
            },
            required: ['name']
          },
          enum_required.to_openai
        )
      end

      it 'has an optional_enum variant that does not appear in required' do
        schema = described_class.build { |p| p.optional_enum :n, 'd', values: ['a'] }.to_openai
        assert_equal [], schema[:required]
        assert_equal ['a'], schema[:properties][:n][:enum]
      end

      it 'freezes the enum array so callers cannot mutate it post-build' do
        schema = enum_required.to_openai
        assert_raises(FrozenError) { schema[:properties][:name][:enum] << 'planner' }
      end

      it 'duplicates the caller-supplied values: array so external mutation does not leak in' do
        external = ['researcher']
        schema = described_class.build { |p| p.required_enum :n, 'd', values: external }.to_openai
        external << 'mutated'
        assert_equal ['researcher'], schema[:properties][:n][:enum]
      end

      it 'empty' do
        assert_equal(
          {
            type: 'object',
            properties: {},
            required: []
          },
          Pikuri::Tool::Parameters::EMPTY.to_openai
        )
      end
    end

    describe 'freeze after build' do
      it 'raises FrozenError on post-build required_enum' do
        assert_raises(FrozenError) { enum_required.required_enum(:foo, 'bar', values: ['a']) }
      end

      it 'raises FrozenError on post-build optional_enum' do
        assert_raises(FrozenError) { enum_required.optional_enum(:foo, 'bar', values: ['a']) }
      end
    end

    describe '#validate (happy)' do
      it 'accepts a value in the enum' do
        assert_equal({ name: 'researcher' }, enum_required.validate('name' => 'researcher'))
      end

      it 'accepts string-keyed and symbol-keyed input identically' do
        assert_equal({ name: 'scout' }, enum_required.validate(name: 'scout'))
      end

      it 'allows omitting an optional enum field' do
        schema = described_class.build { |p| p.optional_enum :name, 'd', values: %w[a b] }
        assert_equal({}, schema.validate({}))
      end
    end

    describe '#validate (sad)' do
      it 'rejects a value not in the enum with a message listing the allowed values' do
        err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          enum_required.validate('name' => 'planner')
        end
        assert_includes err.message, 'Parameter `name` must be one of `researcher`, `scout`'
        assert_includes err.message, 'got String: "planner"'
      end

      it 'rejects exact-match misses (case-sensitive, no trimming)' do
        assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          enum_required.validate('name' => 'Researcher')
        end
        assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          enum_required.validate('name' => 'researcher ')
        end
      end

      it 'rejects non-string values with the string type error (enum check only runs after coerce)' do
        err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          enum_required.validate('name' => 42)
        end
        assert_includes err.message, 'Parameter `name` must be a string'
        refute_includes err.message, 'must be one of'
      end

      it 'rejects nil with the string type error' do
        assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          enum_required.validate('name' => nil)
        end
      end

      it 'mentions the allowed values in the missing-required diff line' do
        err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { enum_required.validate({}) }
        assert_includes err.message,
                        'Missing required parameter `name` (string, one of: `researcher`, `scout`): Agent persona name.'
      end

      it 'reprints the schema with the enum constraint visible' do
        err = assert_raises(Pikuri::Tool::Parameters::ValidationError) { enum_required.validate({}) }
        assert_includes err.message,
                        '`name` (string, required, one of: `researcher`, `scout`): Agent persona name.'
      end

      it 'marks an optional enum field as optional in the reprinted schema' do
        schema = described_class.build { |p| p.optional_enum :name, 'd', values: %w[a] }
        err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
          schema.validate('name' => 'b')
        end
        assert_includes err.message, '`name` (string, optional, one of: `a`): d'
      end
    end
  end

  describe 'mixed types in one schema' do
    let(:mixed_types) do
      described_class.build do |p|
        p.required_string :query, 'Search query.'
        p.required_integer :count, 'Number of results.'
        p.optional_number :temperature, 'Sampling temperature.'
      end
    end

    it 'coerces each field independently and returns properly-typed kwargs' do
      result = mixed_types.validate(
        'query' => 'cats', 'count' => '5', 'temperature' => '0.7'
      )
      assert_equal 'cats', result[:query]
      assert_equal 5, result[:count]
      assert_kind_of Integer, result[:count]
      assert_equal 0.7, result[:temperature]
      assert_kind_of Float, result[:temperature]
    end

    it 'collects per-field type errors together with missing/unknown errors' do
      err = assert_raises(Pikuri::Tool::Parameters::ValidationError) do
        mixed_types.validate('count' => '25abc', 'temperature' => 'NaN', 'extra' => 'x')
      end
      assert_includes err.message, 'Missing required parameter `query`'
      assert_includes err.message, 'Parameter `count` must be an integer'
      assert_includes err.message, 'Parameter `temperature` must be a number'
      assert_includes err.message, 'Unknown parameter `extra`'
    end
  end
end
