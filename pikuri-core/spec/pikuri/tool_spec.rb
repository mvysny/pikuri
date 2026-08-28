# frozen_string_literal: true

RSpec.describe Pikuri::Tool do
  let(:tool) do
    described_class.new(
      name: 'echo',
      description: 'Echoes the input back.',
      parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 'Text to echo.' },
      execute: ->(text:) { "echo: #{text}" }
    )
  end

  describe 'attributes' do
    it 'exposes name, description, parameters, and execute' do
      assert_equal 'echo', tool.name
      assert_equal 'Echoes the input back.', tool.description
      assert_kind_of Pikuri::Tool::Parameters, tool.parameters
      assert_kind_of Proc, tool.execute
    end
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
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
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
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { _ = text; raise 'parser bug' }
      )
      assert_raises(RuntimeError) { tool_that_blows_up.run('text' => 'hi') }
    end
  end

  describe 'cancellation opt-in' do
    def tool_with(execute, wants_context: false)
      described_class.new(
        name: 't', description: 't',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: execute, wants_context: wants_context
      )
    end

    def context_with(cancellable)
      Pikuri::Tool::ExecuteContext.new(cancellable: cancellable)
    end

    it 'defaults to not wanting a context' do
      refute tool_with(->(text:) { text }).wants_context
    end

    it 'hands an opting-in execute the context it was called with' do
      seen = nil
      tool = tool_with(->(text:, context:) { seen = context; text }, wants_context: true)
      ctx = context_with(Pikuri::Agent::Control::Cancellable.new)
      tool.run({ 'text' => 'hi' }, ctx)
      assert_same ctx, seen
    end

    it 'defaults to a context whose cancellation never trips, not nil' do
      seen = :unset
      tool = tool_with(->(text:, context:) { seen = context; text }, wants_context: true)
      tool.run('text' => 'hi')
      assert_same Pikuri::Agent::Control::Cancellable::NEVER, seen.cancellable
    end

    it 'never passes the keyword to a tool that did not declare it' do
      # An unknown keyword would raise ArgumentError, so a clean return is the
      # assertion.
      assert_equal 'hi', tool_with(->(text:) { text })
                         .run({ 'text' => 'hi' }, context_with(Pikuri::Agent::Control::Cancellable.new))
    end

    it 'fails loudly when the flag and the signature disagree' do
      # Both directions are ArgumentError on the first call — the reason the
      # flag is safe to declare by hand.
      assert_raises(ArgumentError) { tool_with(->(text:) { text }, wants_context: true).run('text' => 'hi') }
      assert_raises(ArgumentError) { tool_with(->(text:, context:) { [text, context] }).run('text' => 'hi') }
    end

    it 'refuses a context the LLM tries to supply as an argument' do
      result = tool_with(->(text:, context:) { [text, context] }, wants_context: true)
               .run('text' => 'hi', 'context' => 'pwned')
      assert result.start_with?('Error:'), "expected a validation error, got #{result.inspect}"
    end

    it 'gives each agent its own wrapper around one shared tool' do
      seen = []
      tool = tool_with(->(text:, context:) { seen << context.cancellable; text }, wants_context: true)
      a = Pikuri::Agent::Control::Cancellable.new
      b = Pikuri::Agent::Control::Cancellable.new

      tool.to_ruby_llm_tool(context: context_with(a)).new.execute(text: 'x')
      tool.to_ruby_llm_tool(context: context_with(b)).new.execute(text: 'y')

      assert_equal [a, b], seen
    end
  end

  describe '#to_ruby_llm_tool' do
    # Same shape ruby_llm's Chat will see: it does `klass.new` and then routes
    # tool calls through `instance.call(args)`. We bypass Chat here and drive
    # the synthetic class directly so the test stays network-free and pinned
    # to the exact integration seam.

    let(:rl_tool) { tool.to_ruby_llm_tool }

    it 'is a RubyLLM::Tool subclass that advertises pikuri\'s schema' do
      assert_operator rl_tool, :<, RubyLLM::Tool
      schema = rl_tool.new.params_schema
      assert_equal 'echo', rl_tool.name
      assert_equal 'Echoes the input back.', rl_tool.description
      assert_equal 'object', schema['type']
      assert_equal 'string', schema['properties']['text']['type']
      assert_equal ['text'], schema['required']
    end

    it 'routes a valid Chat#call through to the execute Proc' do
      assert_equal 'echo: hello', rl_tool.new.call('text' => 'hello')
    end

    it 'lets pikuri\'s validator (not ruby_llm\'s) produce the LLM-facing error' do
      typed = described_class.new(
        name: 'add_one',
        description: 'Adds one.',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_integer :count, 'A whole number.' },
        execute: ->(count:) { (count + 1).to_s }
      ).to_ruby_llm_tool

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
