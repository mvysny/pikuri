# frozen_string_literal: true

RSpec.describe Pikuri::Tool::TrifectaLegs do
  def legs(private: false, untrusted: :none, egress: :none)
    described_class.new(private: private, untrusted: untrusted, egress: egress)
  end

  describe 'construction' do
    it 'rejects a level outside the untrusted lattice' do
      assert_raises(ArgumentError) { legs(untrusted: :hardd) }
    end

    it 'rejects a level outside the egress lattice' do
      assert_raises(ArgumentError) { legs(egress: :approver) }
    end

    it 'ships NONE with no legs at all' do
      assert_equal legs, described_class::NONE
    end

    it 'presumes an undeclared tool hostile on both framework-knowable axes' do
      assert_equal legs(untrusted: :hard, egress: :autonomous), described_class::ASSUMED
    end

    it 'leaves private off in ASSUMED, since only the user can declare it' do
      refute described_class::ASSUMED.private
    end
  end

  describe '#| (union in parallel)' do
    it 'takes the max on each axis' do
      a = legs(private: true, untrusted: :weakened, egress: :none)
      b = legs(private: false, untrusted: :hard, egress: :human_approver)
      assert_equal legs(private: true, untrusted: :hard, egress: :human_approver), a | b
    end

    it 'lets a hard untrusted absorb a weakened one' do
      assert_equal :hard, (legs(untrusted: :weakened) | legs(untrusted: :hard)).untrusted
    end

    it 'keeps two weakened legs weakened' do
      assert_equal :weakened, (legs(untrusted: :weakened) | legs(untrusted: :weakened)).untrusted
    end

    it 'lets autonomous egress absorb an approver-gated one' do
      assert_equal :autonomous, (legs(egress: :human_approver) | legs(egress: :autonomous)).egress
    end

    it 'is commutative' do
      a = legs(private: true, untrusted: :hard)
      b = legs(egress: :human_approver, untrusted: :weakened)
      assert_equal a | b, b | a
    end

    it 'leaves NONE as the identity element' do
      a = legs(private: true, untrusted: :weakened, egress: :autonomous)
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
      assert_equal :autonomous, legs(egress: :autonomous).relabel_inbound.egress
    end
  end

  describe '#cap_egress (min in series)' do
    it 'caps a hard leg at the channel level' do
      assert_equal :human_approver, legs(egress: :autonomous).cap_egress(:human_approver).egress
    end

    it 'never promotes a weaker leg up to the channel level' do
      assert_equal :human_approver, legs(egress: :human_approver).cap_egress(:autonomous).egress
    end

    it 'severs the leg entirely when the channel carries nothing' do
      assert_equal :none, legs(egress: :autonomous).cap_egress(:none).egress
    end

    it 'touches neither other axis' do
      capped = legs(private: true, untrusted: :hard, egress: :autonomous).cap_egress(:none)
      assert capped.private
      assert_equal :hard, capped.untrusted
    end

    it 'rejects a channel level outside the lattice' do
      assert_raises(ArgumentError) { legs(egress: :autonomous).cap_egress(:gated) }
    end
  end

  describe '#to_tags' do
    it 'names only the legs present' do
      assert_equal %i[private untrusted_hard], legs(private: true, untrusted: :hard).to_tags
    end

    it 'renders autonomous egress as the bare :egress tag' do
      assert_equal [:egress], legs(egress: :autonomous).to_tags
    end

    it 'renders a gated egress leg at its level' do
      assert_equal [:egress_human_approver], legs(egress: :human_approver).to_tags
    end

    it 'renders a weakened untrusted leg at its level' do
      assert_equal [:untrusted_weakened], legs(untrusted: :weakened).to_tags
    end

    it 'yields an empty array for a leg-free tool' do
      assert_empty described_class::NONE.to_tags
    end
  end
end
