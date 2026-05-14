# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Standalone listener that caps the number of tool calls per
      # +Agent#run_loop+ invocation. Not a +MessageListener+ — its job is
      # control flow (raising on overrun), not surfacing events.
      #
      # ruby_llm has no built-in step budget, so this listener counts
      # +before_tool_call+ events on the underlying +RubyLLM::Chat+ and
      # raises {Exceeded} once the cap is crossed. +Agent#run_loop+
      # forwards that out of +Chat#ask+; the step-exhaustion synthesizer
      # rescues it to salvage the run.
      class StepLimit
        # Raised by the +before_tool_call+ callback once tool-call count
        # exceeds +max+. Carries the budget that was tripped so rescue
        # clauses can include it in user-facing messages.
        class Exceeded < StandardError
          # @return [Integer]
          attr_reader :max_steps

          # @param max_steps [Integer]
          def initialize(max_steps)
            @max_steps = max_steps
            super("Agent loop exceeded #{max_steps} steps")
          end
        end

        # @param max [Integer] hard cap on tool-call rounds; must be
        #   positive
        # @raise [ArgumentError] if +max+ is zero or negative
        def initialize(max:)
          raise ArgumentError, "max must be positive, got #{max}" if max <= 0

          @max = max
          @step = 0
        end

        # Wire the receiver into +chat+'s +before_tool_call+ callback. The
        # callback increments the counter on every tool call and raises
        # {Exceeded} once it crosses the configured cap.
        #
        # @param chat [RubyLLM::Chat]
        # @return [void]
        def attach(chat)
          chat.before_tool_call do |_|
            @step += 1
            raise Exceeded, @max if @step > @max
          end
        end

        # Listener protocol hook. Resets the step counter on a
        # turn-starting {Agent::Message::User} (+mid_loop_run: false+) —
        # that variant marks the start of a new turn by definition, so
        # it doubles as the lifecycle signal. Mid-loop injections
        # (+mid_loop_run: true+, emitted by {Listener::Interloper}) are
        # *not* a new turn and must not refresh the budget; the user
        # could otherwise refresh forever by injecting. Every other
        # variant is a no-op.
        #
        # @param message [Agent::Message]
        # @return [void]
        def on_message(message)
          case message
          in Agent::Message::User(mid_loop_run: false)
            @step = 0
          else
            # no-op
          end
        end

        # Sub-agent variant: a fresh +StepLimit+ at the caller-supplied
        # +max_steps:+, or — when the key is absent from the forwarded
        # params — at the receiver's own cap. The mutable counter and
        # the +before_tool_call+ registration are per-chat, so the
        # parent's instance cannot govern a sub-agent's chat; every
        # sub-agent needs its own.
        #
        # The +max_steps+ default to +@max+ makes the method safe to
        # call with no arguments, which keeps
        # {Agent::ListenerList#for_sub_agent} usable as a bare
        # +.for_sub_agent+ — a caller that doesn't care about the cap
        # gets a sensible inheritance instead of an exception.
        #
        # @param max_steps [Integer] positive step cap for the sub-agent;
        #   defaults to the receiver's current cap
        # @return [StepLimit]
        # @raise [ArgumentError] if +max_steps+ is non-positive
        def for_sub_agent(max_steps: @max, **)
          self.class.new(max: max_steps)
        end

        # @return [String] short config dump for {Agent#to_s}
        def to_s
          "StepLimit(max=#{@max})"
        end
      end
    end
  end
end
