# frozen_string_literal: true

module Pikuri
  class Agent
    module Control
      # Plan-mode flag: a read-only posture the agent can be put into
      # in which the file-mutation tools refuse to write and the model
      # is reminded, every turn, to research-and-propose rather than
      # edit. The instance is normally constructed on the main thread
      # and handed to {Agent#initialize} via the +plan_mode:+ kwarg;
      # two independent writers flip it and both write the *same* flag:
      #
      # * the **host** — a TUI key binding, a slash command, a startup
      #   default — calls {#enter!} / {#exit!} out-of-band, the same
      #   way it calls {Control::Cancellable#cancel!}; and
      # * the **model** — through the +enter_plan_mode+ /
      #   +exit_plan_mode+ tools (shipped by +pikuri-code+), which flip
      #   this very instance.
      #
      # The flag is the single source of truth for "are we planning
      # right now"; the tool and the key binding are just two
      # transitions into the same state. That is what lets a host-side
      # toggle the model never saw work identically to a model-side
      # one: whoever flips the flag, the per-turn reminder injected by
      # the +pikuri-code+ plan extension re-asserts the posture on the
      # next turn.
      #
      # == Not read by the Agent loop
      #
      # Unlike {Control::StepLimit} ({StepLimit#tick!}),
      # {Control::Cancellable} ({Cancellable#check!}), and
      # {Control::Interloper} ({Interloper#drain!}) — each of which the
      # {Agent} reads at a +Chat#complete+ callback boundary — this
      # control is read by the **tools and the extension**, never by
      # the loop. That is forced, not stylistic: ruby_llm owns the
      # loop and its +before_tool_call+ callback cannot substitute a
      # result, so the Agent has no way to deny a tool call *and* feed
      # the model an observation explaining why. The refusal therefore
      # lives inside each mutation tool's own +execute+ (the only place
      # that returns the next observation) — see +pikuri-workspace+'s
      # +Write+ / +Edit+, which take this control via constructor and
      # short-circuit when {#active?}. The Agent merely *holds* the
      # instance (so the host can reach it) and exposes it on the
      # {Configurator} (so the extension can pick it up).
      #
      # == Change notification
      #
      # {#on_change} registers a callback fired once per real
      # transition (off→on or on→off, never on a no-op flip), with the
      # new boolean state. The +pikuri-code+ plan extension wires this
      # to re-emit a domain event on the listener stream so UI chrome
      # (a status line) can render the current mode continuously,
      # sourced from this flag rather than inferred by the model.
      #
      # == Thread safety
      #
      # The two writers can live on different threads (the host's input
      # thread vs. the agent's run thread), so — unlike
      # {Control::Cancellable}, whose only transition is a monotonic
      # +false → true+ that a bare GVL-atomic boolean handles — this
      # control guards its compare-and-set with a {Mutex}: detecting
      # "did this call actually change the value" is a read-then-write
      # that is *not* atomic under the GVL, and getting it wrong would
      # fire the {#on_change} fan-out twice (or zero times) for one
      # logical transition. Callbacks run *outside* the lock so a
      # callback that re-enters this object (or blocks) can't deadlock
      # the next flip.
      class PlanMode
        # @param active [Boolean] initial posture; +true+ starts the
        #   agent already in plan mode (e.g. a +--plan+ startup flag).
        def initialize(active: false)
          @mutex = Mutex.new
          @active = active
          @on_change = []
        end

        # @return [Boolean] whether the agent is currently in plan
        #   mode. Observable from any thread.
        def active?
          @mutex.synchronize { @active }
        end

        # Enter plan mode. Idempotent: a no-op (and no {#on_change}
        # fan-out) when already active. Safe to call from a thread
        # other than the one running the agent loop.
        #
        # @return [void]
        def enter!
          flip(true)
        end

        # Exit plan mode. Idempotent: a no-op (and no {#on_change}
        # fan-out) when already inactive. Safe to call from a thread
        # other than the one running the agent loop.
        #
        # @return [void]
        def exit!
          flip(false)
        end

        # Register a callback fired once per real transition, with the
        # new state. Registration is typically a one-time wiring step
        # (the +pikuri-code+ extension's +bind+), but is guarded so a
        # late registration races safely with a concurrent flip.
        #
        # @yieldparam active [Boolean] the new posture
        # @return [void]
        # @raise [ArgumentError] when called without a block
        def on_change(&blk)
          raise ArgumentError, 'on_change requires a block' unless block_given?

          @mutex.synchronize { @on_change << blk }
          nil
        end

        # @return [String] short label for {Agent#to_s} / debug
        #   prints; reflects the current posture.
        def to_s
          "PlanMode(#{active? ? 'on' : 'off'})"
        end

        private

        # Compare-and-set under the lock; fan out to {#on_change}
        # callbacks outside it, only when the value actually changed.
        #
        # @param target [Boolean] desired posture
        # @return [void]
        def flip(target)
          callbacks = @mutex.synchronize do
            next nil if @active == target

            @active = target
            @on_change.dup
          end
          return nil unless callbacks

          callbacks.each { |cb| cb.call(target) }
          nil
        end
      end
    end
  end
end
