# frozen_string_literal: true

RSpec.describe Pikuri::Todo::Create do
  let(:list) { Pikuri::Todo::List.new }
  let(:tool) { described_class.new(list: list) }

  describe 'tool shape' do
    it 'is a Pikuri::Tool named todo_create with a required items string parameter' do
      assert_kind_of Pikuri::Tool, tool
      assert_equal 'todo_create', tool.name
      schema = tool.parameters.to_h
      assert_equal ['items'], schema[:required]
      assert_equal 'string', schema[:properties][:items][:type]
    end
  end

  describe 'execution' do
    it 'adds each non-blank line as a pending item and returns the rendered list' do
      out = tool.run('items' => "first\nsecond\nthird")
      assert_equal 3, list.size
      assert_equal %w[first second third], list.items.map(&:content)
      assert list.items.all? { |i| i.status == 'pending' }
      assert out.include?('- [pending] first'), out
      assert out.include?('- [pending] second'), out
    end

    it 'strips whitespace on each line and skips blank lines' do
      tool.run('items' => "  first  \n\n   \nsecond")
      assert_equal %w[first second], list.items.map(&:content)
    end

    it 'rejects an empty / whitespace-only items string and adds nothing' do
      out = tool.run('items' => "   \n  \n")
      assert out.start_with?('Error: todo_create requires at least one'), out
      assert list.empty?
    end

    it 'rejects a duplicate within the batch and adds nothing (atomic)' do
      out = tool.run('items' => "a\nb\na")
      assert out.start_with?('Error: duplicate item in batch:'), out
      assert out.include?("'a'"), out
      assert list.empty?
    end

    it 'rejects when an item already exists in the list and adds nothing (atomic)' do
      list.add('existing')
      out = tool.run('items' => "fresh\nexisting\nalso-fresh")
      assert out.start_with?("Error: todo already exists: 'existing'"), out
      assert_equal %w[existing], list.items.map(&:content)
    end
  end
end
