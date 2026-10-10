# frozen_string_literal: true

# The one type every tool returns: what it accepts, what an error looks like,
# and how the two content shapes cross into ruby_llm.
RSpec.describe Pikuri::Tool::Result do
  def tool(execute)
    Pikuri::Tool.new(name: 'probe', description: 'd',
                     parameters: Pikuri::Tool::Parameters.build { |p| p.required_string :text, 't' },
                     execute: execute)
  end

  describe '.error' do
    it 'prefixes the message once and echoes it as the display line' do
      result = described_class.error('no such task id: 7')

      assert result.error?
      assert_equal 'Error: no such task id: 7', result.content
      assert_equal 'Error: no such task id: 7', result.summary
    end

    it 'does not double a prefix a refusal composer already added' do
      assert_equal 'Error: already prefixed', described_class.error('Error: already prefixed').content
    end

    it 'keeps a multi-line message whole for the model but takes one line for the display' do
      # A ValidationError reprints the schema; none of that belongs on a status row.
      result = described_class.error("bad arguments\n\nSchema:\n  {...}")

      assert_includes result.content, 'Schema:'
      assert_equal 'Error: bad arguments', result.summary
    end

    it 'appends detail after a blank line, out of the display line' do
      result = described_class.error('no such task id: 7', detail: "1. write specs\n2. ship")

      assert_includes result.content, '2. ship'
      assert_equal 'Error: no such task id: 7', result.summary
    end
  end

  describe 'validation' do
    it 'refuses content that is not a String' do
      err = assert_raises(ArgumentError) { described_class.new(content: 42, summary: 'x') }
      assert_includes err.message, 'Integer'
    end

    it 'refuses a multi-line summary' do
      assert_raises(ArgumentError) { described_class.new(content: 'x', summary: "two\nlines") }
    end
  end

  describe 'an attachment observation' do
    let(:image) { RubyLLM::Attachment.new(StringIO.new('png'), filename: 'shot.png') }

    it 'reports itself as one, and answers the note for to_s' do
      result = described_class.new(content: 'Read image: shot.png', attachments: [image], summary: 'Read image')

      assert result.attachment?
      refute result.error?
      assert_equal 'Read image: shot.png', result.to_s
    end

    it 'crosses into ruby_llm as a [text, *attachments] Array' do
      # The Result cannot pass ruby_llm's is_a? test, so the wrapper unwraps
      # exactly this case — and only this case.
      wrapper = tool(->(text:) { described_class.new(content: 'note', attachments: [image], summary: text) })
                .to_ruby_llm_tool.new

      assert_equal ['note', image], wrapper.execute(text: 'ignored')
    end

    it 'keeps the Result for text, so the authored summary reaches the listeners' do
      wrapper = tool(->(text:) { described_class.new(content: text, summary: 'Returned 3 rows') })
                .to_ruby_llm_tool.new
      out = wrapper.execute(text: 'body')

      assert_kind_of described_class, out
      assert_equal 'Returned 3 rows', out.summary
      assert_equal 'body', out.to_s
    end
  end

  describe 'Tool#run normalization' do
    it 'wraps a bare String from a third-party tool, with the mechanical summary' do
      out = tool(->(text:) { text }).run('text' => "a\nb\nc")

      assert_kind_of described_class, out
      assert_equal 'Returned 3 lines', out.summary
    end

    it 'passes a Result through untouched' do
      out = tool(->(text:) { described_class.new(content: text, summary: 'Counted 1 thing') }).run('text' => 'x')

      assert_equal 'Counted 1 thing', out.summary
    end

    it 'raises on a return that is neither — a bug in tool code, not an observation' do
      assert_raises(ArgumentError) { tool(->(text:) { [text] }).run('text' => 'x') }
    end
  end
end
