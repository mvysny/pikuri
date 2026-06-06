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

    it 'defaults on_exhausted to :raise' do
      assert_equal :raise, described_class.new(max: 5).on_exhausted
    end

    it 'accepts on_exhausted: :synthesize' do
      assert_equal :synthesize, described_class.new(max: 5, on_exhausted: :synthesize).on_exhausted
    end

    it 'rejects an unknown on_exhausted policy' do
      err = assert_raises(ArgumentError) { described_class.new(max: 5, on_exhausted: :retry) }
      assert_includes err.message, ':retry'
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

  describe '#to_s' do
    it 'renders the configured cap' do
      assert_equal 'StepLimit(max=20)', described_class.new(max: 20).to_s
    end

    it 'renders the policy only when it is the non-default :synthesize' do
      assert_equal 'StepLimit(max=20, on_exhausted=synthesize)',
                   described_class.new(max: 20, on_exhausted: :synthesize).to_s
    end
  end
end
