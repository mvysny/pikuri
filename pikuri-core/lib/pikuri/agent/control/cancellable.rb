# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Cooperative cancellation token. Built on the main thread and handed to
      # {Agent#initialize} via +cancellable:+; an out-of-band caller (a SIGINT
      # trap, a TUI key, an IPC handler) calls {#cancel!} to flip the flag, and
      # the next {#check!} on the run thread raises {Cancelled} — which
      # {Agent#run_loop} catches, emits as {Event::Cancelled}, and re-raises so
      # the REPL returns control to the user.
      #
      # == Cancellation boundary
      #
      # The +Agent+ calls {#check!} from +before_tool_call+ — between an LLM
      # response requesting a tool and the tool invocation — the only point
      # where conversation state is consistent (no in-flight subprocess, no
      # half-applied write). An in-flight LLM HTTP call is *not* interrupted
      # (the response lands, then the next boundary trips), nor is an in-flight
      # tool (notably +Bash+). Both are the intentional "gentle cancel" v1 scope.
      #
      # == Sub-agent semantics
      #
      # Cancellation is a global "stop the whole tree" signal — the +agent+ tool
      # shares the parent's +Cancellable+ by reference with each child, so one
      # {#cancel!} stops the parent, every sub-agent, and the synthesizer. The
      # sharing rule lives at the spawn site, not here.
      #
      # Thread-safe: {#cancel!} is meant to run on a thread other than the loop's
      # (a SIGINT trap while the agent runs on a worker). A plain boolean ivar
      # suffices under MRI — the only transition that matters is +false → true+
      # before the next {#check!}, and repeated {#cancel!} is idempotent.
      class Cancellable
        # Raised by {#check!} once {#cancel!} has been called; carries no fields.
        # {Agent#run_loop} catches it, emits {Event::Cancelled}, and re-raises.
        class Cancelled < StandardError
          def initialize
            super('Agent loop cancelled')
          end
        end

        def initialize
          @cancelled = false
        end

        # Flip the flag. Safe off the loop thread and idempotent. Takes effect
        # at the next {#check!} — see the class header for the gentle-cancel
        # caveats.
        #
        # @return [void]
        def cancel!
          @cancelled = true
        end

        # @return [Boolean] whether {#cancel!} has been called since the last
        #   {#reset!}; observable from any thread.
        def cancelled?
          @cancelled
        end

        # Raise {Cancelled} when the flag is set, else no-op. Called from
        # {Agent}'s +before_tool_call+ wiring.
        #
        # @return [void]
        # @raise [Cancelled] when {#cancel!} has been called since {#reset!}
        def check!
          raise Cancelled if @cancelled
        end

        # Reset the flag to armed. Called by {Agent} at each turn start so a
        # stale cancel doesn't poison the next turn. Mid-loop
        # {Control::Interloper} injections deliberately do *not* reset —
        # otherwise cancel-then-inject would lose the cancel (the injection
        # resets the flag before the next +before_tool_call+ reads it).
        #
        # @return [void]
        def reset!
          @cancelled = false
        end

        # @return [String] short label for {Agent#to_s}, reflecting the flag state.
        def to_s
          "Cancellable(#{@cancelled ? 'cancelled' : 'armed'})"
        end
      end
    end
  end
end
