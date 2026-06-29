# frozen_string_literal: true

module Pikuri
  module Workspace
    # A workspace-scoped read-only flag: when active, the workspace's
    # *mutating file tools* ({Write} / {Edit}) refuse to write and return
    # a read-only observation instead of touching the filesystem. It is a
    # plain shared boolean with change notification — the host constructs
    # one and hands it to {Workspace::Extension} (which threads it into
    # Write/Edit) and to whatever drives it.
    #
    # == What this does NOT gate: Bash
    #
    # This flag governs only {Write} and {Edit}. It does **not** constrain
    # {Pikuri::Code::Bash}. A shell command is Turing-complete and there is
    # no reliable static test for "does this command write" — +echo+ with a
    # redirect, a script, a downloaded binary, +sed -i+, +>+, +dd+, a
    # Makefile target — so we make no attempt to gate Bash on this flag and
    # do not pretend to. A "read-only" workspace can still mutate the disk
    # (and beyond) through bash, subject only to bash's own confirmer. If a
    # host needs a truly inert posture it must also withhold or sandbox
    # bash; this flag is not that boundary. See {Pikuri::Code::Bash} and
    # {Pikuri::Code::Bash::Sandbox}.
    #
    # == Two writers, one flag
    #
    # The flag is the single source of truth for "are writes disabled right
    # now". Both a host (a key binding, a slash command, a startup default)
    # and a feature built on top of it (pikuri-code's +enter_plan_mode+ /
    # +exit_plan_mode+ tools, which call {#activate!} / {#deactivate!}) flip
    # the *same* instance. {#on_change} lets an observer (pikuri-code's plan
    # extension re-emits it as a {Pikuri::Code::PlanModeChanged} domain
    # event) render the current posture continuously, sourced from this flag
    # rather than inferred.
    #
    # == Not an Agent control
    #
    # Deliberately *not* under +Pikuri::Agent::Control+: unlike
    # {Pikuri::Agent::Control::StepLimit} / +Cancellable+ / +Interloper+,
    # the agent loop never reads this — it is consulted only by the Write /
    # Edit tools' +execute+ (the loop cannot deny a tool call and still feed
    # the model an explanatory observation, so the refusal lives inside the
    # tool, the one place that returns the next observation). It is a
    # workspace property, not a loop control.
    #
    # == Thread safety
    #
    # The two writers can live on different threads (a host input thread vs.
    # the agent's run thread), so the compare-and-set in {#flip} is guarded
    # by a {Mutex}: detecting "did this call actually change the value" is a
    # read-then-write that is not atomic under the GVL, and getting it wrong
    # would fire {#on_change} twice (or zero times) for one logical
    # transition. Callbacks run *outside* the lock so a callback that
    # re-enters this object (or blocks) can't deadlock the next flip.
    class ReadOnly
      # @param active [Boolean] initial posture; +true+ starts the
      #   workspace already read-only (e.g. a +--plan+ startup flag).
      def initialize(active: false)
        @mutex = Mutex.new
        @active = active
        @on_change = []
      end

      # @return [Boolean] whether writes are currently disabled.
      #   Observable from any thread.
      def active?
        @mutex.synchronize { @active }
      end

      # Turn the read-only posture on. Idempotent: a no-op (and no
      # {#on_change} fan-out) when already active. Safe to call from a
      # thread other than the one running the agent loop.
      #
      # @return [void]
      def activate!
        flip(true)
      end

      # Turn the read-only posture off. Idempotent: a no-op (and no
      # {#on_change} fan-out) when already inactive. Safe to call from a
      # thread other than the one running the agent loop.
      #
      # @return [void]
      def deactivate!
        flip(false)
      end

      # Register a callback fired once per real transition, with the new
      # state. Registration is typically a one-time wiring step (the
      # +pikuri-code+ extension's +bind+), but is guarded so a late
      # registration races safely with a concurrent flip.
      #
      # @yieldparam active [Boolean] the new posture
      # @return [void]
      # @raise [ArgumentError] when called without a block
      def on_change(&blk)
        raise ArgumentError, 'on_change requires a block' unless block_given?

        @mutex.synchronize { @on_change << blk }
        nil
      end

      # @return [String] short label for debug prints; reflects the
      #   current posture.
      def to_s
        "ReadOnly(#{active? ? 'on' : 'off'})"
      end

      private

      # Compare-and-set under the lock; fan out to {#on_change} callbacks
      # outside it, only when the value actually changed.
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
