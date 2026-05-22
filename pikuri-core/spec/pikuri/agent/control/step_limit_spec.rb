# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::StepLimit do
  describe '#initialize' do
    it 'rejects non-positive max' do
      assert_raises(ArgumentError) { described_class.new(max: 0) }
      assert_raises(ArgumentError) { described_class.new(max: -1) }
    end

    it 'starts with the step counter at zero' do
      limit = described_class.new(max: 5)
      assert_equal 0, limit.step
      assert_equal 5, limit.max
    end
  end

  describe '#tick!' do
    it 'increments the counter and raises Exceeded once it crosses max' do
      limit = described_class.new(max: 2)

      limit.tick!
      limit.tick!
      assert_equal 2, limit.step

      err = assert_raises(described_class::Exceeded) { limit.tick! }
      assert_equal 2, err.max_steps
      assert_includes err.message, 'exceeded 2 steps'
    end

    it 'keeps raising on every subsequent tick! until reset!' do
      limit = described_class.new(max: 1)

      limit.tick!
      assert_raises(described_class::Exceeded) { limit.tick! }
      assert_raises(described_class::Exceeded) { limit.tick! }
    end
  end

  describe '#reset!' do
    it 'returns the counter to zero so a fresh turn can spend the budget again' do
      limit = described_class.new(max: 1)

      limit.tick!
      assert_raises(described_class::Exceeded) { limit.tick! }

      limit.reset!

      assert_equal 0, limit.step
      limit.tick! # budget refreshed; first call after reset succeeds
      assert_raises(described_class::Exceeded) { limit.tick! }
    end
  end

  describe '#for_sub_agent' do
    it 'returns a fresh StepLimit at the caller-supplied max_steps' do
      original = described_class.new(max: 99)
      derived  = original.for_sub_agent(max_steps: 5)

      refute_same original, derived
      assert_equal 5, derived.max
    end

    it "defaults max_steps to the receiver's own cap when the key is absent" do
      derived = described_class.new(max: 99).for_sub_agent
      assert_equal 99, derived.max
    end

    it 'rejects non-positive max_steps via StepLimit#initialize' do
      assert_raises(ArgumentError) { described_class.new(max: 99).for_sub_agent(max_steps: 0) }
    end

    it 'does not share its mutable counter with the parent' do
      parent = described_class.new(max: 4)
      derived = parent.for_sub_agent(max_steps: 4)

      3.times { parent.tick! }

      # The derived control hasn't seen any tool calls yet, so 3 must land
      # without raising — they would already trip if the counter were shared.
      3.times { derived.tick! }
    end
  end

  describe '#to_s' do
    it 'renders the configured cap' do
      assert_equal 'StepLimit(max=20)', described_class.new(max: 20).to_s
    end
  end
end
