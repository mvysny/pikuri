# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Caps the number of tool calls per {Agent#run_loop}. ruby_llm has no
      # step budget; the +Agent+ pokes {#tick!} on every +before_tool_call+ and
      # {#reset!} at turn start. Once the count exceeds the cap, {#tick!} raises
      # {Exceeded} and the +Agent+ applies {#on_exhausted}: re-raise to the host
      # (default), or run the synthesizer to salvage a partial answer.
      #
      # == Why the policy lives here, not on +Agent+
      #
      # Synthesis can only fire off a tripped step limit, so an
      # +Agent.new(synthesize: ...)+ kwarg would be meaningless when
      # +step_limit:+ is +nil+ — an invalid combination. Attaching the policy to
      # the budget makes "what happens when it runs out" travel with the budget,
      # and that nonsense state unrepresentable. Hosts pick per wiring: a Q&A
      # REPL wants +:synthesize+ (salvage from evidence so far); a coding agent
      # wants +:raise+ (a tools-free pass can't finish code — stop, let the user
      # say "continue"; {#reset!} refreshes the budget next turn).
      class StepLimit
        # Valid {#on_exhausted} policies.
        ON_EXHAUSTED = %i[raise synthesize].freeze
        # Raised by {#tick!} once the tool-call count exceeds +max+; carries the
        # tripped budget for user-facing messages.
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

        # Increment the counter; raise {Exceeded} once it crosses {#max}. Called
        # from {Agent}'s +before_tool_call+ wiring.
        #
        # @return [void]
        # @raise [Exceeded] when the counter now exceeds {#max}
        def tick!
          @step += 1
          raise Exceeded, @max if @step > @max
        end

        # Reset the counter to zero. Called by {Agent} at each turn start so one
        # instance governs many turns. Mid-loop {Control::Interloper} injections
        # deliberately do *not* reset — they're context for the same turn, and a
        # chatty user could otherwise refresh the budget forever by injecting.
        #
        # @return [void]
        def reset!
          @step = 0
        end

        # @return [Integer] current step count.
        attr_reader :step

        # @return [String] short config dump for {Agent#to_s}; the policy
        #   renders only when the non-default +:synthesize+.
        def to_s
          policy = @on_exhausted == :raise ? '' : ", on_exhausted=#{@on_exhausted}"
          "StepLimit(max=#{@max}#{policy})"
        end
      end
    end
  end
end
