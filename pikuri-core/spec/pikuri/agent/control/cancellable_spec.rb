# frozen_string_literal: true

RSpec.describe Pikuri::Agent::Control::Cancellable do
  describe '#initialize' do
    it 'starts in the armed (not-cancelled) state' do
      refute described_class.new.cancelled?
    end
  end

  describe '#cancel!' do
    it 'flips the flag observable via #cancelled?' do
      flag = described_class.new
      flag.cancel!
      assert flag.cancelled?
    end

    it 'is idempotent — repeated calls are safe' do
      flag = described_class.new
      flag.cancel!
      flag.cancel!
      assert flag.cancelled?
    end
  end

  describe '#check!' do
    it 'does not raise while armed' do
      described_class.new.check! # no raise
    end

    it 'raises Cancelled once #cancel! has been called' do
      flag = described_class.new
      flag.cancel!

      assert_raises(described_class::Cancelled) { flag.check! }
    end

    it 'keeps raising on every subsequent check! until reset!' do
      flag = described_class.new
      flag.cancel!

      assert_raises(described_class::Cancelled) { flag.check! }
      assert_raises(described_class::Cancelled) { flag.check! }
    end
  end

  describe '#reset!' do
    it 'returns the flag to armed so a fresh turn starts clean' do
      flag = described_class.new
      flag.cancel!
      assert_raises(described_class::Cancelled) { flag.check! }

      flag.reset!

      refute flag.cancelled?
      flag.check! # no raise
    end
  end

  describe 'cross-thread cancellation' do
    it 'a #cancel! from another thread is observed at the next #check!' do
      flag = described_class.new

      Thread.new { flag.cancel! }.join

      assert_raises(described_class::Cancelled) { flag.check! }
    end
  end

  describe '#to_s' do
    it 'renders the armed state when no cancel has happened' do
      assert_equal 'Cancellable(armed)', described_class.new.to_s
    end

    it 'renders the cancelled state after #cancel!' do
      flag = described_class.new
      flag.cancel!
      assert_equal 'Cancellable(cancelled)', flag.to_s
    end
  end
end
