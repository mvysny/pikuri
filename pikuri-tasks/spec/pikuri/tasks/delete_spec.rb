# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Delete do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_delete with a required content string' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_delete', tool.name
      schema = tool.parameters.to_h
      assert_equal ['content'], schema[:required]
    end
  end

  describe 'execution' do
    it 'removes the matching item and returns the rendered list' do
      list.add('keep')
      list.add('drop')
      out = tool.run('content' => 'drop')
      assert_equal %w[keep], list.items.map(&:content)
      assert out.include?('- [pending] keep'), out
      refute out.include?('drop'), out
    end

    it 'returns the empty marker after the last item is removed' do
      list.add('only')
      out = tool.run('content' => 'only')
      assert_equal '<tasks>(empty)</tasks>', out
    end

    it 'returns an LLM-actionable Error: string when no match' do
      out = tool.run('content' => 'nope')
      assert out.start_with?('Error: no such task:'), out
      assert out.include?("'nope'"), out
    end
  end
end
