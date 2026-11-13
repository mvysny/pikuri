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
      # The host resets it each time it starts a turn, on its own thread, before
      # it hands the turn to a worker:
      #
      #   cancellable.reset!
      #   Thread.new { agent.run_loop(user_message: message) }
      #   # Escape, any time from here on: cancellable.cancel!
      #
      # A cancel sent before the worker reaches {Agent#run_loop} then still
      # ends that turn. A host that forgets {#reset!} sees every turn after the
      # first cancel end at once.
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
      # {#sleep} widens that boundary by one case: code *waiting* inside a tool
      # can wait through this instead of +Kernel#sleep+ and become
      # interruptible. It reaches waits only — a thread blocked in IO (a Faraday
      # read, +Subprocess#wait+) is still uninterruptible, so most of a tool's
      # blocking is untouched by design.
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

        # Longest a {#sleep} stays unresponsive to a {#cancel!}: it wakes on
        # this cadence to re-check the flag. Polling rather than a
        # +ConditionVariable+ because {#cancel!} must stay callable from a
        # SIGINT trap, where taking a +Mutex+ raises +ThreadError+ — so the
        # waking side pays, and the signalling side stays a bare flag write.
        #
        # @return [Float] seconds
        SLICE_SECONDS = 0.1

        def initialize
          @cancelled = false
        end

        # A token that never trips — the null object for code that structurally
        # needs one (a {#sleep} to wait through, a +cancellable:+ parameter) when
        # the host wired no cancellation. Frozen, so a stray {#cancel!} raises
        # +FrozenError+ rather than silently cancelling every agent that
        # defaulted to it. Defined below {#initialize} so +@cancelled+ is set.
        #
        # @return [Cancellable]
        NEVER = new.freeze

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

        # Wait +seconds+, cutting the wait short with {Cancelled} if {#cancel!}
        # lands while waiting — the drop-in for +Kernel#sleep+ anywhere a tool
        # paces or polls:
        #
        #   cancellable.sleep(2.0)   # returns after 2s, or raises on a cancel
        #
        # Checks the flag before waiting at all, so an already-cancelled token
        # raises without a delay, and a non-positive +seconds+ is still a
        # cancellation check rather than a no-op. Wakes every {SLICE_SECONDS} to
        # look, so a cancel is honoured within that.
        #
        # @param seconds [Float] how long to wait; +<= 0+ returns at once.
        # @return [void]
        # @raise [Cancelled] if {#cancel!} has been called, before or during
        #   the wait.
        def sleep(seconds)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
          loop do
            check!
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return if remaining <= 0

            # Kernel., or this recurses into itself.
            Kernel.sleep([remaining, SLICE_SECONDS].min)
          end
        end

        # Clear the flag for a new turn. The host calls it where it decides a
        # turn starts, under whatever guards its "running" state — never the
        # agent: {Agent#run_loop} can't tell a cancel left over from the last
        # turn from one sent early for this one. The agent's own boundaries
        # (a mid-loop {Control::Interloper} injection, a sub-agent's turn on
        # the shared token) leave it alone, or they would swallow a pending
        # cancel. +design/decisions.md+ +D_host_resets_cancel+.
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
