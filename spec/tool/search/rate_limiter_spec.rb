# frozen_string_literal: true

require 'timecop'
require 'tool'
require 'tool/search/rate_limiter'

RSpec.describe Tool::Search::RateLimiter do
  # Make the limiter's view of time deterministic without real sleeps:
  # override +sleep_for+ to record the requested duration AND advance
  # Timecop's clock by the same amount, so the limiter sees time pass
  # exactly as if it had slept.
  def fake_sleep(limiter, slept)
    limiter.define_singleton_method(:sleep_for) do |seconds|
      slept << seconds
      Timecop.travel(Time.now + seconds)
    end
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
        fake_sleep(limiter, slept)

        limiter.call { :ok }
        assert_equal [], slept
      end
    end

    it 'sleeps for the remaining interval when called too soon' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 2.0, cooldown: 60.0)
        slept = []
        fake_sleep(limiter, slept)

        limiter.call { :first }
        Timecop.travel(Time.now + 0.5) # only 0.5s passed
        limiter.call { :second }

        assert_equal 1, slept.size
        assert_in_delta 1.5, slept.first, 0.001
      end
    end

    it 'does not sleep when the previous call was long enough ago' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 2.0, cooldown: 60.0)
        slept = []
        fake_sleep(limiter, slept)

        limiter.call { :first }
        Timecop.travel(Time.now + 5.0)
        limiter.call { :second }

        assert_equal [], slept
      end
    end

    it 'arms cooldown and re-raises when the block raises Unavailable' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 300.0)
        slept = []
        fake_sleep(limiter, slept)

        assert_raises(Tool::Search::Unavailable) do
          limiter.call { raise Tool::Search::Unavailable, 'rate-limited' }
        end

        # second call within cooldown raises immediately, block not invoked
        called = false
        Timecop.travel(Time.now + 10.0)
        err = assert_raises(Tool::Search::Unavailable) do
          limiter.call { called = true; :nope }
        end
        refute called, 'block should not be invoked while in cooldown'
        assert_includes err.message, 'cooldown'
      end
    end

    it 'resumes calling the block once the cooldown elapses' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 5.0)
        slept = []
        fake_sleep(limiter, slept)

        assert_raises(Tool::Search::Unavailable) do
          limiter.call { raise Tool::Search::Unavailable, 'rate-limited' }
        end

        Timecop.travel(Time.now + 10.0) # past cooldown
        assert_equal :ok, limiter.call { :ok }
      end
    end

    it 'does not arm cooldown when the block raises a non-Unavailable error' do
      Timecop.freeze do
        limiter = described_class.new(min_interval: 1.0, cooldown: 300.0)
        slept = []
        fake_sleep(limiter, slept)

        assert_raises(RuntimeError) { limiter.call { raise 'network blip' } }

        # interval throttle still applies, but no cooldown
        Timecop.travel(Time.now + 5.0)
        assert_equal :ok, limiter.call { :ok }
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
  end
end
