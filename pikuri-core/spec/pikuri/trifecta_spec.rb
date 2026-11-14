# frozen_string_literal: true

RSpec.describe Pikuri::Trifecta do
  def legs(private: false, untrusted: :none, egress_payload_review: :no_egress, egress_destination: nil)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted,
                                   egress_payload_review: egress_payload_review,
                                   egress_destination: egress_destination)
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

  describe 'Report#verdict — the grid' do
    it 'is loud only with all three legs at full strength' do
      assert_equal :loud, verdict_for(private: true, untrusted: :hard, egress_payload_review: :unreviewed)
    end

    it 'softens when the egress leg is human-gated' do
      assert_equal :soft, verdict_for(private: true, untrusted: :hard, egress_payload_review: :human_reviewed)
    end

    it 'softens when the untrusted leg only arrived weakened' do
      assert_equal :soft, verdict_for(private: true, untrusted: :weakened, egress_payload_review: :unreviewed)
    end

    it 'stays soft with both legs attenuated — an assembled trifecta is still assembled' do
      assert_equal :soft, verdict_for(private: true, untrusted: :weakened, egress_payload_review: :human_reviewed)
    end

    it 'is silent without the private leg, however hot the other two' do
      assert_equal :silent, verdict_for(private: false, untrusted: :hard, egress_payload_review: :unreviewed)
    end

    it 'is silent without an untrusted leg' do
      assert_equal :silent, verdict_for(private: true, untrusted: :none, egress_payload_review: :unreviewed)
    end

    it 'is silent without an egress leg' do
      assert_equal :silent, verdict_for(private: true, untrusted: :hard, egress_payload_review: :no_egress)
    end

    it 'softens when the only destination is tool-vouched, even unreviewed and hard' do
      # The cell no wiring reaches yet: a search-only agent over a private,
      # untrusted workspace. Bytes still leave; the attacker cannot read them back.
      assert_equal :soft, verdict_for(private: true, untrusted: :hard,
                                      egress_payload_review: :unreviewed,
                                      egress_destination: :tool_vouched)
    end

    it 'stays soft with all three attenuations at once' do
      assert_equal :soft, verdict_for(private: true, untrusted: :weakened,
                                      egress_payload_review: :human_reviewed,
                                      egress_destination: :tool_vouched)
    end

    it 'raises rather than absorb a lattice level the grid does not place' do
      # The guard that keeps the *next* level from being silently graded soft —
      # the one that let :tool_vouched land as a deliberate decision rather than
      # a silent absorption. Stands in for a legs record from a future lattice,
      # which TrifectaLegs' own constructor would (correctly) refuse to build.
      unplaced = Data.define(:private, :untrusted, :egress_open) do
        def egress? = true
      end.new(private: true, untrusted: :half_trusted, egress_open: true)
      report = Pikuri::Trifecta::Report.new(label: 'x', legs: unplaced, tool_legs: {},
                                            children: [], channel_egress: nil)
      assert_raises(NoMatchingPatternError) { report.verdict }
    end
  end

  describe 'Report#verdict — egress is graded per tool' do
    let(:read) { legs(private: true, untrusted: :hard) }
    let(:search) { legs(untrusted: :hard, egress_payload_review: :unreviewed, egress_destination: :tool_vouched) }
    let(:compose) { legs(egress_payload_review: :human_reviewed) }
    let(:fetch) { legs(untrusted: :hard, egress_payload_review: :unreviewed) }

    it 'stays soft when one tool is unreviewed and another attacker-reachable, but none is both' do
      # Egress is a sink: bytes leave through one tool, so the vouched search
      # can't reach the attacker and the reviewed compose shows the human the bytes.
      report = described_class.walk(node('agent', { 'read' => read, 'web_search' => search,
                                                    'compose' => compose }))
      assert_equal :soft, report.verdict
      assert_equal %i[private untrusted_hard egress_reviewed egress_vouched], report.legs.to_tags
    end

    it 'goes loud the moment one tool is both unreviewed and attacker-reachable' do
      report = described_class.walk(node('agent', { 'read' => read, 'web_search' => search,
                                                    'compose' => compose, 'fetch' => fetch }))
      assert_equal :loud, report.verdict
      assert_equal %i[private untrusted_hard egress], report.legs.to_tags
    end

    it 'closes an open child behind a reviewed delegation channel' do
      child = node('RESEARCHER', { 'fetch' => fetch }, channel_egress: :human_reviewed)
      report = described_class.walk(node('parent', { 'read' => read }, children: [child]))
      refute report.legs.egress_open
      assert_equal :soft, report.verdict
    end
  end

  describe '.walk — union at a node' do
    it 'unions the legs of every tool the agent holds' do
      report = described_class.walk(node('agent',
                                         { 'read' => legs(private: true, untrusted: :hard),
                                           'bash' => legs(egress_payload_review: :unreviewed) }))
      assert_equal legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed), report.legs
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
      child = node('RESEARCHER', { 'fetch' => legs(untrusted: :hard) }, channel_egress: :unreviewed)
      report = described_class.walk(node('parent', {}, children: [child]))
      assert_equal :weakened, report.legs.untrusted
    end

    it 'propagates the child private leg at full strength' do
      child = node('MINER', { 'read' => legs(private: true) }, channel_egress: :unreviewed)
      report = described_class.walk(node('parent', {}, children: [child]))
      assert report.legs.private
    end

    it 'caps the child egress leg at the gate on the delegation channel' do
      child = node('RESEARCHER', { 'fetch' => legs(untrusted: :hard, egress_payload_review: :unreviewed) },
                   channel_egress: :human_reviewed)
      report = described_class.walk(node('parent', { 'read' => legs(private: true) }, children: [child]))
      assert_equal :human_reviewed, report.legs.egress_payload_review
      assert_equal :soft, report.verdict
    end

    it 'leaves the child egress uncapped when the child holds private data of its own' do
      # The precondition that keeps the cap honest: this child can read secrets
      # *after* the human approved an innocuous-looking task.
      child = node('RESEARCHER', { 'fetch' => legs(private: true, egress_payload_review: :unreviewed) },
                   channel_egress: :human_reviewed)
      report = described_class.walk(node('parent', { 'read' => legs(untrusted: :hard) }, children: [child]))
      assert_equal :unreviewed, report.legs.egress_payload_review
      assert_equal :loud, report.verdict
    end

    it 'treats a child with no recorded edge as ungated' do
      child = node('X', { 'fetch' => legs(egress_payload_review: :unreviewed) })
      assert_equal :unreviewed, described_class.walk(node('parent', {}, children: [child])).legs.egress_payload_review
    end

    it 'does not launder a grandchild untrusted leg away over two hops' do
      grandchild = node('G', { 'fetch' => legs(untrusted: :hard) }, channel_egress: :unreviewed)
      child = node('C', {}, children: [grandchild], channel_egress: :unreviewed)
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
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed) },
                   channel_egress: :unreviewed)
      report = described_class.walk(node('P', { 'read' => legs(private: true) }, children: [child]))

      assert_equal :loud, report.tree_verdict
      assert_equal %w[P S], report.worst_path.map(&:label)
      assert_equal :soft, report.verdict, 'the parent itself is only soft-exposed'
    end

    it 'breaks ties toward the parent, the more actionable finding' do
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed) },
                   channel_egress: :unreviewed)
      report = described_class.walk(node('P', { 'all' => legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed) },
                                         children: [child]))
      assert_equal ['P'], report.worst_path.map(&:label)
    end

    it 'exposes the deciding cell on the last node of the path' do
      child = node('S', { 'all' => legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed) },
                   channel_egress: :unreviewed)
      report = described_class.walk(node('P', {}, children: [child]))
      assert_equal :hard, report.worst_path.last.legs.untrusted
    end
  end

  describe 'Report#render' do
    it 'dumps the tree with tags, gates and depth indentation' do
      researcher = node('RESEARCHER',
                        { 'web_search' => legs(untrusted: :hard, egress_payload_review: :unreviewed,
                                                egress_destination: :tool_vouched),
                          'fetch' => legs(untrusted: :hard, egress_payload_review: :unreviewed) },
                        channel_egress: :human_reviewed)
      root = node('pikuri-computer',
                  { 'fileindex_read' => legs(private: true, untrusted: :hard),
                    'mail_compose' => legs(private: true, egress_payload_review: :human_reviewed),
                    'calculator' => no_legs },
                  children: [researcher])

      expected = <<~TREE.chomp
        [TRIFECTA: soft] pikuri-computer — private(fileindex_read, mail_compose) + \
        untrusted(fileindex_read) + egress(mail_compose). An injection in what this agent \
        reads can drive an exfiltration. Break a leg: privilege-separate the step that reads \
        untrusted content, or declare the workspace trusted if you vouch for every byte it \
        can reach. See book/trifecta-detector.md in this repo.

        pikuri-computer [:private, :untrusted_hard, :egress_reviewed]
          fileindex_read [:private, :untrusted_hard]
          mail_compose [:private, :egress_reviewed]
          calculator []
          RESEARCHER [gate: human_reviewed] [:untrusted_hard, :egress]
            web_search [:untrusted_hard, :egress_vouched]
            fetch [:untrusted_hard, :egress]
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
      def on_user_message(content, attachments); end
      def system_prompt_snippets = []
    end.new
    refute_respond_to duck, :trifecta_contribution
  end
