# frozen_string_literal: true

module Pikuri
  module Workspace
    # An {Pikuri::Agent::Extension} that wires the five file tools
    # ({Read}, {Grep}, {Glob}, {Edit}, {Write}) onto an agent, sharing a
    # single {Workspace} composite across them. That shared composite is
    # what makes the read-before-edit gate work: {Read} marks a path read
    # in the same record {Edit} and overwrite-{Write} consult.
    #
    # The single registration point also removes the five-line
    # +add_tool+ boilerplate every host would otherwise repeat —
    # +bin/pikuri-code+ today, +pikuri-tui+ / +pikuri-web+ / any
    # downstream gem on this surface tomorrow. Same opt-in shape as
    # {Pikuri::Tasks::Extension} / {Pikuri::Code::Extension}: the host
    # builds the {Filesystem} (its containment / sandbox policy is
    # host-specific) and the {Confirmer}, and hands them over; the
    # composite and its read record are an internal detail.
    #
    # Bash is *not* here — it isn't a read/edit/write tool and takes the
    # raw {Filesystem} (it governs the subprocess's filesystem view, not
    # the read record). It lives in {Pikuri::Code::Extension}.
    #
    # == Plan mode
    #
    # When the agent was built with a {Pikuri::Agent::Control::PlanMode}
    # (read off the {Pikuri::Agent::Configurator} as +c.plan_mode+), the
    # extension threads it into {Edit} and {Write} so they refuse while
    # plan mode is active — the read-only tools take no gate. The host
    # passes the control once, to +Agent.new+; it does not hand it here.
    # With no control wired the gate is simply off.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem: filesystem,
    #       confirmer: confirmer
    #     )
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # The five tools the extension owns. Also the duplicate-registration
      # guard list: the whole point is to be the single owner of the
      # shared {Workspace}, so a pre-registered file tool (bound to a
      # different composite) would defeat the read-ledger sharing.
      TOOL_CLASSES = [Read, Grep, Glob, Edit, Write].freeze

      # @return [Workspace] the composite shared across the five tools;
      #   exposed for tests / introspection.
      attr_reader :workspace

      # @param filesystem [Filesystem] path resolution / sandboxing;
      #   wrapped in a fresh {Workspace} (with an empty read record).
      # @param confirmer [Confirmer] consulted by {Write} before an
      #   overwrite.
      def initialize(filesystem:, confirmer:)
        @workspace = Workspace.new(filesystem: filesystem)
        @confirmer = confirmer
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered (in tools: or via c.add_tool) " \
                  'when adding Pikuri::Workspace::Extension — the extension auto-registers all five ' \
                  'file tools so they share one Workspace (and one read record).'
          end
        end

        # Plan mode (when the host wired a control onto Agent.new) is
        # read off the configurator and threaded into the two mutators
        # so they refuse while it is active — the read-only tools take
        # no gate. +nil+ when unwired, which disables the gate.
        plan_mode = c.plan_mode

        c.add_tool Read.new(workspace: @workspace)
        c.add_tool Grep.new(workspace: @workspace)
        c.add_tool Glob.new(workspace: @workspace)
        c.add_tool Edit.new(workspace: @workspace, plan_mode: plan_mode)
        c.add_tool Write.new(workspace: @workspace, confirmer: @confirmer, plan_mode: plan_mode)
        nil
      end
    end
  end
end
