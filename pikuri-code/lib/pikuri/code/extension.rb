# frozen_string_literal: true

module Pikuri
  module Code
    # An {Pikuri::Agent::Extension} that wires the four pikuri-code
    # specific tools ({Bash}, {EnterPlanMode}, {ExitPlanMode},
    # {GitClone} as a sub-agent-only tool).
    #
    # The extension owns only pikuri-code's own surface; callers are
    # still expected to add Skill, Tasks, Mcp and SubAgent extensions
    # themselves if they want those features.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Code::Extension.new(
    #       workspace: workspace,
    #       confirmer: confirmer,
    #       sandbox: sandbox
    #     )
    #   end
    class Extension
      include Pikuri::Agent::Extension

      TOOL_CLASSES = [Bash, EnterPlanMode, ExitPlanMode].freeze

      # @param workspace [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Pikuri::Code::Bash::Sandbox]
      def initialize(workspace:, confirmer:, sandbox: Bash::Sandbox::NONE)
        @workspace = workspace
        @confirmer = confirmer
        @sandbox   = sandbox
      end

      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered when adding Pikuri::Code::Extension"
          end
        end

        c.add_tool Bash.new(workspace: @workspace, confirmer: @confirmer, sandbox: @sandbox)
        c.add_tool EnterPlanMode.new
        c.add_tool ExitPlanMode.new
        # GitClone is intentionally added via +add_sub_agent_tool+ only
        # (never visible to the parent). It exists solely for the
        # GIT_REPO_RESEARCHER persona.
        c.add_sub_agent_tool GitClone.new(workspace: @workspace)
        nil
      end
    end
  end
end
