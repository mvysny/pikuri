# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Caps the number of tool calls per {Agent#run_loop}
      # invocation. ruby_llm has no built-in step budget; the
      # +Agent+ pokes {#tick!} on every +before_tool_call+
      # callback and {#reset!} at the start of each turn. Once the
      # counter exceeds the configured cap, {#tick!} raises
      # {Exceeded} and the +Agent+ applies the {#on_exhausted}
      # policy: re-raise to the host (the default), or run the
      # step-exhaustion synthesizer to salvage a partial answer.
      #
      # == Why the policy lives here, not on +Agent+
      #
      # Synthesis can only ever fire off a tripped step limit, so
      # an +Agent.new(synthesize: ...)+ kwarg would be meaningless
      # whenever +step_limit:+ is +nil+ — an invalid combination
      # the API would have to document away. Attaching the policy
      # to the budget makes "what happens when the budget runs
      # out" travel with the budget, and the nonsense state is
      # unrepresentable. The host picks per wiring: a Q&A REPL
      # wants +:synthesize+ (salvage an answer from the evidence
      # gathered so far); a coding agent wants the default
      # +:raise+ (a tools-free pass can't finish writing code —
      # stop, let the user say "continue"; {#reset!} at the next
      # turn boundary refreshes the budget).
      class StepLimit
        # Valid {#on_exhausted} policies.
        ON_EXHAUSTED = %i[raise synthesize].freeze
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

        # @return [Symbol] what {Agent#run_loop} does when this
        #   budget trips: +:raise+ lets {Exceeded} propagate to the
        #   host; +:synthesize+ runs the tools-free synthesizer
        #   rescue. See the class header for how to pick.
        attr_reader :on_exhausted

        # @param max [Integer] hard cap on tool-call rounds; must
        #   be positive
        # @param on_exhausted [Symbol] +:raise+ (default) or
        #   +:synthesize+ — see {#on_exhausted}
        # @raise [ArgumentError] if +max+ is zero or negative, or
        #   +on_exhausted+ is not one of {ON_EXHAUSTED}
        def initialize(max:, on_exhausted: :raise)
          raise ArgumentError, "max must be positive, got #{max}" if max <= 0
          raise ArgumentError, "on_exhausted must be one of #{ON_EXHAUSTED.inspect}, got #{on_exhausted.inspect}" \
            unless ON_EXHAUSTED.include?(on_exhausted)

          @max = max
          @on_exhausted = on_exhausted
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

        # @return [String] short config dump for {Agent#to_s}.
        #   The policy only renders when it's the non-default
        #   +:synthesize+, so existing banner output is unchanged.
        def to_s
          policy = @on_exhausted == :raise ? '' : ", on_exhausted=#{@on_exhausted}"
          "StepLimit(max=#{@max}#{policy})"
        end
      end
    end
  end
end
