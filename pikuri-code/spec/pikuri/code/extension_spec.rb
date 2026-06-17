# frozen_string_literal: true

RSpec.describe Pikuri::Code::Extension do
  let(:workspace) do
    Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)
  end
  let(:confirmer) { Pikuri::Workspace::Confirmer::AutoApprove.new }
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
    ext = described_class.new(workspace: workspace, confirmer: confirmer)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure' do
    it 'registers Bash, EnterPlanMode and ExitPlanMode plus GitClone as sub-agent tool' do
      ext = described_class.new(workspace: workspace, confirmer: confirmer)
      ext.configure(configurator)

      names = configurator.tools.map(&:name)
      assert_includes names, 'bash'
      assert_includes names, 'enter_plan_mode'
      assert_includes names, 'exit_plan_mode'

      sub_names = configurator.sub_agent_tools.map(&:name)
      assert_includes sub_names, 'git_clone'
    end

    it 'raises if any of its tools was already registered' do
      pre = Pikuri::Code::EnterPlanMode.new
      configurator.add_tool(pre)
      err = assert_raises(RuntimeError) do
        described_class.new(workspace: workspace, confirmer: confirmer).configure(configurator)
      end
      assert_match(/EnterPlanMode.*cannot be pre-registered/, err.message)
    end
  end
end
