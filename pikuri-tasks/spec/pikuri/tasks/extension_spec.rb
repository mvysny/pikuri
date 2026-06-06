# frozen_string_literal: true

RSpec.describe Pikuri::Tasks::Extension do
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
    it 'registers all four task tools, all sharing the same List instance' do
      ext = described_class.new
      ext.configure(configurator)

      tools = configurator.tools
      assert_equal 4, tools.size
      assert_equal %w[task_create task_in_progress task_completed task_delete].sort,
                   tools.map(&:name).sort

      # All four tools must mutate the same list — drive one and observe via the others.
      task_create = tools.find { |t| t.name == 'task_create' }
      task_completed = tools.find { |t| t.name == 'task_completed' }
      task_create.run('items' => ['one item'])
      out = task_completed.run('id' => 1)
      assert out.include?('- #1 [completed] one item'), out
      assert_equal 'completed', ext.list.items.first.status
    end

    it 'appends the workflow snippet to the system prompt' do
      ext = described_class.new
      ext.configure(configurator)

      assert_equal 1, configurator.system_prompt_additions.size
      snippet = configurator.system_prompt_additions.first
      assert snippet.include?('<tasks_usage>'), snippet
      assert snippet.include?('task_create'), snippet
      assert snippet.include?('task_in_progress'), snippet
      assert snippet.include?('task_completed'), snippet
      assert snippet.include?('task_delete'), snippet
    end

    it 'raises if any of the four task tools was already registered' do
      pre = Pikuri::Tasks::Create.new(list: Pikuri::Tasks::List.new)
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
      assert_kind_of Pikuri::Tasks::List, a.list
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
