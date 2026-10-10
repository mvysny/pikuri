# frozen_string_literal: true

# The static legs the Thunderbird tools carry. Asserted on the two shared
# constants and on the tools that use them, since the whole point is that the
# values are fixed by domain rather than derived from a collaborator.
RSpec.describe 'Thunderbird trifecta legs' do
  describe 'INBOUND_LEGS' do
    subject(:legs) { Pikuri::Thunderbird::INBOUND_LEGS }

    it 'declares private without waiting for a user declaration' do
      # The narrow exception to "the user declares sensitivity": a mailbox is
      # private by what it *is*, not by how it was configured.
      assert legs.private
    end

    it 'is hard untrusted — the contents are written by whoever mailed you' do
      assert_equal :hard, legs.untrusted
    end

    it 'has no egress leg, which is the gem default posture' do
      assert_equal :no_egress, legs.egress_payload_review
    end
  end

  describe 'OUTBOUND_LEGS' do
    subject(:legs) { Pikuri::Thunderbird::OUTBOUND_LEGS }

    it 'reaches the approver seat rather than autonomous egress' do
      # Payload visibility: the human commits in Thunderbird's own compose
      # window, so what is on screen is what leaves, byte for byte.
      assert_equal :human_reviewed, legs.egress_payload_review
    end

    it 'brings nothing untrusted back in' do
      assert_equal :none, legs.untrusted
    end

    it 'declares no private leg — these send, they do not read the mailbox' do
      # ComposeGuard's recipient-novelty note is a single incidental bit about
      # an address the model itself supplied, and under attack a novel
      # recipient is expected anyway. The private leg grades what a tool lets
      # an attacker *query*, not whether any bit at all flows back.
      refute legs.private
    end
  end

  describe 'the tools' do
    it 'tags the six inbound tools identically' do
      %i[MailSearch MailRead ContactSearch CalendarSearch CalendarRead].each do |const|
        tool = Pikuri::Thunderbird.const_get(const).new(backend: nil)
        assert_equal Pikuri::Thunderbird::INBOUND_LEGS, tool.trifecta_legs, const.to_s
      end
      # An attachment is untrusted the way a body is, so it adds no new leg.
      tool = Pikuri::Thunderbird::MailAttachmentRead.new(backend: nil, store: nil)
      assert_equal Pikuri::Thunderbird::INBOUND_LEGS, tool.trifecta_legs
    end

    it 'tags mail_compose as an approver-gated hand-off' do
      tool = Pikuri::Thunderbird::MailCompose.new(thunderbird_bin: '/nonexistent/tb')
      assert_equal Pikuri::Thunderbird::OUTBOUND_LEGS, tool.trifecta_legs
    end
  end

  describe 'walked' do
    it 'reads as two legs for the default extension — no egress at all' do
      node = Pikuri::Trifecta::Node.new(
        label: 'pikuri-thunderbird',
        tool_legs: { 'thunderbird_mail_search' => Pikuri::Thunderbird::INBOUND_LEGS,
                     'thunderbird_mail_read' => Pikuri::Thunderbird::INBOUND_LEGS }
      )
      report = Pikuri::Trifecta.walk(node)
      assert_equal :silent, report.verdict
      assert_equal %i[private untrusted_hard], report.legs.to_tags
    end

    it 'softens rather than going loud once an outbound hand-off is wired' do
      node = Pikuri::Trifecta::Node.new(
        label: 'pikuri-thunderbird',
        tool_legs: { 'thunderbird_mail_search' => Pikuri::Thunderbird::INBOUND_LEGS,
                     'thunderbird_mail_compose' => Pikuri::Thunderbird::OUTBOUND_LEGS }
      )
      report = Pikuri::Trifecta.walk(node)
      assert_equal :soft, report.verdict
      assert_equal %i[private untrusted_hard egress_reviewed], report.legs.to_tags
    end
  end
end

# The pikuri-computer rows of the paper dry-run table. This gem is where the
# Thunderbird tools live, so it is the only place that can assemble them
# alongside a broad workspace.
RSpec.describe 'trifecta dry run: pikuri-computer' do
  def legs(private: false, untrusted: :no_egress, egress_payload_review: :no_egress)
    Pikuri::Tool::TrifectaLegs.new(private: private, untrusted: untrusted, egress_payload_review: egress_payload_review)
  end

  # Whole-host disk (AllowAll, declared private) + mail/calendar reads +
  # kernel-severed bash. Egress is Thunderbird compose, not the web tools.
  def computer_node(internet:)
    tools = {
      'read' => legs(private: true, untrusted: :hard),           # AllowAll: no trusted: possible
      'bash' => legs(private: true, untrusted: :hard),           # FullFsNoNet: egress severed
      'thunderbird_mail_search' => Pikuri::Thunderbird::INBOUND_LEGS,
      'thunderbird_mail_compose' => Pikuri::Thunderbird::OUTBOUND_LEGS
    }
    children = if internet
                 [Pikuri::Trifecta::Node.new(
                   label: 'RESEARCHER',
                   tool_legs: { 'fetch' => legs(untrusted: :hard, egress_payload_review: :unreviewed) },
                   channel_egress: :human_reviewed
                 )]
               else
                 []
               end
    Pikuri::Trifecta::Node.new(label: 'pikuri-computer', tool_legs: tools, children: children)
  end

  it 'is soft with the internet off — assembled, but the way out is human-gated' do
    report = Pikuri::Trifecta.walk(computer_node(internet: false))
    assert_equal :soft, report.tree_verdict
    assert_equal %i[private untrusted_hard egress_reviewed], report.legs.to_tags
  end

  it 'stays soft with the internet on — the series cap holds the researcher at approver' do
    # The persona holds no private data of its own, so its hard fetch cannot
    # exceed the approved task string that feeds it.
    report = Pikuri::Trifecta.walk(computer_node(internet: true))
    assert_equal :soft, report.tree_verdict
    assert_equal :human_reviewed, report.legs.egress_payload_review
  end

  it 'makes the internet toggle verdict-neutral, as the note predicted' do
    assert_equal Pikuri::Trifecta.walk(computer_node(internet: false)).tree_verdict,
                 Pikuri::Trifecta.walk(computer_node(internet: true)).tree_verdict
  end

  it 'goes loud if the delegation gate is auto-approved away' do
    node = Pikuri::Trifecta::Node.new(
      label: 'pikuri-computer',
      tool_legs: { 'read' => legs(private: true, untrusted: :hard) },
      children: [Pikuri::Trifecta::Node.new(
        label: 'RESEARCHER',
        tool_legs: { 'fetch' => legs(untrusted: :hard, egress_payload_review: :unreviewed) },
        channel_egress: :unreviewed
      )]
    )
    assert_equal :loud, Pikuri::Trifecta.walk(node).tree_verdict
  end
end
