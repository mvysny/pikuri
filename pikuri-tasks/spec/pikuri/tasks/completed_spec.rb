# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Completed do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_completed with a required content string' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_completed', tool.name
      schema = tool.parameters.to_h
      assert_equal ['content'], schema[:required]
    end
  end

  describe 'execution' do
    it 'sets the matching item to completed and returns the rendered list' do
      list.add('task')
      list.set_status(content: 'task', status: 'in_progress')
      out = tool.run('content' => 'task')
      assert_equal 'completed', list.items.first.status
      assert out.include?('- [completed] task'), out
    end

    it 'returns an LLM-actionable Error: string when no match' do
      out = tool.run('content' => 'missing')
      assert out.start_with?('Error: no such task:'), out
      assert out.include?("'missing'"), out
    end
  end
end
