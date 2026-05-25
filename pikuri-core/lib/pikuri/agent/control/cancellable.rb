# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Cooperative cancellation token. The instance is normally
      # constructed on the main thread and handed to
      # {Agent#initialize} via the +cancellable:+ kwarg; an
      # out-of-band caller (a SIGINT trap, a TUI key binding, an
      # IPC handler) calls {#cancel!} to flip the flag, and the
      # next {#check!} on the run thread raises {Cancelled} —
      # which {Agent#run_loop} catches, normalizes into an
      # {Event::Cancelled} on the listener stream, and re-raises
      # so the caller's REPL can return control to the user.
      #
      # == Cancellation boundary
      #
      # The +Agent+ calls {#check!} from its +before_tool_call+
      # wiring — between an LLM response that requested a tool
      # and the actual tool invocation — which is the only point
      # at which the conversation state is consistent (no
      # in-flight subprocess, no half-applied write). An in-flight
      # LLM HTTP call is *not* interrupted; the response lands,
      # then the next tool-call boundary trips. An in-flight tool
      # (notably +Bash+) is also not interrupted — cancellation
      # lands after the tool returns. Both are intentional v1
      # scope: the "gentle cancel" semantic that pikuri promises.
      #
      # == Thread safety
      #
      # {#cancel!} is intended to be called from a thread other
      # than the one running {Agent#run_loop} (the typical case
      # is a SIGINT trap handler on the main thread while the
      # agent runs on a worker, or vice versa). A plain boolean
      # ivar is sufficient under MRI: writes and reads of a
      # single reference are atomic with respect to the GVL, and
      # the only state transition we care about is +false → true+
      # before the next {#check!} fires. There is no double-cancel
      # hazard; repeated {#cancel!} calls are idempotent.
      #
      # == Sub-agent semantics
      #
      # Cancellation is a global "stop the whole tree" signal —
      # the +agent+ tool from +pikuri-subagents+ shares the
      # parent's +Cancellable+ by reference when spawning a child,
      # so one {#cancel!} call stops the parent, every running
      # sub-agent, and the synthesizer rescue. The sharing rule
      # lives at the spawn site (sub-agent code), not on this
      # class.
      class Cancellable
        # Raised by {#check!} once {#cancel!} has been called.
        # Carries no fields; the cancellation reason ("the user
        # asked us to stop") is implicit in the exception class.
        # {Agent#run_loop} catches this, emits {Event::Cancelled},
        # and re-raises so the caller (typically a REPL) can
        # return control to the user.
        class Cancelled < StandardError
          def initialize
            super('Agent loop cancelled')
          end
        end

        def initialize
          @cancelled = false
        end

        # Flip the flag. Safe to call from a thread other than
        # the one running the agent loop, and safe to call
        # multiple times (idempotent). Takes effect at the next
        # {#check!} on the run thread — see the class header for
        # the "gentle cancel" caveats.
        #
        # @return [void]
        def cancel!
          @cancelled = true
        end

        # @return [Boolean] whether {#cancel!} has been called
        #   since the last {#reset!}; observable from any thread.
        def cancelled?
          @cancelled
        end

        # Raise {Cancelled} when the flag is set; otherwise no-op.
        # Called by {Agent} from its +before_tool_call+ wiring.
        #
        # @return [void]
        # @raise [Cancelled] when {#cancel!} has been called since
        #   the last {#reset!}
        def check!
          raise Cancelled if @cancelled
        end

        # Reset the flag back to armed. Called by {Agent} at the
        # start of each turn so a stale cancellation from a prior
        # turn does not poison the next one. Mid-loop
        # {Control::Interloper} injections deliberately do *not*
        # trigger a reset — otherwise the cancel-then-inject
        # ordering would lose the cancellation: +cancel!+ sets
        # the flag, the injection lands and resets it, and the
        # next +before_tool_call+ no longer raises.
        #
        # @return [void]
        def reset!
          @cancelled = false
        end

        # @return [String] short label for {Agent#to_s}; reflects
        #   the current flag state so a startup banner or debug
        #   print can tell an armed token apart from one that has
        #   already tripped.
        def to_s
          "Cancellable(#{@cancelled ? 'cancelled' : 'armed'})"
        end
      end
    end
  end
end
