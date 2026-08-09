# frozen_string_literal: true

RSpec.describe Pikuri::Trifecta do
  def legs(private: false, untrusted: :none, egress: :none)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted, egress: egress)
  end

  def no_legs = Pikuri::Tool::TrifectaLegs::NONE

  def node(label, tools = {}, children: [], channel_egress: nil)
    Pikuri::Trifecta::Node.new(label: label, tool_legs: tools, children: children,
                               channel_egress: channel_egress)
  end

  def verdict_for(**axes)
    report = described_class.walk(node('agent', { 'tool' => legs(**axes) }))
    report.verdict
  end

  describe 'Report#verdict — the 2x2 grid' do
    it 'is loud only with all three legs at full strength' do
      assert_equal :loud, verdict_for(private: true, untrusted: :hard, egress: :autonomous)
    end

    it 'softens when the egress leg is human-gated' do
      assert_equal :soft, verdict_for(private: true, untrusted: :hard, egress: :human_approver)
    end

    it 'softens when the untrusted leg only arrived weakened' do
      assert_equal :soft, verdict_for(private: true, untrusted: :weakened, egress: :autonomous)
    end

    it 'stays soft with both legs attenuated — an assembled trifecta is still assembled' do
      assert_equal :soft, verdict_for(private: true, untrusted: :weakened, egress: :human_approver)
    end

    it 'is silent without the private leg, however hot the other two' do
      assert_equal :silent, verdict_for(private: false, untrusted: :hard, egress: :autonomous)
    end

    it 'is silent without an untrusted leg' do
      assert_equal :silent, verdict_for(private: true, untrusted: :none, egress: :autonomous)
    end

    it 'is silent without an egress leg' do
      assert_equal :silent, verdict_for(private: true, untrusted: :hard, egress: :none)
    end

    it 'raises rather than absorb a lattice level the grid does not place' do
      # The guard that keeps a future :egress_searchengine from being silently
      # graded soft. Stands in for a legs record from a future lattice, which
      # TrifectaLegs' own constructor would (correctly) refuse to build.
      unplaced = Data.define(:private, :untrusted, :egress)
                     .new(private: true, untrusted: :hard, egress: :searchengine)
      report = Pikuri::Trifecta::Report.new(label: 'x', legs: unplaced, tool_legs: {},
                                            children: [], channel_egress: nil)
      assert_raises(NoMatchingPatternError) { report.verdict }
    end
  end

  describe '.walk — union at a node' do
    it 'unions the legs of every tool the agent holds' do
      report = described_class.walk(node('agent',
                                         { 'read' => legs(private: true, untrusted: :hard),
                                           'bash' => legs(egress: :autonomous) }))
      assert_equal legs(private: true, untrusted: :hard, egress: :autonomous), report.legs
      assert_equal :loud, report.verdict
    end

    it 'gives a tool-less agent no legs' do
      assert_equal no_legs, described_class.walk(node('bare')).legs
    end

    it 'carries the tool breakdown through unpre-unioned, for the map' do
      report = described_class.walk(node('agent', { 'read' => legs(private: true) }))
      assert_equal({ 'read' => legs(private: true) }, report.tool_legs)
    end
  end

  describe '.walk — propagation across a sub-agent boundary' do
    it 'attenuates the child untrusted leg to weakened' do
      child = node('RESEARCHER', { 'fetch' => legs(untrusted: :hard) }, channel_egress: :autonomous)
      report = described_class.walk(node('parent', {}, children: [child]))
      assert_equal :weakened, report.legs.untrusted
    end

    it 'propagates the child private leg at full strength' do
      child = node('MINER', { 'read' => legs(private: true) }, channel_egress: :autonomous)
      report = described_class.walk(node('parent', {}, children: [child]))
      assert report.legs.private
    end

    it 'caps the child egress leg at the gate on the delegation channel' do
      child = node('RESEARCHER', { 'fetch' => legs(untrusted: :hard, egress: :autonomous) },
                   channel_egress: :human_approver)
      report = described_class.walk(node('parent', { 'read' => legs(private: true) }, children: [child]))
      assert_equal :human_approver, report.legs.egress
      assert_equal :soft, report.verdict
    end

    it 'leaves the child egress uncapped when the child holds private data of its own' do
      # The precondition that keeps the cap honest: this child can read secrets
      # *after* the human approved an innocuous-looking task.
      child = node('RESEARCHER', { 'fetch' => legs(private: true, egress: :autonomous) },
                   channel_egress: :human_approver)
      report = described_class.walk(node('parent', { 'read' => legs(untrusted: :hard) }, children: [child]))
      assert_equal :autonomous, report.legs.egress
      assert_equal :loud, report.verdict
    end

    it 'treats a child with no recorded edge as ungated' do
      child = node('X', { 'fetch' => legs(egress: :autonomous) })
      assert_equal :autonomous, described_class.walk(node('parent', {}, children: [child])).legs.egress
    end

    it 'does not launder a grandchild untrusted leg away over two hops' do
      grandchild = node('G', { 'fetch' => legs(untrusted: :hard) }, channel_egress: :autonomous)
      child = node('C', {}, children: [grandchild], channel_egress: :autonomous)
      report = described_class.walk(node('parent', {}, children: [child]))
      assert_equal :weakened, report.legs.untrusted
    end
  end

  describe 'Report#worst_path — max over the tree' do
    it 'stops at the root when nothing below is worse' do
      report = described_class.walk(node('solo', { 'read' => legs(private: true) }))
      assert_equal ['solo'], report.worst_path.map(&:label)
      assert_equal :silent, report.tree_verdict
    end

    it 'attributes a loud sub-agent to the path that reaches it' do
      # A child that is a full trifecta on its own; the parent only reads soft.
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress: :autonomous) },
                   channel_egress: :autonomous)
      report = described_class.walk(node('P', { 'read' => legs(private: true) }, children: [child]))

      assert_equal :loud, report.tree_verdict
      assert_equal %w[P S], report.worst_path.map(&:label)
      assert_equal :soft, report.verdict, 'the parent itself is only soft-exposed'
    end

    it 'breaks ties toward the parent, the more actionable finding' do
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress: :autonomous) },
                   channel_egress: :autonomous)
      report = described_class.walk(node('P', { 'all' => legs(private: true, untrusted: :hard, egress: :autonomous) },
                                         children: [child]))
      assert_equal ['P'], report.worst_path.map(&:label)
    end

    it 'exposes the deciding cell on the last node of the path' do
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress: :autonomous) },
                   channel_egress: :autonomous)
      report = described_class.walk(node('P', {}, children: [child]))
      assert_equal :hard, report.worst_path.last.legs.untrusted
    end
  end

  describe 'Report#render' do
    it 'dumps the tree with tags, gates and depth indentation' do
      researcher = node('RESEARCHER',
                        { 'web_search' => legs(untrusted: :hard, egress: :autonomous),
                          'fetch' => legs(untrusted: :hard, egress: :autonomous) },
                        channel_egress: :human_approver)
      root = node('pikuri-computer',
                  { 'fileindex_read' => legs(private: true, untrusted: :hard),
                    'mail_compose' => legs(private: true, egress: :human_approver),
                    'calculator' => no_legs },
                  children: [researcher])

      expected = <<~TREE.chomp
        Trifecta: soft

        pikuri-computer [:private, :untrusted_hard, :egress_human_approver]
          fileindex_read [:private, :untrusted_hard]
          mail_compose [:private, :egress_human_approver]
          calculator []
          RESEARCHER [gate: human_approver] [:untrusted_hard, :egress]
            web_search [:untrusted_hard, :egress]
            fetch [:untrusted_hard, :egress]

        See the book in this repo for what the lethal trifecta is and how to break a leg.
      TREE

      assert_equal expected, described_class.walk(root).render
    end

    it 'omits the gate marker at the root, which has no parent edge' do
      rendered = described_class.walk(node('solo')).render
      refute_includes rendered, 'gate:'
      assert_includes rendered, 'solo []'
    end
  end
end

RSpec.describe Pikuri::Trifecta::Contribution do
  it 'defaults to nothing on both axes — an extension opts in to each' do
    contribution = described_class.new
    assert_equal Pikuri::Tool::TrifectaLegs::NONE, contribution.legs
    assert_empty contribution.children
  end
end

RSpec.describe Pikuri::Agent::Extension do
  it 'defaults #trifecta_contribution to nil, so most extensions owe nothing' do
    plain = Class.new { include Pikuri::Agent::Extension }.new
    assert_nil plain.trifecta_contribution([])
  end

  it 'stays optional for a class that implements the protocol without including it' do
    # The protocol permits this, which is why the Agent must call the hook
    # guarded by respond_to? rather than by name like every other hook.
    duck = Class.new do
      def configure(c); end
      def bind(ctx); end
      def on_user_message(ctx, content); end
      def on_conversation_reset(ctx); end
      def system_prompt_snippets = []
    end.new
    refute_respond_to duck, :trifecta_contribution
  end
end
