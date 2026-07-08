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
    # == Read-only gate
    #
    # When the host passes a {ReadOnly} flag, the extension threads it into
    # {Edit} and {Write} so they refuse while it is active — the read-only
    # tools ({Read} / {Grep} / {Glob}) take no gate. The host owns the
    # flag and hands the *same* instance to whatever drives it (pikuri-code
    # wires it into its +enter_plan_mode+ / +exit_plan_mode+ tools). With
    # no flag the gate is simply off. Note: this gate covers Write/Edit
    # only, never Bash — see {ReadOnly}.
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
      # @param read_only [ReadOnly, nil] when set, threaded into {Edit}
      #   and {Write} so they refuse while it is active; +nil` (default)
      #   leaves the gate off. See "Read-only gate".
      # @param confirm_all_writes [Boolean] the host's write posture: when
      #   +true+ (the full-disk OS-helper posture) every writable write/edit
      #   confirms with a diff and unwritable targets short-circuit;
      #   +false+ (default) keeps the classic policy (Write confirms
      #   overwrites only, Edit stays promptless). {Write} takes this flag
      #   directly; {Edit} has no such flag — it infers the posture from
      #   whether a confirmer was passed (see {Edit}), so this reaches Edit
      #   as +confirmer+-or-+nil+. See the guide's ch7.
      def initialize(filesystem:, confirmer:, read_only: nil, confirm_all_writes: false)
        @workspace = Workspace.new(filesystem: filesystem)
        @confirmer = confirmer
        @read_only = read_only
        @confirm_all_writes = confirm_all_writes
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

        # The read-only flag (when the host supplied one) is threaded into
        # the two mutators so they refuse while it is active — the
        # read-only tools take no gate. +nil+ when unwired, which disables
        # the gate.
        c.add_tool Read.new(workspace: @workspace)
        c.add_tool Grep.new(workspace: @workspace)
        c.add_tool Glob.new(workspace: @workspace)
        # Edit takes no posture flag: a non-nil confirmer *is* its
        # confirm-all-writes posture (see {Edit}). So the host's
        # +confirm_all_writes+ choice reaches Edit as confirmer-or-nil —
        # promptless default, diff-confirmed under the OS-helper posture.
        c.add_tool Edit.new(workspace: @workspace, read_only: @read_only,
                            confirmer: @confirm_all_writes ? @confirmer : nil)
        c.add_tool Write.new(workspace: @workspace, confirmer: @confirmer,
                             read_only: @read_only, confirm_all_writes: @confirm_all_writes)
        nil
      end

      # Clear the shared read-record when the host clears the
      # conversation, so the read-before-edit gate forgets what the
      # now-discarded conversation read. Without this, an {Edit} right
      # after a "/clear" could touch a file the model can no longer see
      # in its (wiped) context — defeating the gate's "you must Read
      # first" promise. The {Filesystem}'s containment / sandbox policy
      # is untouched; only the session read-ledger resets.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext] unused; part of the
      #   protocol signature.
      # @return [void]
      def on_conversation_reset(_ctx)
        @workspace.clear_reads
        nil
      end
    end
  end
end
