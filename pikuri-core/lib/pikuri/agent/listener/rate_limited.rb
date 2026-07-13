# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Decorator that coalesces high-frequency streaming deltas
      # ({Event::AssistantDelta}, {Event::ThinkingDelta}) into at most +fps+
      # events/sec before forwarding to an inner listener. Non-delta events flow
      # through unmodified, with any pending coalesced content emitted ahead of
      # them (default) or dropped — see +flush_pending_on_non_delta:+.
      #
      # For renderers whose per-delta repaint costs more than provider chunks
      # arrive: a fast provider emits dozens of deltas/sec, and a
      # Markdown-rendering UI doesn't need every one. +fps: 15+ suits a TUI.
      #
      # == Tick alignment
      #
      # The first flush is anchored to a monotonic-clock reference taken at
      # construction, not the first delta's arrival — so stream-startup latency
      # doesn't leak into the cadence. After a flush the schedule advances by
      # exactly +1/fps+ per missed tick, so a long-idle stream doesn't backlog
      # ticks against itself.
      #
      # == Per-stream buffering
      #
      # Assistant and thinking deltas buffer independently; a tick flushes
      # whichever are non-empty as separate events.
      #
      # == Non-delta handling
      #
      # +flush_pending_on_non_delta: true+ (default) emits pending content ahead
      # of the non-delta event — lossless. +false+ drops it silently:
      # appropriate for inner listeners that re-render the authoritative final
      # content on a bookend ({Event::Assistant}/{Event::Thinking}), where the
      # trailing 0–66 ms of deltas would be wasted CPU before the redraw.
      #
      # No threads or timers: tick state advances only when an event arrives, so
      # it's safe on any thread as long as delivery is sequential (the
      # {ListenerList} contract).
      class RateLimited < Base
        # @param inner [Listener::Base] the listener to forward (coalesced) events to.
        # @param fps [Integer, Float] frames-per-second cap on the coalesced
        #   delta stream. Must be positive.
        # @param flush_pending_on_non_delta [Boolean] +true+ (default) emits
        #   pending content as a delta before a non-delta event; +false+ drops it.
        # @param clock [Proc] zero-arg → monotonic seconds as a +Float+;
        #   injection seam for specs (production uses
        #   +Process.clock_gettime(Process::CLOCK_MONOTONIC)+).
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

        # Sub-agent variant: wraps the inner listener's sub-agent variant (or
        # the inner itself when it has no +for_sub_agent+) in a fresh
        # +RateLimited+ with the same knobs. +nil+ when the inner's returned
        # +nil+.
        #
        # @param params [Hash{Symbol => Object}] forwarded to the inner's
        #   +for_sub_agent+ (same protocol as {ListenerList#for_sub_agent})
        # @return [RateLimited, nil]
        def for_sub_agent(**params)
          inner_sub = @inner.respond_to?(:for_sub_agent) ? @inner.for_sub_agent(**params) : @inner
          return nil if inner_sub.nil?

          self.class.new(inner_sub, fps: @fps,
                                    flush_pending_on_non_delta: @flush_on_non_delta,
                                    clock: @clock)
        end

        # @return [String] short label for {Agent#to_s}, embedding the inner
        #   listener's so the chain reads end-to-end.
        def to_s
          policy = @flush_on_non_delta ? 'flush' : 'drop'
          "RateLimited(#{@fps}fps, #{policy}, #{@inner})"
        end

        private

        # Advance to the next tick strictly after +now+, in one shot — a stream
        # idle for several periods doesn't backlog ticks against the next
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
