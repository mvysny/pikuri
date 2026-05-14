# frozen_string_literal: true

module Pikuri
  class Agent
    module Listener
      # Cooperative cancellation token wired into the chat's
      # +before_tool_call+ callback. The instance is normally constructed
      # on the main thread and handed to {Agent#initialize} via the
      # {ListenerList}; an out-of-band caller (a SIGINT trap, a TUI key
      # binding, an IPC handler) calls {#cancel!} to flip the flag, and
      # the next +before_tool_call+ on the chat raises {Cancelled} —
      # which {Agent#run_loop} catches, normalizes into a
      # {Agent::Message::Cancelled} event for the listener stream, and
      # re-raises so the caller's REPL can return control to the user.
      #
      # Like {StepLimit}, this is a control-flow listener rather than a
      # {MessageListener} subclass: it raises from the chat callback
      # instead of reacting to {Agent::Message} variants. The single
      # +on_message+ hook is used only to reset the flag at the start of
      # each turn so the same instance can govern many turns across a
      # long-running REPL.
      #
      # == Cancellation boundary
      #
      # The flag is checked at +before_tool_call+ — between an LLM
      # response that requested a tool and the actual tool invocation —
      # which is the only point at which the conversation state is
      # consistent (no in-flight subprocess, no half-applied write). An
      # in-flight LLM HTTP call is *not* interrupted; the response lands,
      # then the next tool-call boundary trips. An in-flight tool
      # (notably +Bash+) is also not interrupted — cancellation lands
      # after the tool returns. Both are intentional v1 scope: the
      # "gentle cancel" semantic that pikuri promises.
      #
      # == Thread safety
      #
      # {#cancel!} is intended to be called from a thread other than the
      # one running {Agent#run_loop} (the typical case is a SIGINT trap
      # handler on the main thread while the agent runs on a worker, or
      # vice versa). A plain boolean ivar is sufficient under MRI: writes
      # and reads of a single reference are atomic with respect to the
      # GVL, and the only state transition we care about is +false → true+
      # before the next callback fires. There is no double-cancel hazard;
      # repeated {#cancel!} calls are idempotent.
      #
      # == Sub-agent semantics
      #
      # {#for_sub_agent} returns +self+ — the same instance is shared by
      # reference across the parent, every sub-agent, and the
      # synthesizer rescue. One {#cancel!} call stops the whole tree.
      # This is the opposite policy from {StepLimit}, which gives each
      # agent its own counter (because step budgets are per-agent
      # concerns) — cancellation is a global signal from the user, so it
      # must propagate down.
      class Cancellable
        # Raised by the +before_tool_call+ callback once {#cancel!} has
        # been called. Carries no fields; the cancellation reason ("the
        # user asked us to stop") is implicit in the exception class.
        # {Agent#run_loop} catches this, emits {Agent::Message::Cancelled},
        # and re-raises so the caller (typically a REPL) can return
        # control to the user.
        class Cancelled < StandardError
          def initialize
            super('Agent loop cancelled')
          end
        end

        def initialize
          @cancelled = false
        end

        # Flip the flag. Safe to call from a thread other than the one
        # running the agent loop, and safe to call multiple times
        # (idempotent). Takes effect at the next +before_tool_call+
        # boundary on the attached chat — see the class header for
        # the "gentle cancel" caveats.
        #
        # @return [void]
        def cancel!
          @cancelled = true
        end

        # @return [Boolean] whether {#cancel!} has been called since the
        #   last reset; observable from any thread.
        def cancelled?
          @cancelled
        end

        # Wire the receiver into +chat+'s +before_tool_call+ callback.
        # The callback raises {Cancelled} when the flag is set, halting
        # the loop at the next tool-call boundary.
        #
        # @param chat [RubyLLM::Chat]
        # @return [void]
        def attach(chat)
          chat.before_tool_call do |_|
            raise Cancelled if @cancelled
          end
        end

        # Listener protocol hook. Resets the flag on a turn-starting
        # {Agent::Message::User} (+mid_loop_run: false+) — that variant
        # marks the start of a new turn by definition, so a stale
        # cancellation from a prior turn does not poison the next one.
        # Mid-loop injections (+mid_loop_run: true+, emitted by
        # {Listener::Interloper}) must *not* clear the flag — otherwise
        # the cancel-then-inject ordering would lose the cancellation:
        # +cancel!+ sets the flag, the injection's +Message::User+ lands
        # and resets it, and the next +before_tool_call+ no longer
        # raises. Every other variant is a no-op.
        #
        # @param message [Agent::Message]
        # @return [void]
        def on_message(message)
          case message
          in Agent::Message::User(mid_loop_run: false)
            @cancelled = false
          else
            # no-op
          end
        end

        # Sub-agent variant: the same instance, shared by reference, so a
        # single {#cancel!} stops the parent, every running sub-agent,
        # and the synthesizer rescue. See the class header for the
        # rationale.
        #
        # @return [Cancellable] the receiver
        def for_sub_agent(**)
          self
        end

        # @return [String] short label for {Agent#to_s}; reflects the
        #   current flag state so a startup banner or debug print can
        #   tell an armed token apart from one that has already tripped.
        def to_s
          "Cancellable(#{@cancelled ? 'cancelled' : 'armed'})"
        end
      end
    end
  end
end
