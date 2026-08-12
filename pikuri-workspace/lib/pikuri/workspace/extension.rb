# frozen_string_literal: true

module Pikuri
  module Workspace
    # An {Pikuri::Agent::Extension} that wires the five file tools ({Read},
    # {Search::Grep}, {Search::Glob}, {Edit}, {Write}) onto an agent, sharing a single
    # {Workspace} composite — which is what makes the read-before-edit gate
    # work: {Read} marks a path read in the same record {Edit} and
    # overwrite-{Write} consult. One registration point removes the per-host
    # +add_tool+ boilerplate. Same opt-in shape as {Pikuri::Tasks::Extension}:
    # the host builds the {Filesystem} and {Confirmer} and hands them over; the
    # composite and its read record are internal.
    #
    # Bash is *not* here — it isn't a read/edit/write tool and takes the raw
    # {Filesystem} (it governs the subprocess's fs view, not the read record).
    # It lives in {Pikuri::Code::Extension}.
    #
    # Contributes {PROMPT_SNIPPET} — the "a decline is final" confirmation
    # guidance — so it rides the wiring of the mutating tools instead of
    # being restated in each host prompt.
    #
    # == Read-only gate
    #
    # A {ReadOnly} flag (when the host passes one) is threaded into {Edit}/{Write}
    # so they refuse while active — the read-only tools take no gate. The host
    # owns the flag and hands the *same* instance to whatever drives it
    # (pikuri-code's plan mode). No flag → gate off. Covers Write/Edit only,
    # never Bash — see {ReadOnly}.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem: filesystem, confirmer: confirmer)
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # The five tools the extension owns, and the duplicate-registration guard
      # list: it must be the single owner of the shared {Workspace}, so a
      # pre-registered file tool (on a different composite) would defeat the
      # read-ledger sharing.
      TOOL_CLASSES = [Read, Search::Grep, Search::Glob, Edit, Write].freeze

      # @return [String] system-prompt guidance wired alongside the mutating
      #   tools: the confirmer may pause a write/edit (and a co-wired Bash)
      #   for the user's OK, and a decline is final. Contributed as a snippet
      #   so it tracks the wiring rather than each host prompt (the Os/Code
      #   precedent), and emitted unconditionally — an auto-approve ("yolo")
      #   confirmer is the rare exception, and the guidance is harmless there.
      PROMPT_SNIPPET = <<~SNIPPET.chomp
        A tool may ask you to confirm before it makes a change. If the user declines, stop rather than trying another route to the same end — a decline means they want to re-steer you, so hand back and wait for their guidance.
      SNIPPET

      # @return [Workspace] the composite shared across the five tools;
      #   exposed for tests / introspection.
      attr_reader :workspace

      # @param filesystem [Filesystem] path resolution / sandboxing; wrapped in a
      #   fresh {Workspace} (empty read record).
      # @param confirmer [Confirmer] consulted by {Write} before an overwrite.
      # @param read_only [ReadOnly, nil] when set, threaded into {Edit}/{Write}
      #   so they refuse while active; +nil+ (default) leaves the gate off.
      # @param confirm_all_writes [Boolean] the host's write posture: +true+ (the
      #   OS-helper posture) confirms every writable write/edit with a diff and
      #   short-circuits unwritable targets; +false+ (default) keeps the classic
      #   policy. {Write} takes it directly; {Edit} infers the posture from
      #   whether a confirmer was passed, so this reaches Edit as
      #   +confirmer+-or-+nil+. See book/os-assistant.md.
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

        # The read-only flag (when supplied) is threaded into the two mutators;
        # the read-only tools take no gate. +nil+ disables it.
        c.add_tool Read.new(workspace: @workspace)
        c.add_tool Search::Grep.new(workspace: @workspace)
        c.add_tool Search::Glob.new(workspace: @workspace)
        # Edit takes no posture flag: a non-nil confirmer *is* its
        # confirm-all-writes posture (see {Edit}), so +confirm_all_writes+
        # reaches Edit as confirmer-or-nil.
        c.add_tool Edit.new(workspace: @workspace, read_only: @read_only,
                            confirmer: @confirm_all_writes ? @confirmer : nil)
        c.add_tool Write.new(workspace: @workspace, confirmer: @confirmer,
                             read_only: @read_only, confirm_all_writes: @confirm_all_writes)
        nil
      end

      # Clear the shared read-record when the host clears the conversation, so
      # the read-before-edit gate forgets what the discarded conversation read —
      # else an {Edit} right after "/clear" could touch a file the model can no
      # longer see. The {Filesystem}'s policy is untouched; only the read-ledger
      # resets.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext] unused; protocol signature.
      # @return [void]
      def on_conversation_reset(_ctx)
        @workspace.clear_reads
        nil
      end

      # @return [Array<String>] the confirmation guidance ({PROMPT_SNIPPET}),
      #   always — the confirmer is wired on every non-yolo host.
      def system_prompt_snippets = [PROMPT_SNIPPET]
    end
  end
end
