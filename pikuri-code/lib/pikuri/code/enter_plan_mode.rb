# frozen_string_literal: true

module Pikuri
  module Code
    # The +enter_plan_mode+ tool: flips the shared
    # {Pikuri::Agent::Control::PlanMode} into its active, read-only
    # posture. Once active, the file-editing tools refuse to write
    # (see +pikuri-workspace+'s +Write+ / +Edit+) and the
    # {Extension}'s per-turn reminder tells the model to research and
    # propose rather than implement. The model exits via
    # {ExitPlanMode}; the host can also flip the same control from a
    # key binding (see {Pikuri::Agent::Control::PlanMode}).
    #
    # Self-entry is opportunistic: the model is encouraged (via the
    # description) to enter plan mode before a non-trivial change, but
    # entry is just as often host-initiated. Either way the flag is
    # the single source of truth.
    class EnterPlanMode < Pikuri::Tool
      # Description shown to the LLM. opencode-shape: one-line summary,
      # blank line, +Usage:+ bullets.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Enter plan mode: a read-only posture for researching and designing a change before writing any of it.

        Usage:
        - Reach for this before a non-trivial change — new features, multi-file edits, refactors, or anything with several valid approaches — so the user can sign off on the approach before code is written.
        - Skip it for small, unambiguous edits (a typo, an obvious one-line fix) and for pure research questions.
        - While in plan mode the file-editing tools are disabled; explore and reason freely, then present a plan with exit_plan_mode for approval.
        - When unsure, prefer entering: alignment up front is cheaper than redone work.
      DESC

      # @param plan_mode [Pikuri::Agent::Control::PlanMode] the shared
      #   plan-mode control to activate.
      # @return [EnterPlanMode]
      def initialize(plan_mode:)
        super(
          name: 'enter_plan_mode',
          description: DESCRIPTION,
          parameters: Parameters::EMPTY,
          execute: -> { EnterPlanMode.run(plan_mode: plan_mode) }
        )
      end

      # Activate plan mode (idempotent) and return the observation that
      # confirms the posture to the model.
      #
      # @param plan_mode [Pikuri::Agent::Control::PlanMode]
      # @return [String] tool observation
      def self.run(plan_mode:)
        plan_mode.enter!
        'You are now in plan mode (read-only): research and design only, do not edit ' \
          'files. When the plan is ready, call exit_plan_mode to present it for approval.'
      end
    end
  end
end
