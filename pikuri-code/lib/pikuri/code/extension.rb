# frozen_string_literal: true

module Pikuri
  module Code
    # An {Pikuri::Agent::Extension} that wires pikuri-code's own
    # tools: {Bash}, the plan-mode pair ({EnterPlanMode} /
    # {ExitPlanMode}), and {GitClone} as a sub-agent-only tool.
    #
    # The extension owns only pikuri-code's own surface; callers are
    # still expected to add Skill, Tasks, Mcp and SubAgent extensions
    # themselves if they want those features.
    #
    # == Plan mode is opt-in via the control
    #
    # The plan-mode tools, the per-turn read-only reminder, and the
    # {PlanModeChanged} UI event are wired only when the agent was
    # constructed with a {Pikuri::Agent::Control::PlanMode} — read off
    # the {Pikuri::Agent::Configurator} as {Configurator#plan_mode}.
    # That same instance must be the one the host hands the file-editing
    # tools ({Pikuri::Workspace::Write} / {Pikuri::Workspace::Edit}),
    # so their refusal and this reminder stay in lockstep. With no
    # control wired, the extension still installs {Bash} + {GitClone}
    # but no plan-mode surface — plan mode is simply unavailable.
    #
    # == Usage
    #
    #   plan_mode = Pikuri::Agent::Control::PlanMode.new
    #   Pikuri::Agent.new(..., plan_mode: plan_mode) do |c|
    #     c.add_tool Pikuri::Workspace::Edit.new(workspace:, plan_mode:)
    #     c.add_tool Pikuri::Workspace::Write.new(workspace:, confirmer:, plan_mode:)
    #     c.add_extension Pikuri::Code::Extension.new(
    #       workspace: workspace,
    #       confirmer: confirmer,
    #       sandbox: sandbox
    #     )
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # Tool classes whose pre-registration is rejected — the extension
      # is the single owner of these, so a manually pre-registered copy
      # would shadow the wiring done here.
      TOOL_CLASSES = [Bash, EnterPlanMode, ExitPlanMode].freeze

      # @param workspace [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Pikuri::Code::Bash::Sandbox]
      def initialize(workspace:, confirmer:, sandbox: Bash::Sandbox::NONE)
        @workspace = workspace
        @confirmer = confirmer
        @sandbox   = sandbox
        @plan_mode = nil
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered when adding Pikuri::Code::Extension"
          end
        end

        c.add_tool Bash.new(workspace: @workspace, confirmer: @confirmer, sandbox: @sandbox)

        # Plan mode rides the host-owned control; only wire its surface
        # when one was given to Agent.new (see the class header).
        @plan_mode = c.plan_mode
        if @plan_mode
          c.add_tool EnterPlanMode.new(plan_mode: @plan_mode)
          c.add_tool ExitPlanMode.new(plan_mode: @plan_mode, confirmer: @confirmer)
        end

        # GitClone is intentionally added via +add_sub_agent_tool+ only
        # (never visible to the parent). It exists solely for the
        # GIT_REPO_RESEARCHER persona.
        c.add_sub_agent_tool GitClone.new(workspace: @workspace)
        nil
      end

      # Bridge plan-mode transitions onto the listener stream so UI
      # chrome can render the current posture — for both model-driven
      # ({EnterPlanMode} / {ExitPlanMode}) and host-driven (key
      # binding) flips. No-op when plan mode isn't wired.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        return nil unless @plan_mode

        @plan_mode.on_change { |active| ctx.emit_event(PlanModeChanged.new(active: active)) }
        nil
      end

      # Inject the read-only reminder as a +:system+ message on every
      # turn that plan mode is active — the soft half of plan mode's
      # defense, re-asserting the posture even when the *host* engaged
      # it and the model never saw a tool call. Returns +nil+ (inject
      # nothing) when plan mode is off or unwired.
      #
      # @param _ctx [Pikuri::Agent::ExtensionContext]
      # @param _content [String]
      # @return [String, nil]
      def on_user_message(_ctx, _content)
        return nil unless @plan_mode&.active?

        @reminder ||= Pikuri.prompt(:'plan-mode-reminder')
      end
    end
  end
end
