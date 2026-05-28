# frozen_string_literal: true

RSpec.describe Pikuri::Todo::Extension do
  let(:configurator) do
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil
    )
  end

  it 'is an Agent::Extension by composition' do
    assert_kind_of Pikuri::Agent::Extension, described_class.new
  end

  describe '#configure' do
    it 'registers all four todo tools, all sharing the same List instance' do
      ext = described_class.new
      ext.configure(configurator)

      tools = configurator.tools
      assert_equal 4, tools.size
      assert_equal %w[todo_create todo_in_progress todo_completed todo_delete].sort,
                   tools.map(&:name).sort

      # All four tools must mutate the same list — drive one and observe via the others.
      todo_create = tools.find { |t| t.name == 'todo_create' }
      todo_completed = tools.find { |t| t.name == 'todo_completed' }
      todo_create.run('items' => 'one item')
      out = todo_completed.run('content' => 'one item')
      assert out.include?('- [completed] one item'), out
      assert_equal 'completed', ext.list.items.first.status
    end

    it 'appends the workflow snippet to the system prompt' do
      ext = described_class.new
      ext.configure(configurator)

      assert_equal 1, configurator.system_prompt_additions.size
      snippet = configurator.system_prompt_additions.first
      assert snippet.include?('<todo_usage>'), snippet
      assert snippet.include?('todo_create'), snippet
      assert snippet.include?('todo_in_progress'), snippet
      assert snippet.include?('todo_completed'), snippet
      assert snippet.include?('todo_delete'), snippet
    end

    it 'raises if any of the four todo tools was already registered' do
      pre = Pikuri::Todo::Create.new(list: Pikuri::Todo::List.new)
      configurator.add_tool(pre)
      err = assert_raises(RuntimeError) { described_class.new.configure(configurator) }
      assert_match(/Create.*cannot be pre-registered/, err.message)
    end
  end

  describe '#list' do
    it 'exposes a fresh List instance per extension instance' do
      a = described_class.new
      b = described_class.new
      refute_same a.list, b.list
      assert_kind_of Pikuri::Todo::List, a.list
      assert a.list.empty?
    end
  end

  describe '#bind' do
    it 'is the inherited no-op default' do
      ext = described_class.new
      assert_nil ext.bind(:any_agent)
    end
  end
end
