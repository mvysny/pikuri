# frozen_string_literal: true

RSpec.describe 'SubAgent::Extension#trifecta_contribution' do
  def legs(private: false, untrusted: :none, egress: :none)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted, egress: egress)
  end

  def tool(name, tool_legs)
    Pikuri::Tool.new(name: name, description: 'x',
                     parameters: Pikuri::Tool::Parameters.build { |_p| },
                     execute: ->(**) { '' }, trifecta_legs: tool_legs)
  end

  let(:web_tools) do
    [tool('web_search', legs(untrusted: :hard, egress: :autonomous)),
     tool('fetch', legs(untrusted: :hard, egress: :autonomous)),
     tool('read', legs(private: true, untrusted: :hard))]
  end

  let(:persona) do
    Pikuri::SubAgent::Persona.new(name: 'RESEARCHER', description: 'd',
                                  tool_names: %w[web_search fetch].freeze,
                                  system_prompt: 'p', max_steps: 5)
  end

  def extension(confirmer:)
    Pikuri::SubAgent::Extension.new(personas: [persona], confirmer: confirmer)
  end

  it 'yields one child per persona, holding only that persona tools' do
    contribution = extension(confirmer: nil).trifecta_contribution(web_tools)

    assert_equal 1, contribution.children.size
    child = contribution.children.first
    assert_equal 'RESEARCHER', child.label
    assert_equal %w[web_search fetch], child.tool_legs.keys
  end

  it 'adds no legs of its own — a sub-agent is a node, not a capability' do
    assert_equal Pikuri::Tool::TrifectaLegs::NONE,
                 extension(confirmer: nil).trifecta_contribution(web_tools).legs
  end

  it 'marks the delegation edge as gated when the confirmer can block on a human' do
    asking = Class.new(Pikuri::Workspace::Confirmer) do
      def ask(request:) = Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
    end
    child = extension(confirmer: asking.new).trifecta_contribution(web_tools).children.first
    assert_equal :human_approver, child.channel_egress
  end

  it 'marks it autonomous under AUTO_APPROVE, so --no-confirm re-hardens the verdict' do
    child = extension(confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE)
            .trifecta_contribution(web_tools).children.first
    assert_equal :autonomous, child.channel_egress
  end

  it 'marks it autonomous when no confirmer was wired at all' do
    child = extension(confirmer: nil).trifecta_contribution(web_tools).children.first
    assert_equal :autonomous, child.channel_egress
  end

  describe 'walked into a parent' do
    def parent_report(confirmer:)
      contribution = extension(confirmer: confirmer).trifecta_contribution(web_tools)
      node = Pikuri::Trifecta::Node.new(
        label: 'parent',
        tool_legs: { 'read' => legs(private: true, untrusted: :hard) },
        children: contribution.children
      )
      Pikuri::Trifecta.walk(node)
    end

    it 'caps the propagated egress at the gate — soft, not loud' do
      asking = Class.new(Pikuri::Workspace::Confirmer) do
        def ask(request:) = Pikuri::Workspace::Confirmer::Approved.new(new_request_detail: request.detail)
      end
      report = parent_report(confirmer: asking.new)
      assert_equal :human_approver, report.legs.egress
      assert_equal :soft, report.verdict
    end

    it 'goes loud once the gate is auto-approved' do
      report = parent_report(confirmer: Pikuri::Workspace::Confirmer::AUTO_APPROVE)
      assert_equal :autonomous, report.legs.egress
      assert_equal :loud, report.verdict
    end
  end
end
