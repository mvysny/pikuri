# frozen_string_literal: true

module Pikuri
  module Code
    # The +exit_plan_mode+ tool: presents the finished plan to the
    # user for approval and, on a yes, flips the shared
    # {Pikuri::Agent::Control::PlanMode} back off so the file-editing
    # tools work again.
    #
    # == Approval rides the Confirmer seam
    #
    # The plan is shown — and the yes/no is collected — through the
    # same {Pikuri::Workspace::Confirmer} the +write+ / +bash+ tools
    # already use, so presentation, attacker-text sanitization, and
    # the answer cue live in one place rather than in tool code. On
    # approval the control is flipped off and the model is told to
    # proceed; on a decline the control stays on and the observation
    # steers the model to refine and re-present, never to edit. The
    # plan text is LLM-authored, so it is passed as the request
    # +detail+ — the Confirmer neutralizes it before display.
    class ExitPlanMode < Pikuri::Tool
      # Description shown to the LLM. opencode-shape: one-line summary,
      # blank line, +Usage:+ bullets.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Exit plan mode by presenting your finished implementation plan for the user's approval.

        Usage:
        - Call this only once your plan is complete and unambiguous; pass the full plan as the `plan` argument.
        - The user is shown the plan and asked to approve. On approval you leave plan mode and may implement it; on a decline you stay in plan mode — refine the plan and call this again.
        - If a requirement is still unclear, ask the user directly first (without leaving plan mode) rather than presenting a half-formed plan.
        - Do not use this for pure research tasks — those never enter plan mode in the first place.
      DESC

      # @param plan_mode [Pikuri::Agent::Control::PlanMode] the shared
      #   plan-mode control to deactivate on approval.
      # @param confirmer [Pikuri::Workspace::Confirmer] consulted to
      #   present the plan and collect the approval.
      # @return [ExitPlanMode]
      def initialize(plan_mode:, confirmer:)
        super(
          name: 'exit_plan_mode',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :plan,
                              'Your complete implementation plan, in Markdown, ' \
                              'shown to the user for approval. Cover the files ' \
                              'to change and the changes to each, e.g. ' \
                              '"## Plan\n1. Add X to foo.rb\n2. ...".'
          },
          execute: ->(plan:) {
            ExitPlanMode.run(plan_mode: plan_mode, confirmer: confirmer, plan: plan)
          }
        )
      end

      # Present +plan+ for approval; on yes deactivate plan mode, on no
      # keep it active. Returns the observation the model reacts to.
      #
      # @param plan_mode [Pikuri::Agent::Control::PlanMode]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param plan [String] the LLM-authored plan to show the user
      # @return [String] tool observation
      def self.run(plan_mode:, confirmer:, plan:)
        unless plan_mode.active?
          return 'Error: not in plan mode, so there is nothing to exit. ' \
                 'Proceed with the work directly.'
        end

        request = Pikuri::Workspace::Confirmer::Request.new(
          question: 'Approve this plan? (approving exits plan mode and lets the agent edit files)',
          detail: plan
        )

        if confirmer.confirm?(request: request)
          plan_mode.exit!
          'Plan approved — you are no longer in plan mode. Implement the plan now.'
        else
          'The user did not approve the plan; you are still in plan mode (read-only). ' \
            'Ask what they would like changed, revise the plan, and call exit_plan_mode ' \
            'again when ready. Do not edit any files.'
        end
      end
    end
  end
end
