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
    # == Plan mode is opt-in via the read-only flag
    #
    # The plan-mode tools, the {PLAN_MODE_PROMPT} system-prompt
    # explainer, and the per-turn read-only reminder are wired only
    # when the host passes a {Pikuri::Workspace::ReadOnly} flag via the
    # +read_only:+ constructor argument. That same instance must be the
    # one the host hands the file-editing tools (through
    # {Pikuri::Workspace::Extension}'s own +read_only:+), so their
    # refusal and this reminder stay in lockstep on one flag. With no
    # flag, the extension still installs {Bash} + {GitClone} but no
    # plan-mode surface — plan mode is simply unavailable.
    #
    # The transition is surfaced as a {PlanModeChanged} domain event,
    # emitted from {#bind} off the flag's +on_change+ — a pikuri-code
    # concern, not a core agent event (the loop never reads plan mode).
    #
    # == Usage
    #
    #   read_only = Pikuri::Workspace::ReadOnly.new
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem:, confirmer:, read_only: read_only
    #     )
    #     c.add_extension Pikuri::Code::Extension.new(
    #       filesystem: filesystem,
    #       confirmer: confirmer,
    #       sandbox: sandbox,
    #       read_only: read_only
    #     )
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # Tool classes whose pre-registration is rejected — the extension
      # is the single owner of these, so a manually pre-registered copy
      # would shadow the wiring done here.
      TOOL_CLASSES = [Bash, EnterPlanMode, ExitPlanMode].freeze

      # Static plan-mode explainer, appended *once* to the system
      # prompt (and so prefix-cached) when plan mode is wired. The
      # mechanics and the active-behavior contract live here, paid
      # once; the per-turn injection ({PLAN_MODE_REMINDER}) is then
      # just a one-line state re-assertion, paid every turn at the
      # uncached tail. Same shape as {Pikuri::Tasks::Extension}'s
      # +PROMPT_SNIPPET+ — an extension-owned snippet that names its own
      # tools (the persona/extension carve-out to "no tool names in a
      # main prompt").
      #
      # @return [String]
      PLAN_MODE_PROMPT = <<~PROMPT
        <plan_mode>
        You can work in plan mode — a read-only posture for researching and designing a change before writing any of it. Reach for enter_plan_mode before a non-trivial change (new features, multi-file edits, refactors, anything with several viable approaches); the user can also turn plan mode on directly. While it is active you will see a short reminder each turn.

        While in plan mode:
        - The file-editing tools are disabled and will refuse — do not try to create, overwrite, or edit files.
        - Explore freely: read files, search the codebase, and run read-only shell commands.
        - Work out a concrete plan — which files change, the change to each, and any trade-offs — and write it out.
        - Call exit_plan_mode with that plan to present it for approval. Only start implementing once the user approves.
        - If a requirement is genuinely ambiguous, ask the user directly rather than guessing.
        </plan_mode>
      PROMPT

      # One-line per-turn state re-assertion, injected as a +:system+
      # message while plan mode is active (see {#on_user_message}). It
      # lands at the uncached tail after each user message, so it is
      # deliberately tiny — the substantive prose lives once, cached,
      # in {PLAN_MODE_PROMPT}. Inlined rather than read from +prompts/+
      # precisely because it is a single line.
      #
      # @return [String]
      PLAN_MODE_REMINDER =
        'Reminder: you are in plan mode (read-only) — research, design, ' \
        'and brainstorm, but do not edit files.'

      # Reason clause for a write/edit refusal *while plan mode is the
      # reason the workspace is read-only*. Handed to
      # {Pikuri::Workspace::ReadOnly} (via the host) so that a refused
      # Write/Edit names the recovery path — +exit_plan_mode+ — instead
      # of the generic {Pikuri::Workspace::ReadOnly::DEFAULT_MESSAGE},
      # which can't assume plan mode is the cause. The owning words live
      # here, in pikuri-code, beside {PLAN_MODE_PROMPT} /
      # {PLAN_MODE_REMINDER}; the host just wires it into the flag.
      #
      # @return [String]
      PLAN_MODE_READONLY_MESSAGE =
        'you are in plan mode (read-only). Add this change to your plan and ' \
        'call exit_plan_mode to present it; you can apply it once the user approves.'

      # @param filesystem [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Pikuri::Code::Bash::Sandbox]
      # @param read_only [Pikuri::Workspace::ReadOnly, nil] the shared
      #   read-only flag (the same one handed to
      #   {Pikuri::Workspace::Extension}). When present, the plan-mode
      #   tools + prompt + reminder + event are wired; +nil+ leaves plan
      #   mode unavailable.
      def initialize(filesystem:, confirmer:, sandbox: Bash::Sandbox::NONE, read_only: nil)
        @filesystem = filesystem
        @confirmer  = confirmer
        @sandbox    = sandbox
        @read_only  = read_only
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered when adding Pikuri::Code::Extension"
          end
        end

        c.add_tool Bash.new(filesystem: @filesystem, confirmer: @confirmer, sandbox: @sandbox)

        # Plan mode rides the host-owned read-only flag; only wire its
        # surface when one was supplied (see the class header).
        if @read_only
          c.add_tool EnterPlanMode.new(read_only: @read_only)
          c.add_tool ExitPlanMode.new(read_only: @read_only, confirmer: @confirmer)
          c.append_system_prompt(PLAN_MODE_PROMPT)
        end

        # GitClone is intentionally added via +add_sub_agent_tool+ only
        # (never visible to the parent). It exists solely for the
        # GIT_REPO_RESEARCHER persona.
        c.add_sub_agent_tool GitClone.new(filesystem: @filesystem)
        nil
      end

      # Bridge plan-mode transitions onto the listener stream so UI
      # chrome can render the current posture — for both model-driven
      # ({EnterPlanMode} / {ExitPlanMode}) and host-driven (key binding /
      # slash command) flips. No-op when plan mode isn't wired.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        return nil unless @read_only

        @read_only.on_change { |active| ctx.emit_event(PlanModeChanged.new(active: active)) }
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
        return nil unless @read_only&.active?

        PLAN_MODE_REMINDER
      end
    end
  end
end
