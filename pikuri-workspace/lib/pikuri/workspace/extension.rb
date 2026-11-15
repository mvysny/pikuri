# frozen_string_literal: true

module Pikuri
  module Workspace
    # An {Pikuri::Agent::Extension} that wires the file tools ({Read},
    # {Search::Grep}, {Search::Glob}, {FileList}, {Edit}, {Write}) onto an agent, sharing a single
    # {Workspace} composite — which is what makes the read-before-edit gate
    # work: {Read} marks a path read in the same record {Edit} and
    # overwrite-{Write} consult. One registration point removes the per-host
    # +add_tool+ boilerplate. The host builds the {Filesystem} and {Confirmer}
    # and hands them over; the composite and its read record are internal.
    #
    # A shell tool is *not* here — it isn't a read/edit/write tool, and a host
    # wiring one (pikuri-workshop's coding agent does) hands it the raw
    # {Filesystem}, since it governs a subprocess's fs view, not the read record.
    #
    # Contributes {PROMPT_SNIPPET} — the "a decline is final" confirmation
    # guidance — so it rides the wiring of the mutating tools instead of
    # being restated in each host prompt, plus the boot snapshot below.
    #
    # == Boot snapshot
    #
    # A depth-1 {Listing} of the workspace root, contributed once so
    # orientation costs zero tool calls — {Search::Glob} is +rg --files+, which
    # emits files only, so +glob '*'+ hides every directory:
    #
    #   <workspace_snapshot>
    #   The workspace root is /home/alice/proj. Its top level, as of the start of this conversation:
    #
    #   lib/  [1 dir, 1 file]
    #   spec/  [1 dir, 1 file]
    #   README.md  2.3K
    #
    #   One level only, and not refreshed — call `file_list` for anything deeper or newer.
    #   </workspace_snapshot>
    #
    # One level is the design, not a default to grow: {Listing}'s
    # +[N dirs, M files]+ column already does depth 2's job on the wide-flat
    # directories where depth 2 costs most — a blog's +_posts/  [0 dirs, 256
    # files]+ is 30 bytes against 24 KB expanded. Measurements and the rejected
    # ladder live in +design/decisions.md+ +D_directory_listing+.
    #
    # Taken once per agent, so a "/clear" — a new agent — refreshes it and
    # nothing else does.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(...) do |c|
    #     c.add_extension Pikuri::Workspace::Extension.new(
    #       filesystem: filesystem, confirmer: confirmer)
    #   end
    class Extension
      include Pikuri::Agent::Extension

      # The tools the extension owns, and the duplicate-registration guard
      # list: it must be the single owner of the shared {Workspace}, so a
      # pre-registered file tool (on a different composite) would defeat the
      # read-ledger sharing.
      TOOL_CLASSES = [Read, Search::Grep, Search::Glob, FileList, Edit, Write].freeze

      # @return [String] system-prompt guidance wired alongside the mutating
      #   tools: the confirmer may pause a write/edit (and a co-wired Bash)
      #   for the user's OK; a plain decline is final, a decline with words is
      #   guidance to follow. Contributed as a snippet
      #   so it tracks the wiring rather than each host prompt (the Os/Code
      #   precedent), and emitted unconditionally — an auto-approve ("yolo")
      #   confirmer is the rare exception, and the guidance is harmless there.
      PROMPT_SNIPPET = <<~SNIPPET.chomp
        A tool may ask the user to confirm before it makes a change. If they decline, stop: never reach the same end another way (a refused file write redone through a shell command, say) — tell them you stopped and wait for their guidance. If they decline and say something, follow what they said; a new proposal along those lines is fine, and they will be asked again.
      SNIPPET

      # @return [Integer] +depth+ the boot snapshot renders at. Deliberately
      #   not {Listing::DEFAULT_DEPTH}: both are 1 today, so folding them
      #   together compiles, passes, and silently re-points the snapshot the
      #   day {FileList}'s per-call default moves.
      SNAPSHOT_DEPTH = 1

      # @return [Integer] byte ceiling on the rendered snapshot; over it the
      #   snippet degrades to one line rather than head-truncating, because a
      #   truncated listing is an alphabetical prefix that teaches the model
      #   +spec/+ does not exist. Twice the largest root measured (a real
      #   +$HOME+), so it is a fail-safe, not a routine path.
      SNAPSHOT_MAX_BYTES = 2 * 1024

      # @return [Workspace] the composite shared across the tools;
      #   exposed for tests / introspection.
      attr_reader :workspace

      # @param filesystem [Filesystem] path resolution / sandboxing; wrapped in a
      #   fresh {Workspace} (empty read record).
      # @param confirmer [Confirmer] consulted by {Write} before an overwrite.
      # @param confirm_all_writes [Boolean] the host's write posture: +true+ (the
      #   OS-helper posture) confirms every writable write/edit with a diff and
      #   short-circuits unwritable targets; +false+ (default) keeps the classic
      #   policy. {Write} takes it directly; {Edit} infers the posture from
      #   whether a confirmer was passed, so this reaches Edit as
      #   +confirmer+-or-+nil+. See book/os-assistant.md.
      def initialize(filesystem:, confirmer:, confirm_all_writes: false)
        @workspace = Workspace.new(filesystem: filesystem)
        @confirmer = confirmer
        @confirm_all_writes = confirm_all_writes
      end

      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered (in tools: or via c.add_tool) " \
                  'when adding Pikuri::Workspace::Extension — the extension auto-registers every ' \
                  'file tool so they share one Workspace (and one read record).'
          end
        end

        c.add_tool Read.new(workspace: @workspace)
        c.add_tool Search::Grep.new(workspace: @workspace)
        c.add_tool Search::Glob.new(workspace: @workspace)
        c.add_tool FileList.new(workspace: @workspace)
        # Edit takes no posture flag: a non-nil confirmer *is* its
        # confirm-all-writes posture (see {Edit}), so +confirm_all_writes+
        # reaches Edit as confirmer-or-nil.
        c.add_tool Edit.new(workspace: @workspace, confirmer: @confirm_all_writes ? @confirmer : nil)
        c.add_tool Write.new(workspace: @workspace, confirmer: @confirmer,
                             confirm_all_writes: @confirm_all_writes)
        nil
      end

      # @return [Array<String>] the confirmation guidance ({PROMPT_SNIPPET}),
      #   always — the confirmer is wired on every non-yolo host — followed by
      #   the boot snapshot.
      # @raise [SystemCallError] if the workspace root itself can't be opened.
      #   Deliberately unhandled: it surfaces out of +Agent.new+, and a root you
      #   can't open is a wiring bug every file tool is about to hit anyway.
      def system_prompt_snippets = [PROMPT_SNIPPET, workspace_snapshot]

      private

      # The +<workspace_snapshot>+ block. An empty root and an over-cap root
      # each collapse to one line, so the block is never blank — which would
      # read as a failed walk — and never truncated.
      #
      # @return [String]
      def workspace_snapshot
        root    = @workspace.project_root
        listing = Listing.render(root, filesystem: @workspace.filesystem, depth: SNAPSHOT_DEPTH)
        body =
          if listing.empty?
            "The workspace root is #{root}. It is empty."
          elsif listing.bytesize > SNAPSHOT_MAX_BYTES
            "The workspace root is #{root}. It has too many entries to show " \
              'here — call `file_list` to explore it.'
          else
            "The workspace root is #{root}. Its top level, as of the start of " \
              "this conversation:\n\n#{listing}\n\nOne level only, and not " \
              'refreshed — call `file_list` for anything deeper or newer.'
          end
        "<workspace_snapshot>\n#{body}\n</workspace_snapshot>"
      end
    end
  end
end
