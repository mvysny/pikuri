# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::InProgress do
  let(:list) { Pikuri::Tasks::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is named task_in_progress with a required content string' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'task_in_progress', tool.name
      schema = tool.parameters.to_h
      assert_equal ['content'], schema[:required]
      assert_equal 'string', schema[:properties][:content][:type]
    end
  end

  describe 'execution' do
    it 'sets the matching item to in_progress and returns the rendered list' do
      list.add('task')
      out = tool.run('content' => 'task')
      assert_equal 'in_progress', list.items.first.status
      assert out.include?('- [in_progress] task'), out
    end

    it 'returns an LLM-actionable Error: string when no match' do
      list.add('something else')
      out = tool.run('content' => 'task')
      assert out.start_with?('Error: no such task:'), out
      assert out.include?("'task'"), out
      # Nothing changed
      assert_equal 'pending', list.items.first.status
    end
  end
end
