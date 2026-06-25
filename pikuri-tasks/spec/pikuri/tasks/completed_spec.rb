# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Completed do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_completed with a required id integer' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_completed', tool.name
      schema = tool.parameters.to_openai
      assert_equal ['id'], schema[:required]
      assert_equal 'integer', schema[:properties][:id][:type]
    end
  end

  describe 'execution' do
    it 'sets the matching item to completed and returns the rendered list' do
      item = list.add('task')
      list.set_status(id: item.id, status: 'in_progress')
      out = tool.run('id' => item.id)
      assert_equal 'completed', list.items.first.status
      assert out.include?("- ##{item.id} [completed] task"), out
    end

    it 'returns an LLM-actionable Error: string with the current list when no match' do
      list.add('real task')
      out = tool.run('id' => 7)
      assert out.start_with?('Error: no such task id: 7'), out
      assert out.include?('- #1 [pending] real task'), out
    end
  end
end
