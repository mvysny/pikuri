# frozen_string_literal: true

require 'timecop'
RSpec.describe Pikuri::Tool::Search::RateLimiter do
  # Make the limiter's view of time deterministic without real sleeps. The
  # limiter waits through whatever +cancellable:+ it is handed, so a stand-in
  # that records the requested duration AND advances Timecop's clock by the
  # same amount is the whole seam — the limiter sees time pass exactly as if
  # it had slept.
  #
  # Uses +Timecop.freeze+ (not +travel+) so the clock stays *stopped* at
  # the advanced instant: +travel+ keeps real wall-clock flowing from the
  # new base, which lets microseconds leak into the limiter's +elapsed+
  # computation and makes the slept-for duration drift off the expected
  # value by ~1ms — enough to fail a tight +assert_in_delta+ on a slow box.
  def fake_clock(slept)
    Class.new do
      def initialize(slept) = @slept = slept

      def sleep(seconds)
        @slept << seconds
        Timecop.freeze(Time.now + seconds)
      end
    end.new(slept)
  end

  describe '#call' do
    it 'returns the block value' do
      limiter = described_class.new(min_interval: 1.0, cooldown: 60.0)
      assert_equal 42, limiter.call { 42 }
    end

    it 'does not sleep on the first call' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 2.0, cooldown: 60.0)
        slept = []
        clock = fake_clock(slept)

        limiter.call(cancellable: clock) { :ok }
        assert_equal [], slept
      end
    end

    it 'sleeps for the remaining interval when called too soon' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 2.0, cooldown: 60.0)
        slept = []
        clock = fake_clock(slept)

        limiter.call(cancellable: clock) { :first }
        Timecop.freeze(Time.now + 0.5) # only 0.5s passed
        limiter.call(cancellable: clock) { :second }

        assert_equal 1, slept.size
        assert_in_delta 1.5, slept.first, 0.001
      end
    end

    it 'does not sleep when the previous call was long enough ago' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 2.0, cooldown: 60.0)
        slept = []
        clock = fake_clock(slept)

        limiter.call(cancellable: clock) { :first }
        Timecop.freeze(Time.now + 5.0)
        limiter.call(cancellable: clock) { :second }

        assert_equal [], slept
      end
    end

    it 'arms cooldown and re-raises when the block raises Unavailable' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 300.0)
        slept = []
        clock = fake_clock(slept)

        assert_raises(Pikuri::Tool::Search::Engines::Unavailable) do
          limiter.call(cancellable: clock) { raise Pikuri::Tool::Search::Engines::Unavailable, 'rate-limited' }
        end

        # second call within cooldown raises immediately, block not invoked
        called = false
        Timecop.freeze(Time.now + 10.0)
        err = assert_raises(Pikuri::Tool::Search::Engines::Unavailable) do
          limiter.call(cancellable: clock) { called = true; :nope }
        end
        refute called, 'block should not be invoked while in cooldown'
        assert_includes err.message, 'cooldown'
      end
    end

    it 'resumes calling the block once the cooldown elapses' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 5.0)
        slept = []
        clock = fake_clock(slept)

        assert_raises(Pikuri::Tool::Search::Engines::Unavailable) do
          limiter.call(cancellable: clock) { raise Pikuri::Tool::Search::Engines::Unavailable, 'rate-limited' }
        end

        Timecop.freeze(Time.now + 10.0) # past cooldown
        assert_equal :ok, limiter.call(cancellable: clock) { :ok }
      end
    end

    it 'does not arm cooldown when the block raises a non-Unavailable error' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 300.0)
        slept = []
        clock = fake_clock(slept)

        assert_raises(RuntimeError) { limiter.call(cancellable: clock) { raise 'network blip' } }

        # interval throttle still applies, but no cooldown
        Timecop.freeze(Time.now + 5.0)
        assert_equal :ok, limiter.call(cancellable: clock) { :ok }
      end
    end

    it 'serializes concurrent callers' do
      limiter = described_class.new(min_interval: 0.0, cooldown: 60.0)
      observed_concurrency = 0
      max_observed = 0
      mutex = Mutex.new

      threads = Array.new(4) do
        Thread.new do
          limiter.call do
            mutex.synchronize { observed_concurrency += 1; max_observed = [max_observed, observed_concurrency].max }
            sleep(0.02)
            mutex.synchronize { observed_concurrency -= 1 }
          end
        end
      end
      threads.each(&:join)

      assert_equal 1, max_observed, 'limiter should serialize block execution'
    end

    it 'abandons the pacing wait when the cancellable trips, without running the block' do
      limiter = described_class.new(min_interval: 30.0, cooldown: 60.0)
      flag = Pikuri::Agent::Control::Cancellable.new
      limiter.call { :first } # arms the interval

      called = false
      canceller = Thread.new { Kernel.sleep(0.1); flag.cancel! }
      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) do
        limiter.call(cancellable: flag) { called = true }
      end
      canceller.join
      refute called, 'the block must not run once the wait was cancelled'
    end

    it 'releases the mutex on a cancelled wait, so the next caller is not stuck behind it' do
      limiter = described_class.new(min_interval: 30.0, cooldown: 60.0)
      flag = Pikuri::Agent::Control::Cancellable.new
      flag.cancel!
      limiter.call { :first }

      assert_raises(Pikuri::Agent::Control::Cancellable::Cancelled) { limiter.call(cancellable: flag) { :never } }
      # A second caller with its own (untripped) token must be able to acquire;
      # give it a limiter whose interval has effectively elapsed.
      Timecop.freeze(Time.now + 60) { assert_equal :ok, limiter.call { :ok } }
    end
  end
end
