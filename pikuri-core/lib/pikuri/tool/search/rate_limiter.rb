# frozen_string_literal: true

module Pikuri
  # Loaded after {Tool} itself is defined; the +class Tool+ reopening below
  # assumes that order.
  class Tool
    module Search
      # Thread-safe pacing + circuit-breaker wrapper for a search provider.
      #
      # +#call { ... }+ enforces a minimum interval between block invocations
      # (sleeping if the previous was too recent) and watches for
      # {Engines::Unavailable}: on one, a cooldown deadline is recorded and
      # further calls within the window raise {Engines::Unavailable} immediately
      # without running the block — so a rate-limited or bot-blocked provider
      # isn't hammered with retries.
      #
      # The mutex is held across the block, so concurrent callers serialize —
      # what {DuckDuckGo} needs to keep its IP-spacing throttle correct under
      # concurrent agents. Uses wall-clock {Time.now}, not monotonic: the
      # intervals (1s–5min) are well above any NTP step, and {Time.now} keeps
      # tests fakeable with Timecop.
      class RateLimiter
        # @param min_interval [Float] minimum seconds between consecutive
        #   block invocations. {#call} sleeps if a previous call was more
        #   recent.
        # @param cooldown [Float] seconds to refuse calls after the block
        #   raises {Engines::Unavailable}. Calls within this window raise
        #   {Engines::Unavailable} immediately without invoking the block.
        def initialize(min_interval:, cooldown:)
          @min_interval = min_interval
          @cooldown = cooldown
          @mutex = Mutex.new
          @last_call_at = nil
          @cooldown_until = nil
        end

        # Run the block subject to the throttle and cooldown rules, with the
        # mutex held (only one block runs at a time per limiter). If it raises
        # {Engines::Unavailable}, cooldown is armed and the exception re-raised;
        # any other exception bubbles up without arming cooldown.
        #
        # @yieldreturn [Object] passed through
        # @return [Object] whatever the block returned
        # @raise [Engines::Unavailable] re-raised from the block, or raised
        #   directly when the limiter is in cooldown
        def call
          @mutex.synchronize do
            now = Time.now
            if @cooldown_until && now < @cooldown_until
              remaining = (@cooldown_until - now).ceil
              raise Engines::Unavailable, "rate-limiter cooldown active for another #{remaining}s"
            end

            if @last_call_at
              elapsed = now - @last_call_at
              sleep_for(@min_interval - elapsed) if elapsed < @min_interval
            end
            @last_call_at = Time.now

            begin
              yield
            rescue Engines::Unavailable
              @cooldown_until = Time.now + @cooldown
              raise
            end
          end
        end

        # Sleep for +seconds+. A private method so tests can override it on one
        # instance (to advance a frozen Timecop clock) without monkey-patching
        # global +sleep+.
        #
        # @param seconds [Float] non-negative duration
        # @return [void]
        def sleep_for(seconds)
          sleep(seconds)
        end
        private :sleep_for
      end
    end
  end
end
