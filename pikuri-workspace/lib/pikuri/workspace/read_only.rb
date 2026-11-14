# frozen_string_literal: true

module Pikuri
  module Workspace
    # A workspace-scoped read-only flag: when active, the mutating file tools
    # ({Write}/{Edit}) refuse to write and return a read-only observation
    # instead. A plain shared boolean with change notification — the host
    # constructs one and hands it to {Workspace::Extension} (which threads it
    # into Write/Edit) and to whatever drives it.
    #
    # Enforcement is the point, so a prompt-only "plan mode" is not a cheaper
    # version of this: an outside-model review (Grok 4.6, 2026-08) rated the
    # posture it *couldn't* talk its way past over being told to "think step by
    # step and then start editing".
    #
    # == What this does NOT gate: a shell
    #
    # This governs only {Write}/{Edit}, **not** a co-wired shell tool. A shell
    # command is Turing-complete with no reliable static "does this write" test
    # (+echo+ + redirect, +sed -i+, +>+, +dd+, a Makefile target), so we make no
    # attempt to gate one and don't pretend to: a "read-only" workspace can
    # still mutate disk through a shell, subject only to the shell's own
    # confirmer. A truly inert posture must also withhold or sandbox the shell;
    # this flag is not that boundary.
    #
    # == Two writers, one flag
    #
    # The single source of truth for "are writes disabled now". Both a host (a
    # key binding, a slash command) and a feature on top (a plan mode the model
    # enters and leaves through {#activate!}/{#deactivate!}) flip the *same*
    # instance. {#on_change} lets an observer (one re-emitting it as a domain
    # event on the agent's stream) render the posture continuously.
    #
    # == Not an Agent control
    #
    # Deliberately not under +Pikuri::Agent::Control+: unlike +Cancellable+ /
    # +Interloper+, the loop never reads this — only Write/Edit's
    # +execute+ does (the loop can't deny a tool call *and* feed the model an
    # explanatory observation, so the refusal lives in the tool). It's a
    # workspace property, not a loop control.
    #
    # Thread-safe: the two writers may be on different threads, so the
    # compare-and-set in {#flip} is +Mutex+-guarded (a read-then-write isn't
    # atomic under the GVL; getting it wrong would fire {#on_change} twice or
    # zero times). Callbacks run *outside* the lock so a re-entrant or blocking
    # one can't deadlock the next flip.
    class ReadOnly
      # Default reason clause when the host gives no +message:+. Posture-agnostic
      # — it must NOT assume plan mode (a host can engage read-only for other
      # reasons); {Write}/{Edit} splice it after their own "cannot <verb> <path>
      # — " prefix. A driving feature (plan mode) passes its own.
      #
      # @return [String]
      DEFAULT_MESSAGE = 'the workspace is read-only, so changes are disabled right now'

      # @param active [Boolean] initial posture; +true+ starts read-only (a
      #   +--plan+ startup flag).
      # @param message [String] the reason clause {Write}/{Edit} append; default
      #   {DEFAULT_MESSAGE}. Immutable — the host supplies the wording.
      def initialize(active: false, message: DEFAULT_MESSAGE)
        @mutex = Mutex.new
        @active = active
        @message = message
        @on_change = []
      end

      # @return [String] the reason clause to surface when a write is
      #   refused; see {#initialize}.
      attr_reader :message

      # @return [Boolean] whether writes are currently disabled.
      #   Observable from any thread.
      def active?
        @mutex.synchronize { @active }
      end

      # Turn the posture on. Idempotent (no {#on_change} when already active);
      # safe off the loop thread.
      #
      # @return [void]
      def activate!
        flip(true)
      end

      # Turn the posture off. Idempotent (no {#on_change} when already inactive);
      # safe off the loop thread.
      #
      # @return [void]
      def deactivate!
        flip(false)
      end

      # Register a callback fired once per real transition, with the new state.
      # Guarded so a late registration races safely with a concurrent flip.
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

      # Compare-and-set under the lock; fan out to {#on_change} outside it, only
      # when the value actually changed.
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