end

RSpec.describe 'Trifecta::Report#advisory' do
  def legs(private: false, untrusted: :none, egress_payload_review: :no_egress, egress_destination: nil)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted,
                                   egress_payload_review: egress_payload_review,
                                   egress_destination: egress_destination)
  end

  def report_for(**axes)
    Pikuri::Trifecta.walk(
      Pikuri::Trifecta::Node.new(label: 'demo', tool_legs: { 'tool' => legs(**axes) })
    )
  end

  it 'never claims safety when nothing fires — it reports the finding' do
    line = report_for(private: true, untrusted: :hard).advisory
    refute_includes line, 'No trifecta'
    refute_includes line, 'secure'
    assert_includes line, '2 of 3 legs (private, untrusted)'
    assert_includes line, 'no egress leg found'
  end

  it 'names every missing leg, so the reader sees what would tip it over' do
    assert_includes report_for(private: true).advisory,
                    'no untrusted/egress leg found'
  end

  it 'marks a full trifecta HARD and names the tool that gave each leg' do
    line = report_for(private: true, untrusted: :hard, egress_payload_review: :unreviewed).advisory
    assert_includes line, '[TRIFECTA: HARD]'
    assert_includes line, 'private(tool) + untrusted(tool) + egress(tool)'
  end

  it 'gives the three soft cells three different fixes' do
    approver = report_for(private: true, untrusted: :hard, egress_payload_review: :human_reviewed).advisory
    weakened = report_for(private: true, untrusted: :weakened, egress_payload_review: :unreviewed).advisory
    both     = report_for(private: true, untrusted: :weakened,
                          egress_payload_review: :human_reviewed).advisory

    assert_includes approver, 'privilege-separate'
    assert_includes weakened, 'sever egress'
    assert_includes both, 'already attenuated'
    assert_equal 3, [approver, weakened, both].uniq.size
  end

  it 'attributes to the path when the worst node is a sub-agent' do
    child = Pikuri::Trifecta::Node.new(
      label: 'RESEARCHER',
      tool_legs: { 'fetch' => legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed) },
      channel_egress: :unreviewed
    )
    report = Pikuri::Trifecta.walk(Pikuri::Trifecta::Node.new(label: 'boss', children: [child]))
    assert_includes report.advisory, 'boss -> RESEARCHER'
  end
end
