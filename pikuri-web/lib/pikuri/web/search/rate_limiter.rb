# frozen_string_literal: true

module Pikuri
  # Loaded after {Tool} itself is defined; the +class Tool+ reopening below
  # assumes that order.
  module Web
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
      # Uses wall-clock {Time.now}, not monotonic: the intervals (1s–5min) are
      # well above any NTP step, and {Time.now} keeps tests fakeable with
      # Timecop.
      #
      # == Sharing
      #
      # +P_shared_locked+, and sharing is *mandatory*: a limiter must be scoped
      # to the resource it protects, which here is one egress IP and one API
      # key's quota — never one agent. Hence each provider holds its limiter in
      # a class-level constant, so every agent in the VM queues behind the same
      # one. Per-agent limiters would let ten agents fire ten simultaneous
      # requests from one IP and earn exactly the ban this class exists to
      # avoid. (Contrast {Pikuri::Agent::Listener::RateLimited}, which paces one
      # renderer's repaints and is therefore per listener chain.)
      #
      # Two consequences of that scope, both correct and both surprising:
      #
      # * **It is a global queue, not just a pacer.** The mutex is held across
      #   the block — the HTTP call included — so ten agents searching at once
      #   serialize, with no timeout and no queue position. +cancellable:+
      #   covers the *pacing wait*, which is what the lock holder is doing; a
      #   caller still parked in +Mutex#synchronize+ waiting to acquire cannot
      #   observe its own cancel. It does still benefit, because every agent
      #   that cancels releases early and drains the queue faster. Making the
      #   acquisition itself interruptible means polling +Mutex#try_lock+ with
      #   explicit +lock+/+unlock+ — deliberately not built for a
      #   three-concurrent-agent case nothing has yet.
      # * **The circuit breaker is global too.** One agent tripping the
      #   provider's soft-block puts every other agent into the same cooldown.
      #   Right, because the block is IP-wide and the others were blocked
      #   anyway — but from the host's side nine agents lose a provider for
      #   something the tenth did.
      #
      # Thread-safe.
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
        # The pacing wait happens *through* +cancellable+, so the calling agent
        # can abandon it on a user cancel. It is a per-call argument rather than
        # constructor state because one limiter serves every agent in the VM
        # (see +== Sharing+) while a token belongs to one of them — and it is
        # always a real token, defaulting to
        # {Pikuri::Agent::Control::Cancellable::NEVER} rather than +nil+, so
        # there is one wait path instead of two.
        #
        # @param cancellable [Pikuri::Agent::Control::Cancellable] waited
        #   through instead of +Kernel#sleep+.
        # @yieldreturn [Object] passed through
        # @return [Object] whatever the block returned
        # @raise [Engines::Unavailable] re-raised from the block, or raised
        #   directly when the limiter is in cooldown
        # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] if
        #   +cancellable+ trips before or during the pacing wait; the block does
        #   not run and the mutex is released, so the agents queued behind this
        #   one advance immediately.
        def call(cancellable: Pikuri::Agent::Control::Cancellable::NEVER)
          @mutex.synchronize do
            now = Time.now
            if @cooldown_until && now < @cooldown_until
              remaining = (@cooldown_until - now).ceil
              raise Engines::Unavailable, "rate-limiter cooldown active for another #{remaining}s"
            end

            if @last_call_at
              elapsed = now - @last_call_at
              cancellable.sleep(@min_interval - elapsed) if elapsed < @min_interval
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

      end
    end
  end
end
