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
      assert_equal 'echo: hi', tool.run('text' => 'hi').content
    end

    it 'answers Result.error for invalid arguments and does not call execute' do
      called = false
      tool_with_spy = described_class.new(
        name: 'spy',
        description: 'spy',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
        execute: ->(text:) { called = true; text }
      )
      result = tool_with_spy.run({})
      assert result.error?, "expected a Result.error, got #{result.inspect}"
      assert_includes result.content, '`text`'
      assert_equal result.summary, result.content.lines.first.strip
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
                         .content
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
      assert result.error?, "expected a validation error, got #{result.inspect}"
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
      schema = rl_tool.new.parameters_schema
      assert_equal 'echo', rl_tool.name
      assert_equal 'Echoes the input back.', rl_tool.description
      assert_equal 'object', schema['type']
      assert_equal 'string', schema['properties']['text']['type']
      assert_equal ['text'], schema['required']
    end

    it 'routes a valid Chat#call through to the execute Proc' do
      assert_equal 'echo: hello', rl_tool.new.call('text' => 'hello').content
    end

    it 'lets pikuri\'s validator (not ruby_llm\'s) produce the LLM-facing error' do
      typed = described_class.new(
        name: 'add_one',
        description: 'Adds one.',
        parameters: Pikuri::Tool::Parameters.build { |p| p.required_integer :count, 'A whole number.' },
        execute: ->(count:) { (count + 1).to_s }
      ).to_ruby_llm_tool

      missing = typed.new.call
      assert missing.error?, "expected pikuri-style error, got #{missing.inspect}"
      assert_includes missing.content, 'Missing required parameter `count`'

      mistyped = typed.new.call('count' => 'banana')
      assert mistyped.error?, "expected pikuri-style error, got #{mistyped.inspect}"
      assert_includes mistyped.content, '`count`'
      assert_includes mistyped.content, 'integer'

      misspelled = typed.new.call('counts' => 1)
      assert_includes misspelled.content, 'Did you mean `count`?'
    end

    describe 'with a refusal' do
      let(:png) { Pikuri::Attachment.new(mime: 'image/png', filename: 'shot.png', bytes: 'png') }
      let(:wav) { Pikuri::Attachment.new(mime: 'audio/wav', filename: 'a.wav', bytes: 'wav') }
      let(:looker) do
        attachments = [png, wav]
        described_class.new(
          name: 'look', description: 'Looks.', parameters: Pikuri::Tool::Parameters.build { |_| },
          execute: -> { Pikuri::Tool::Result.new(content: 'Read 2 files', summary: 'x', attachments: attachments) }
        )
      end

      it 'replaces a refused attachment with a note and sends the rest' do
        refusal = ->(a) { 'model m takes no vision input' if a.mime.start_with?('image/') }
        content, *sent = looker.to_ruby_llm_tool(refusal: refusal).new.execute

        assert_equal "Read 2 files\n\n[shot.png not shown: model m takes no vision input]", content
        assert_equal [wav], sent.map { |a| Pikuri::Attachment.from_ruby_llm(a) }
      end

      it 'falls back to a text Result when every attachment is refused' do
        result = looker.to_ruby_llm_tool(refusal: ->(_) { 'no' }).new.execute

        assert_kind_of Pikuri::Tool::Result, result
        refute result.attachment?
        assert_equal "Read 2 files\n\n[shot.png not shown: no]\n\n[a.wav not shown: no]", result.content
      end
    end
  end
end
