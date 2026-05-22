# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Decorator that coalesces high-frequency streaming deltas
      # ({Event::AssistantDelta}, {Event::ThinkingDelta}) into at most
      # +fps+ events per second before handing them off to an inner
      # listener. Non-delta events flow through unmodified, with any
      # pending coalesced content either emitted ahead of them
      # (default) or dropped silently — see
      # +flush_pending_on_non_delta:+.
      #
      # Useful for renderers whose per-delta repaint cost is higher
      # than the wire-arrival rate of provider chunks: a fast provider
      # can emit dozens of deltas per second, and a Markdown-rendering
      # UI doesn't need every one of them on-screen. +fps: 15+ is a
      # reasonable starting point for a TUI.
      #
      # == Tick alignment
      #
      # The first flush is anchored to a monotonic-clock reference
      # taken at construction, not to the arrival of the first delta.
      # This keeps stream-startup latency from leaking into the
      # cadence: with +fps: 1+, if the first delta arrives 0.9s after
      # construction, it flushes immediately (the construction-time
      # tick has already passed) and the next tick fires 0.1s later
      # — preserving the configured rate. After a flush, the schedule
      # advances by exactly +1/fps+ per missed tick; a long-idle
      # stream doesn't backlog ticks against itself.
      #
      # == Per-stream buffering
      #
      # Assistant and thinking deltas are buffered independently. A
      # tick flushes whichever buffers are non-empty as separate
      # coalesced delta events; providers practically don't interleave
      # the two modalities within a single tick, but the
      # implementation doesn't rely on that.
      #
      # == Non-delta handling
      #
      # +flush_pending_on_non_delta: true+ (default) emits any pending
      # coalesced content as a delta event ahead of the non-delta
      # event so the inner listener sees the complete stream — the
      # lossless choice. +false+ drops the pending buffers silently:
      # appropriate for inner listeners that re-render the
      # authoritative final content on a bookend ({Event::Assistant} /
      # {Event::Thinking}), where rendering the trailing 0–66 ms of
      # deltas would be wasted CPU before the redraw.
      #
      # == Threading
      #
      # No threads, no timers. The decorator advances its tick state
      # only when an event arrives, so it's safe to install on any
      # listener regardless of which thread the agent emits on, as
      # long as delivery is sequential (which the {ListenerList}
      # contract guarantees).
      class RateLimited < Base
        # @param inner [Listener::Base] the listener to forward
        #   (possibly coalesced) events to.
        # @param fps [Integer, Float] frames-per-second cap on the
        #   coalesced delta stream. Must be positive.
        # @param flush_pending_on_non_delta [Boolean] +true+
        #   (default) emits any pending coalesced content as a delta
        #   before forwarding the non-delta event; +false+ drops the
        #   pending buffers silently.
        # @param clock [Proc] zero-arg returning monotonic
        #   seconds-since-some-epoch as a +Float+. Injection seam for
        #   deterministic specs; production uses
        #   +Process.clock_gettime(Process::CLOCK_MONOTONIC)+.
        # @raise [ArgumentError] if +fps+ is not positive.
        def initialize(inner, fps:, flush_pending_on_non_delta: true,
                       clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          super()
          raise ArgumentError, "fps must be positive, got #{fps.inspect}" unless fps.positive?

          @inner = inner
          @fps = fps
          @period = 1.0 / fps
          @flush_on_non_delta = flush_pending_on_non_delta
          @clock = clock
          @next_tick_at = clock.call
          @assistant_buffer = String.new
          @thinking_buffer = String.new
        end

        # @param event [Agent::Event] one of the {Agent::Event}
        #   variants; see {Agent::Event} for the full list
        # @return [void]
        def on_event(event)
          case event
          when Event::AssistantDelta
            @assistant_buffer << event.content
            tick
          when Event::ThinkingDelta
            @thinking_buffer << event.content
            tick
          else
            if @flush_on_non_delta
              flush_thinking
              flush_assistant
            else
              @assistant_buffer.clear
              @thinking_buffer.clear
            end
            @inner.on_event(event)
          end
        end

        # Sub-agent variant: wraps the inner listener's sub-agent
        # variant (or the inner listener itself when it doesn't define
        # +for_sub_agent+) in a fresh +RateLimited+ with the same
        # knobs. Returns +nil+ when the inner's +for_sub_agent+
        # returned +nil+ — there's nothing to wrap.
        #
        # @param params [Hash{Symbol => Object}] forwarded to the
        #   inner listener's +for_sub_agent+, same protocol as
        #   {ListenerList#for_sub_agent}
        # @return [RateLimited, nil]
        def for_sub_agent(**params)
          inner_sub = @inner.respond_to?(:for_sub_agent) ? @inner.for_sub_agent(**params) : @inner
          return nil if inner_sub.nil?

          self.class.new(inner_sub, fps: @fps,
                                    flush_pending_on_non_delta: @flush_on_non_delta,
                                    clock: @clock)
        end

        # @return [String] short label for {Agent#to_s}; embeds the
        #   inner listener's label so the chain reads end-to-end in
        #   {ListenerList#to_s}
        def to_s
          policy = @flush_on_non_delta ? 'flush' : 'drop'
          "RateLimited(#{@fps}fps, #{policy}, #{@inner})"
        end

        private

        # Advance to the next tick strictly after +now+, in one shot.
        # Handles the case where deltas paused for several periods —
        # a long-idle stream doesn't backlog ticks against the next
        # stream's first delta.
        # @return [void]
        def tick
          now = @clock.call
          return if now < @next_tick_at

          flush_thinking
          flush_assistant
          missed = ((now - @next_tick_at) / @period).floor + 1
          @next_tick_at += missed * @period
        end

        # @return [void]
        def flush_assistant
          return if @assistant_buffer.empty?

          @inner.on_event(Event::AssistantDelta.new(content: @assistant_buffer.dup))
          @assistant_buffer.clear
        end

        # @return [void]
        def flush_thinking
          return if @thinking_buffer.empty?

          @inner.on_event(Event::ThinkingDelta.new(content: @thinking_buffer.dup))
          @thinking_buffer.clear
        end
      end
    end
  end
end
