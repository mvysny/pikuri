# frozen_string_literal: true

RSpec.describe 'Pikuri.prompt / .prompts' do
  describe '.prompt' do
    it 'reads a bundled prompt by symbol basename (.txt auto-appended)' do
      assert Pikuri.prompt(:'agent-loop').start_with?('Working with tools:')
    end

    it 'raises ArgumentError naming the unknown prompt' do
      err = assert_raises(ArgumentError) { Pikuri.prompt(:no_such_prompt) }
      assert_match(/no_such_prompt/, err.message)
    end
  end

  describe '.prompts' do
    it 'joins fragments with a single blank line and no trailing newline' do
      # Both fragments end in their own trailing newline on disk; the join
      # must not double-blank the seam.
      result = Pikuri.prompts(:'pikuri-chat', :'agent-loop')
      refute result.include?("\n\n\n")
      refute result.end_with?("\n")
      assert result.include?("\n\nWorking with tools:")
    end

    it 'keeps a later "\n\n"-prefixed append to one blank line' do
      result = Pikuri.prompts(:'pikuri-chat', :'agent-loop') + "\n\nCurrent date: x"
      refute result.include?("\n\n\n")
    end

    it 'raises if any name is unknown' do
      assert_raises(ArgumentError) { Pikuri.prompts(:'agent-loop', :no_such_prompt) }
    end
  end
end
