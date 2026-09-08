# frozen_string_literal: true

# Assembling the tree from a *live* Agent — the one part of the detector the
# other specs cannot cover, because they all build Nodes by hand. That gap is
# exactly where the sub-agent-tool bug hid: every rule was right and the input
# set was wrong.
RSpec.describe 'Pikuri::Trifecta.build' do
  let(:fake_chat) do
    Class.new do
      attr_reader :tools, :model

      def initialize
        @tools = []
        @model = Struct.new(:context_window, :id, :provider).new(nil, 'm', 'openai')
      end

      def messages = []
      def with_instructions(_text) = self
      def with_tool(tool) = tap { @tools << tool }
      def after_message(&_block) = self
      def before_tool_call(&_block) = self
      def after_tool_result(&_block) = self
      def with_context(*, **) = self
      def with_model(*, **) = self
      def add_message(*, **) = self
    end.new
  end

  # +Context#chat+, not +RubyLLM.chat+: every chat an Agent builds rides a
  # per-transport +RubyLLM::Context+.
  before do
    captured = fake_chat
    @original_context_chat = RubyLLM::Context.instance_method(:chat)
    RubyLLM::Context.define_method(:chat) { |**_| captured }
  end

  after do
    RubyLLM::Context.define_method(:chat, @original_context_chat)
  end

  def tool(name, legs)
    Pikuri::Tool.new(name: name, description: 'd',
                     parameters: Pikuri::Tool::Parameters.build { |_p| },
                     execute: ->(**) { '' }, trifecta_legs: legs)
  end

  def egressing(name) = tool(name, Pikuri::Tool::TrifectaLegs::ASSUMED)

  def reading(name)
    tool(name, Pikuri::Tool::TrifectaLegs.new(private: true, untrusted: :hard, egress_payload_review: :no_egress))
  end

  def agent_with(&block)
    Pikuri::Agent.new(transport: Pikuri::Agent::ChatTransport.new(model: 'm'),
                      system_prompt: 's', &block)
  end

  it 'keeps a sub-agent-only tool out of the root node' do
    # The quarantine pattern both pikuri-computer and pikuri-code are built
    # around: the parent LLM never sees these, so the parent must not be
    # credited with their legs.
    agent = agent_with do |c|
      c.add_tool reading('read')
      c.add_sub_agent_tool egressing('fetch')
    end

    node = Pikuri::Trifecta.build(agent, label: 'demo')
    assert_equal %w[read], node.tool_legs.keys
    refute_includes node.tool_legs.keys, 'fetch'
  end

  it 'leaves a quarantined wiring without an egress leg at the root' do
    agent = agent_with do |c|
      c.add_tool reading('read')
      c.add_sub_agent_tool egressing('fetch')
    end

    report = Pikuri::Trifecta.walk(Pikuri::Trifecta.build(agent, label: 'demo'))
    assert_equal :no_egress, report.legs.egress_payload_review
    assert_equal :silent, report.tree_verdict, 'two legs only — the quarantine holds'
  end

  it 'leaves a tool nothing can call off the map entirely' do
    # An orphan: registered on the sub-agent pool, named by no persona, so no
    # node claims it. The silence is the decision (D_trifecta_map_orphans) —
    # pinned here so a later reader does not mistake it for a gap and "fix" it.
    agent = agent_with do |c|
      c.add_tool reading('read')
      c.add_sub_agent_tool egressing('git_clone')
    end

    map = Pikuri::Trifecta.walk(Pikuri::Trifecta.build(agent, label: 'demo')).render
    refute_includes map, 'git_clone'
  end

  it 'still credits the parent with an egress tool it holds directly' do
    agent = agent_with do |c|
      c.add_tool reading('read')
      c.add_tool egressing('fetch')
    end

    report = Pikuri::Trifecta.walk(Pikuri::Trifecta.build(agent, label: 'demo'))
    assert_equal :unreviewed, report.legs.egress_payload_review
    assert_equal :loud, report.tree_verdict
  end

  it 'hands the extension hook both lists, so a persona can resolve either' do
    seen = nil
    ext = Class.new do
      include Pikuri::Agent::Extension
      define_method(:trifecta_contribution) do |tools|
        seen = tools.map(&:name)
        nil
      end
    end.new

    agent = agent_with do |c|
      c.add_tool reading('read')
      c.add_sub_agent_tool egressing('fetch')
      c.add_extension ext
    end
    agent.trifecta

    assert_equal %w[read fetch], seen
  end

  it 'is reachable through Agent#trifecta, memoized' do
    agent = agent_with { |c| c.add_tool reading('read') }
    assert_same agent.trifecta, agent.trifecta
    assert_equal :silent, agent.trifecta.tree_verdict
  end
end
