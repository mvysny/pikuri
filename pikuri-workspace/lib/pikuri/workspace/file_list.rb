# frozen_string_literal: true

module Pikuri
  module Workspace
    # The +file_list+ tool — the only way the model learns that a directory
    # *exists*. {Search::Glob} is built on +rg --files+, which emits files
    # only, so +glob '*'+ at a monorepo root shows the loose root files and
    # hides every gem.
    #
    #   FileList.list(workspace: ws, path: 'pikuri-workspace/lib', depth: 2)   # =>
    #   pikuri/
    #     workspace/  [2 dirs, 12 files]
    #   pikuri-workspace.rb  961B
    #
    # Row format is {Listing}'s; this class owns only the LLM-facing surface —
    # parameter validation, +resolve_for_read+, and the refusals.
    #
    # Not under +Workspace::Search::+ where Grep and Glob live: listing a
    # folder is a read of it, not a search. Borrowing {Search::Utils} is reuse,
    # not membership.
    #
    # == Refusals (all as +"Error: ..."+)
    #
    # +depth+ below 1; +path+ is a regular file (→ read tool); +path+ not
    # found; +path+ outside the workspace ({Filesystem::Error}); an oversized
    # root, which hands back the root's own entries to pick from rather than
    # dead-ending (see {Search::Utils.oversized_root_refusal}). A +depth+ over
    # {Listing::MAX_DEPTH} is clamped, not refused — the answer is still the
    # one asked for, just shallower.
    #
    # Sharing: +P_one_agent+ — it never touches the read record, so nothing
    # races; what makes it one agent's is the {Workspace} it enumerates, since
    # that is one agent's project view (a sub-agent's clone differs).
    # +with_workspace+ rebinds a copy.
    class FileList < Pikuri::Tool
      # Description shown to the LLM (opencode-shape). Per-parameter constraints
      # live in the parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        List what is inside a directory: subdirectories first, then files, sorted by name.

        Usage:
        - Reach for this first in an unfamiliar tree — it is the only tool that shows you which subdirectories exist.
        - Directories end with `/` and carry a count of what is inside them (`[3 dirs, 1 file]`); files carry their size.
        - Raise `depth` to see nested structure in one call rather than listing each subdirectory in turn.
        - Everything on disk is listed, including files `.gitignore` hides; use `glob` instead when you want a gitignore-respecting search by filename pattern.
        - Output is truncated to #{Listing::MAX_BYTES_LABEL}; list a subdirectory if the response ends in a truncation marker.
      DESC

      # @param workspace [Workspace] captured for path resolution; path
      #   arguments route through +resolve_for_read+.
      # @return [FileList]
      def initialize(workspace:)
        super(
          name: 'file_list',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.optional_string :path,
                              'Directory to list (e.g. "lib" or ' \
                              '"spec/pikuri"). Relative paths resolve against ' \
                              'the workspace root. Defaults to the workspace ' \
                              'root if missing.'
            p.optional_integer :depth,
                               'How many levels to descend. Defaults to ' \
                               "#{Listing::DEFAULT_DEPTH} (immediate children " \
                               "only); values above #{Listing::MAX_DEPTH} are " \
                               "capped at #{Listing::MAX_DEPTH}."
          },
          execute: lambda { |path: nil, depth: Listing::DEFAULT_DEPTH|
            FileList.list(workspace: workspace, path: path, depth: depth)
          },
          # Filenames and sizes, not contents — same reasoning as Glob: a path
          # can be as sensitive as a file and is as attacker-authorable, so
          # this reads the same as Read.
          trifecta_legs: Tool::TrifectaLegs.new(
            private: workspace.filesystem.private?,
            untrusted: workspace.filesystem.trusted? ? :none : :hard,
            egress_payload_review: :no_egress
          )
        )
      end

      # The workspace root renders as +.+ rather than as nothing: +path+ is
      # optional and the model usually omits it, which the generic default
      # would show as a bare +FileList+.
      #
      # @param arguments [Hash] raw tool-call arguments
      # @return [String]
      def describe_call(arguments)
        Pikuri::Tool.one_line((arguments['path'] || arguments[:path] || '.').to_s)
      end

      # A new {FileList} bound to +workspace+. Used by
      # {Pikuri::SubAgent::SubAgentTool} when a persona supplies a
      # +workspace_factory:+, so paths resolve against the sub-agent's root.
      #
      # @param workspace [Workspace]
      # @return [FileList]
      def with_workspace(workspace)
        self.class.new(workspace: workspace)
      end

      # Resolve +path+, refuse a file / missing / oversized root, render.
      #
      # @param workspace [Workspace]
      # @param path [String, nil] raw path from the LLM; +nil+ means the
      #   workspace root
      # @param depth [Integer] levels to descend
      # @return [Tool::Result] the listing (+"Listed 31 entries"+), or
      #   {Pikuri::Tool::Result.error}
      def self.list(workspace:, path:, depth:)
        return Tool::Result.error("depth must be >= 1, got #{depth}") if depth < 1

        resolved = path ? workspace.resolve_for_read(path) : workspace.project_root
        return Tool::Result.error("path not found: #{path}") unless resolved.exist?
        return Tool::Result.error("#{path} is a file, not a directory; use the read tool to view it.") if resolved.file?

        if (refusal = Search::Utils.oversized_root_refusal(resolved, filesystem: workspace.filesystem,
                                                          verb: 'list'))
          return Tool::Result.error(refusal)
        end

        listing, entries = Listing.render_with_count(resolved, filesystem: workspace.filesystem, depth: depth)
        return Tool::Result.new(content: '(Empty directory)', summary: 'Listed 0 entries') if listing.empty?

        Tool::Result.new(content: listing,
                         summary: "Listed #{Pikuri::Tool.pluralize(entries, 'entry', 'entries')}")
      rescue Filesystem::Error => e
        Tool::Result.error(e.message)
      rescue SystemCallError => e
        Tool::Result.error("cannot list #{path || '.'}: #{e.message}")
      end
    end
  end
end
