# frozen_string_literal: true

RSpec.describe Pikuri::Tool::TrifectaLegs do
  def legs(private: false, untrusted: :none, egress_payload_review: :no_egress, egress_destination: nil)
    described_class.new(private: private, untrusted: untrusted,
                        egress_payload_review: egress_payload_review, egress_destination: egress_destination)
  end

  describe 'construction' do
    it 'rejects a level outside the untrusted lattice' do
      assert_raises(ArgumentError) { legs(untrusted: :hardd) }
    end

    it 'rejects a level outside the egress review lattice' do
      assert_raises(ArgumentError) { legs(egress_payload_review: :approver) }
    end

    it 'rejects a level outside the egress destination lattice' do
      assert_raises(ArgumentError) do
        legs(egress_payload_review: :unreviewed, egress_destination: :pinned)
      end
    end

    it 'derives a pessimistic destination for a declared leg' do
      assert_equal :attacker_reachable, legs(egress_payload_review: :unreviewed).egress_destination
    end

    it 'derives no destination when there is no leg' do
      assert_equal :no_egress, legs.egress_destination
    end

    it 'rejects the two egress axes disagreeing about whether the leg exists' do
      assert_raises(ArgumentError) { legs(egress_destination: :tool_vouched) }
      assert_raises(ArgumentError) do
        legs(egress_payload_review: :unreviewed, egress_destination: :no_egress)
      end
    end

    it 'ships NONE with no legs at all' do
      assert_equal legs, described_class::NONE
    end

    it 'presumes an undeclared tool hostile on every framework-knowable axis' do
      assert_equal legs(untrusted: :hard, egress_payload_review: :unreviewed,
                        egress_destination: :attacker_reachable), described_class::ASSUMED
    end

    it 'leaves private off in ASSUMED, since only the user can declare it' do
      refute described_class::ASSUMED.private
    end
  end

  describe '#| (union in parallel)' do
    it 'takes the max on each axis' do
      a = legs(private: true, untrusted: :weakened, egress_payload_review: :no_egress)
      b = legs(private: false, untrusted: :hard, egress_payload_review: :human_reviewed)
      assert_equal legs(private: true, untrusted: :hard, egress_payload_review: :human_reviewed), a | b
    end

    it 'lets an attacker-reachable destination absorb a vouched one' do
      # The sole-leg guard, mechanically: one readable sink hardens the node.
      vouched = legs(egress_payload_review: :unreviewed, egress_destination: :tool_vouched)
      reachable = legs(egress_payload_review: :human_reviewed, egress_destination: :attacker_reachable)
      assert_equal :attacker_reachable, (vouched | reachable).egress_destination
      assert_equal :unreviewed, (vouched | reachable).egress_payload_review
    end

    it 'lets a hard untrusted absorb a weakened one' do
      assert_equal :hard, (legs(untrusted: :weakened) | legs(untrusted: :hard)).untrusted
    end

    it 'keeps two weakened legs weakened' do
      assert_equal :weakened, (legs(untrusted: :weakened) | legs(untrusted: :weakened)).untrusted
    end

    it 'lets autonomous egress absorb an approver-gated one' do
      assert_equal :unreviewed, (legs(egress_payload_review: :human_reviewed) | legs(egress_payload_review: :unreviewed)).egress_payload_review
    end

    it 'is commutative' do
      a = legs(private: true, untrusted: :hard)
      b = legs(egress_payload_review: :human_reviewed, untrusted: :weakened)
      assert_equal a | b, b | a
    end

    it 'leaves NONE as the identity element' do
      a = legs(private: true, untrusted: :weakened, egress_payload_review: :unreviewed)
      assert_equal a, a | described_class::NONE
    end
  end

  describe '#relabel_inbound (crossing a sub-agent boundary)' do
    it 'demotes hard untrusted to weakened' do
      assert_equal :weakened, legs(untrusted: :hard).relabel_inbound.untrusted
    end

    it 'saturates at weakened rather than stepping down a rung' do
      # The regression that matters: a per-hop decrement would launder a
      # grandchild's untrusted content to :none at depth three.
      assert_equal :weakened, legs(untrusted: :weakened).relabel_inbound.untrusted
      assert_equal :weakened, legs(untrusted: :hard).relabel_inbound.relabel_inbound.relabel_inbound.untrusted
    end

    it 'leaves private at full strength — a summary of a secret still contains it' do
      assert legs(private: true).relabel_inbound.private
    end

    it 'leaves egress at full strength — the parent can ask the child to send it' do
      assert_equal :unreviewed, legs(egress_payload_review: :unreviewed).relabel_inbound.egress_payload_review
    end
  end

  describe '#cap_payload_review (min in series)' do
    it 'caps a hard leg at the channel level' do
      assert_equal :human_reviewed, legs(egress_payload_review: :unreviewed).cap_payload_review(:human_reviewed).egress_payload_review
    end

    it 'never promotes a weaker leg up to the channel level' do
      assert_equal :human_reviewed, legs(egress_payload_review: :human_reviewed).cap_payload_review(:unreviewed).egress_payload_review
    end

    it 'severs the leg entirely when the channel carries nothing' do
      capped = legs(egress_payload_review: :unreviewed).cap_payload_review(:no_egress)
      assert_equal :no_egress, capped.egress_payload_review
      # Both axes, or the record would claim a destination for a leg it no longer holds.
      assert_equal :no_egress, capped.egress_destination
    end

    it 'touches neither other axis' do
      capped = legs(private: true, untrusted: :hard, egress_payload_review: :unreviewed).cap_payload_review(:no_egress)
      assert capped.private
      assert_equal :hard, capped.untrusted
    end

    it 'leaves the destination axis alone: a gate bounds who saw the bytes, never who can read them' do
      capped = legs(egress_payload_review: :unreviewed, egress_destination: :tool_vouched)
                 .cap_payload_review(:human_reviewed)
      assert_equal :tool_vouched, capped.egress_destination
    end

    it 'rejects a channel level outside the lattice' do
      assert_raises(ArgumentError) { legs(egress_payload_review: :unreviewed).cap_payload_review(:gated) }
    end
  end

  describe '#to_tags' do
    it 'names only the legs present' do
      assert_equal %i[private untrusted_hard], legs(private: true, untrusted: :hard).to_tags
    end

    it 'renders autonomous egress as the bare :egress tag' do
      assert_equal [:egress], legs(egress_payload_review: :unreviewed).to_tags
    end

    it 'renders a reviewed egress leg at its level' do
      assert_equal [:egress_reviewed], legs(egress_payload_review: :human_reviewed).to_tags
    end

    it 'renders a vouched destination at its level' do
      assert_equal [:egress_vouched],
                   legs(egress_payload_review: :unreviewed, egress_destination: :tool_vouched).to_tags
    end

    it 'names the doubly-attenuated cell from both axes' do
      assert_equal [:egress_reviewed_vouched],
                   legs(egress_payload_review: :human_reviewed, egress_destination: :tool_vouched).to_tags
    end

    it 'renders a weakened untrusted leg at its level' do
      assert_equal [:untrusted_weakened], legs(untrusted: :weakened).to_tags
    end

    it 'yields an empty array for a leg-free tool' do
      assert_empty described_class::NONE.to_tags
    end
  end
end
