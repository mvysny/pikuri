# frozen_string_literal: true

module Pikuri
  module Code
    class ExitPlanMode < Pikuri::Tool
      # @return [Logger]
      LOGGER = Pikuri.logger_for('ExitPlanMode')

      # Description shown to the LLM. opencode-shape: summary + +Usage:+
      # bullets. Per-parameter constraints (default, max) live in the
      # parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Use this tool when you are in plan mode and have finished writing your plan to the plan file and are ready for user approval.

        ## How This Tool Works
        - Write your plan as an assistant chat message before calling this tool
        - This tool simply signals that you're done planning and ready for the user to review and approve
        - The user will see the contents of the message when they review it

        ## Before Using This Tool
        Ensure your plan is complete and unambiguous:
        - If you have unresolved questions about requirements or approach, ask the user directly, without calling any tools (in earlier phases)
        - Once your plan is finalized, use THIS tool to request approval

        ## Examples

        1. Initial task: "Search for and understand the implementation of vim mode in the codebase" - Do not use the exit plan mode tool because you are not planning the implementation steps of a task.
        2. Initial task: "Help me implement yank mode for vim" - Use the exit plan mode tool after you have finished planning the implementation steps of the task.
        3. Initial task: "Add a new feature to handle user authentication" - If unsure about auth method (OAuth, JWT, etc.), use AskUserQuestion first, then use exit plan mode tool after clarifying the approach.
      DESC

      def initialize
        super(
          name: 'exit_plan_mode',
          description: DESCRIPTION,
          parameters: Parameters::EMPTY,
          execute: -> { "Exited the plan mode. Wait until the user reads the plan and tells you to proceed" }
        )
      end
    end
  end
end
