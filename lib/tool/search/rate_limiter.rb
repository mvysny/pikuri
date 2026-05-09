# frozen_string_literal: true

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  module Search
    # Thread-safe pacing + circuit-breaker wrapper for a search provider.
    #
    # +#call { ... }+ enforces a minimum interval between consecutive
    # invocations of the block (sleeping if the previous one was too
    # recent), and watches for {Unavailable} raised by the block: when
    # that happens, a cooldown deadline is recorded and further calls
    # within the window raise {Unavailable} immediately without
    # invoking the block. This stops a provider that has been
    # rate-limited or bot-blocked from being hammered with retries.
    #
    # The mutex is held across the block, so concurrent callers
    # serialize — matching the behavior {DuckDuckGo} has always
    # required to keep its IP-spacing throttle correct under
    # concurrent agents.
    #
    # Uses wall-clock {Time.now} rather than the monotonic clock; the
    # intervals here are 1s–5min, well above any realistic NTP step,
    # and {Time.now} keeps tests trivially fakeable with Timecop.
    class RateLimiter
      # @param min_interval [Float] minimum seconds between consecutive
      #   block invocations. {#call} sleeps if a previous call was more
      #   recent.
      # @param cooldown [Float] seconds to refuse calls after the block
      #   raises {Unavailable}. Calls within this window raise
      #   {Unavailable} immediately without invoking the block.
      def initialize(min_interval:, cooldown:)
        @min_interval = min_interval
        @cooldown = cooldown
        @mutex = Mutex.new
        @last_call_at = nil
        @cooldown_until = nil
      end

      # Run the given block subject to throttle and cooldown rules.
      #
      # The block is invoked with the mutex held, so concurrent calls
      # serialize: only one block runs at a time per limiter instance.
      # If the block raises {Unavailable}, the cooldown is armed and
      # the exception is re-raised. Any other exception bubbles up
      # without arming cooldown — only "try again later" signals from
      # the provider are treated as backoff triggers.
      #
      # @yieldreturn [Object] block's return value is passed through
      # @return [Object] whatever the block returned
      # @raise [Unavailable] either re-raised from the block, or
      #   raised directly when the limiter is currently in cooldown
      def call
        @mutex.synchronize do
          now = Time.now
          if @cooldown_until && now < @cooldown_until
            remaining = (@cooldown_until - now).ceil
            raise Unavailable, "rate-limiter cooldown active for another #{remaining}s"
          end

          if @last_call_at
            elapsed = now - @last_call_at
            sleep_for(@min_interval - elapsed) if elapsed < @min_interval
          end
          @last_call_at = Time.now

          begin
            yield
          rescue Unavailable
            @cooldown_until = Time.now + @cooldown
            raise
          end
        end
      end

      # Sleep for +seconds+. Isolated as a private method so tests can
      # override it on a single instance (typically to advance a frozen
      # Timecop clock by the same amount) without monkey-patching the
      # global +sleep+.
      #
      # @param seconds [Float] non-negative duration to sleep
      # @return [void]
      def sleep_for(seconds)
        sleep(seconds)
      end
      private :sleep_for
    end
  end
end
