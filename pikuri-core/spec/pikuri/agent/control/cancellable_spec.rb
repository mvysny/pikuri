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

  describe '#sleep' do
    # Durations are a few slices at most: the point is the *cut-short*, and a
    # test that waits a realistic pacing interval (2s) would only be slower.
    it 'waits out the full duration when never cancelled' do
      flag = described_class.new
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flag.sleep(0.25)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert elapsed >= 0.25, "expected >= 0.25s, slept #{elapsed}"
    end

    it 'raises at once when already cancelled, without waiting' do
      flag = described_class.new
      flag.cancel!
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(described_class::Cancelled) { flag.sleep(30) }
      assert (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) < 1.0
    end

    it 'cuts the wait short when cancelled from another thread' do
      flag = described_class.new
      canceller = Thread.new { Kernel.sleep(0.1); flag.cancel! }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(described_class::Cancelled) { flag.sleep(30) }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      canceller.join
      assert elapsed < 2.0, "expected the cancel to cut the wait, took #{elapsed}s"
    end

    it 'still checks for cancellation on a non-positive duration' do
      flag = described_class.new
      flag.sleep(0)
      flag.cancel!
      assert_raises(described_class::Cancelled) { flag.sleep(0) }
    end
  end

  describe 'NEVER' do
    it 'is a token that never trips' do
      refute described_class::NEVER.cancelled?
      described_class::NEVER.check!
      described_class::NEVER.sleep(0)
    end

    it 'is frozen, so nothing can cancel every agent that defaulted to it' do
      assert described_class::NEVER.frozen?
      assert_raises(FrozenError) { described_class::NEVER.cancel! }
    end
  end
end
