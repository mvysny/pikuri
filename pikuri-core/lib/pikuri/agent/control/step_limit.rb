# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Caps the number of tool calls per {Agent#run_loop}
      # invocation. ruby_llm has no built-in step budget; the
      # +Agent+ pokes {#tick!} on every +before_tool_call+
      # callback and {#reset!} at the start of each turn. Once the
      # counter exceeds the configured cap, {#tick!} raises
      # {Exceeded}, the +Agent+ catches it, and the step-
      # exhaustion synthesizer rescues to salvage a partial
      # answer.
      class StepLimit
        # Raised by {#tick!} once tool-call count exceeds +max+.
        # Carries the budget that was tripped so rescue clauses
        # can include it in user-facing messages.
        class Exceeded < StandardError
          # @return [Integer]
          attr_reader :max_steps

          # @param max_steps [Integer]
          def initialize(max_steps)
            @max_steps = max_steps
            super("Agent loop exceeded #{max_steps} steps")
          end
        end

        # @return [Integer] the configured cap
        attr_reader :max

        # @param max [Integer] hard cap on tool-call rounds; must
        #   be positive
        # @raise [ArgumentError] if +max+ is zero or negative
        def initialize(max:)
          raise ArgumentError, "max must be positive, got #{max}" if max <= 0

          @max = max
          @step = 0
        end

        # Increment the tool-call counter; raise {Exceeded} once
        # it crosses {#max}. Called by {Agent} from its
        # +before_tool_call+ wiring.
        #
        # @return [void]
        # @raise [Exceeded] when the counter has now exceeded
        #   {#max}
        def tick!
          @step += 1
          raise Exceeded, @max if @step > @max
        end

        # Reset the counter back to zero. Called by {Agent} at the
        # start of each turn (in {Agent#run_loop} before forwarding
        # the user message to the chat) so the same instance can
        # govern many turns across a long-running REPL. Mid-loop
        # {Control::Interloper} injections deliberately do *not*
        # trigger a reset — those are additional context for the
        # same turn, not a fresh one, and a chatty user could
        # otherwise refresh the budget forever by injecting.
        #
        # @return [void]
        def reset!
          @step = 0
        end

        # @return [Integer] current step count; exposed so callers
        #   can introspect it (and so tests can assert it)
        attr_reader :step

        # Sub-agent variant: a fresh +StepLimit+ at the
        # caller-supplied +max_steps:+, or — when the key is
        # absent — at the receiver's own cap. The mutable counter
        # is per-chat, so the parent's instance cannot govern a
        # sub-agent's chat; every sub-agent needs its own.
        #
        # @param max_steps [Integer] positive step cap for the
        #   sub-agent; defaults to the receiver's current cap
        # @return [StepLimit]
        # @raise [ArgumentError] if +max_steps+ is non-positive
        def for_sub_agent(max_steps: @max)
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
