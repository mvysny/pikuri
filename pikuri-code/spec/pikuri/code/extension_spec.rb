# frozen_string_literal: true

RSpec.describe Pikuri::Code::Extension do
  let(:workspace) do
    Pikuri::Workspace::Filesystem.new(project_root: Dir.pwd)
  end
  let(:confirmer) { Pikuri::Workspace::Confirmer::AutoApprove.new }

  def build_configurator(plan_mode: nil)
    Pikuri::Agent::Configurator.new(
      transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
      system_prompt_base: 'base',
      id: '',
      streaming: false,
      step_limit: nil,
      cancellable: nil,
      interloper: nil,
      plan_mode: plan_mode
    )
  end

  # Minimal ExtensionContext stand-in that records emitted events.
  def build_ctx
    ctx = Object.new
    events = []
    ctx.define_singleton_method(:emit_event) { |e| events << e }
    ctx.define_singleton_method(:events) { events }
    ctx
  end

  it 'is an Agent::Extension by composition' do
    ext = described_class.new(workspace: workspace, confirmer: confirmer)
    assert_kind_of Pikuri::Agent::Extension, ext
  end

  describe '#configure with a plan-mode control' do
    let(:plan_mode) { Pikuri::Agent::Control::PlanMode.new }

    it 'registers Bash, the plan-mode pair, and GitClone as a sub-agent tool' do
      c = build_configurator(plan_mode: plan_mode)
      described_class.new(workspace: workspace, confirmer: confirmer).configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      assert_includes names, 'enter_plan_mode'
      assert_includes names, 'exit_plan_mode'

      assert_includes c.sub_agent_tools.map(&:name), 'git_clone'
    end

    it 'appends the plan-mode explainer to the system prompt' do
      c = build_configurator(plan_mode: plan_mode)
      described_class.new(workspace: workspace, confirmer: confirmer).configure(c)

      assert(c.system_prompt_additions.any? { |s| s.match?(/plan mode/i) })
    end

    it 'raises if any of its tools was already registered' do
      c = build_configurator(plan_mode: plan_mode)
      c.add_tool(Pikuri::Code::EnterPlanMode.new(plan_mode: plan_mode))

      err = assert_raises(RuntimeError) do
        described_class.new(workspace: workspace, confirmer: confirmer).configure(c)
      end
      assert_match(/EnterPlanMode.*cannot be pre-registered/, err.message)
    end
  end

  describe '#configure without a plan-mode control' do
    it 'still wires Bash + GitClone but no plan-mode tools' do
      c = build_configurator(plan_mode: nil)
      described_class.new(workspace: workspace, confirmer: confirmer).configure(c)

      names = c.tools.map(&:name)
      assert_includes names, 'bash'
      refute_includes names, 'enter_plan_mode'
      refute_includes names, 'exit_plan_mode'
      assert_includes c.sub_agent_tools.map(&:name), 'git_clone'
      refute(c.system_prompt_additions.any? { |s| s.match?(/plan mode/i) })
    end
  end

  describe '#on_user_message' do
    let(:plan_mode) { Pikuri::Agent::Control::PlanMode.new }

    it 'injects the read-only reminder while plan mode is active' do
      ext = described_class.new(workspace: workspace, confirmer: confirmer)
      ext.configure(build_configurator(plan_mode: plan_mode))

      assert_nil ext.on_user_message(nil, 'hello')

      plan_mode.enter!
      reminder = ext.on_user_message(nil, 'hello')
      assert_match(/plan mode/i, reminder)
    end

    it 'injects nothing when no plan-mode control is wired' do
      ext = described_class.new(workspace: workspace, confirmer: confirmer)
      ext.configure(build_configurator(plan_mode: nil))

      assert_nil ext.on_user_message(nil, 'hello')
    end
  end

  describe '#bind event bridge' do
    let(:plan_mode) { Pikuri::Agent::Control::PlanMode.new }

    it 'emits PlanModeChanged on every transition' do
      ext = described_class.new(workspace: workspace, confirmer: confirmer)
      ext.configure(build_configurator(plan_mode: plan_mode))
      ctx = build_ctx
      ext.bind(ctx)

      plan_mode.enter!
      plan_mode.exit!

      assert_equal [true, false], ctx.events.map(&:active)
      assert ctx.events.all? { |e| e.is_a?(Pikuri::Code::PlanModeChanged) }
    end

    it 'is a no-op when no plan-mode control is wired' do
      ext = described_class.new(workspace: workspace, confirmer: confirmer)
      ext.configure(build_configurator(plan_mode: nil))
      ctx = build_ctx

      ext.bind(ctx) # must not raise
      assert_empty ctx.events
    end
  end
end
