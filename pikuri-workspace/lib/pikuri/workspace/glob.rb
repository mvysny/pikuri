# frozen_string_literal: true

module Pikuri
  module Workspace
    # The +glob+ tool — list files matching a glob pattern via
    # +rg --files+, sorted by modification time (newest first).
    # Instantiating +Glob.new(workspace: ws)+ produces a tool
    # whose {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to any
    # bundled tool's. Same shape as {Grep} (workspace captured by the
    # +execute+ closure, no confirmer — read-only).
    #
    # == Why a separate tool from Grep
    #
    # The unique capability is *mtime-descending sort* — "what's been
    # touched recently" is a common navigation move and Grep can't
    # express it. The rest (filter by name, default to listing all
    # matching files) is theoretically reachable through Grep with
    # +pattern="."+, but Glob avoids that hack and keeps Read / Grep /
    # Glob as three clean roles: read one file, search content, list
    # files by name.
    #
    # == ripgrep dependency
    #
    # Hard dependency: {.check_binaries!} runs in +initialize+ and
    # raises if +rg+ isn't on +PATH+. Each tool owns its own probe so
    # construction order doesn't matter — Glob doesn't lean on Grep's
    # check.
    #
    # == Argv & filter pipeline
    #
    #   rg --files --color=never --hidden --glob '!.git/*' \
    #      -- <relative-path-or-dot>
    #   # …then filter the result list in Ruby with File.fnmatch?
    #
    # Why not pass the user pattern as +--glob+ to rg? Because rg's
    # +--glob+ documentation says *"This always overrides any other
    # ignore logic"* — so +--glob '**/*.rb'+ would re-include
    # +.gitignore+'d Ruby files, breaking our gitignore-respect
    # promise. We let rg produce the full gitignore-respecting file
    # list and filter to the user's pattern in Ruby with
    # +File.fnmatch?(pattern, p, FNM_PATHNAME | FNM_EXTGLOB |
    # FNM_DOTMATCH)+. The three flags together cover the common rg
    # glob cases: +**+ recursion (+FNM_PATHNAME+), +{a,b}+ alternation
    # (+FNM_EXTGLOB+), and dotfile inclusion (+FNM_DOTMATCH+, matching
    # rg's +--hidden+ behavior). The +.git/+ exclusion stays on the rg
    # side so its contents never even reach the Ruby filter.
    #
    # * +--hidden+ → search dotfiles (still respects +.gitignore+).
    # * No +--sort+ flag: we re-sort by mtime in Ruby on the way out.
    # * Output paths come back as +./...+ when the search path is +.+;
    #   the leading +./+ is stripped post-rg so the model sees clean
    #   workspace-relative paths.
    #
    # == Sort
    #
    # mtime-descending in Ruby after rg returns, with path-ascending
    # as a tiebreaker for files with equal mtimes (the common case in
    # fresh checkouts). Cost: one +stat+ per result. Broad patterns
    # can make this expensive, but in practice rg's +.gitignore+ filter
    # keeps result sets bounded; if real friction shows up later we can
    # cap pre-sort.
    #
    # == Truncation
    #
    # Total output head-truncated to {MAX_BYTES} *after* mtime sort, so
    # the kept rows are the newest. Matches {Grep}'s budget and
    # head-bias.
    #
    # == Exit codes
    #
    # * +0+ → at least one file; format with footer.
    # * +1+ → no files; return +"No files match pattern '...'"+.
    # * +2+ → rg error (bad path, bad glob); return
    #   +"Error: ripgrep: ..."+.
    #
    # == Refusals
    #
    # All returned as +"Error: ..."+ observations:
    #
    # * Empty +pattern+ → fast reject.
    # * +path+ is a regular file → fast reject pointing at the +read+
    #   tool.
    # * +path+ not found → +"Error: path not found: <path>"+.
    # * +path+ outside the workspace → caught from
    #   {Filesystem::Error}.
    class Glob < Pikuri::Tool
      # @return [Integer] hard byte cap on combined rg output. Same
      #   value as {Grep::MAX_BYTES} so the two file-touching
      #   tools share a budget shape. Re-declared here rather than
      #   referenced cross-file because Zeitwerk's eager-load order
      #   isn't guaranteed between siblings.
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES} for the
      #   truncation marker.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # Description shown to the LLM. opencode-shape (summary +
      # +Usage:+ bullets). Per-parameter constraints live in parameter
      # descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        List files matching a glob pattern, sorted by modification time (newest first).

        Usage:
        - `.gitignore` is respected; for unfiltered listing use bash `rg --no-ignore --files -g <pattern>`.
        - Glob syntax: `**` matches any number of directories, `*` matches any filename chars (not `/`), `{a,b}` is alternation.
        - Default search root is the workspace root; pass `path` to narrow to a subdirectory.
        - Use `glob` to find files by name; use `grep` to find files by content.
        - Output is sorted by mtime descending — recently-touched files come first, so broad patterns still surface relevant files near the top.
        - Output is truncated to #{MAX_BYTES_LABEL}; refine the pattern or narrow `path` if the response ends in a truncation marker.
      DESC

      # @param workspace [Workspace] captured for path resolution
      #   and as +chdir+ for rg. All path arguments route through
      #   +workspace.resolve_for_read+.
      # @raise [RuntimeError] if +rg+ isn't on +PATH+; fail-loud at
      #   construction rather than the first tool call.
      # @return [Glob]
      def initialize(workspace:)
        Glob.send(:check_binaries!)
        super(
          name: 'glob',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :pattern,
                              'Glob pattern (** matches any number of ' \
                              'directories; {a,b} alternation), e.g. ' \
                              '"**/*.rb" or "lib/**/*_spec.rb".'
            p.optional_string :path,
                              'Directory to search in. Relative paths resolve ' \
                              'against the workspace root. Defaults to the ' \
                              'workspace root, e.g. "lib/" or "spec/".'
          },
          execute: lambda { |pattern:, path: nil|
            Glob.search(workspace: workspace, pattern: pattern, path: path)
          }
        )
      end

      # Produce a new {Glob} bound to +workspace+. Used by
      # {Pikuri::SubAgent::SubAgentTool} when a persona supplies a
      # +workspace_factory:+ — the parent's instance is rebuilt for
      # the sub-agent's fresh workspace so paths resolve against the
      # right root.
      #
      # @param workspace [Workspace]
      # @return [Glob]
      def with_workspace(workspace)
        self.class.new(workspace: workspace)
      end

      # Validate inputs, resolve the path against the workspace, spawn
      # rg, mtime-sort, head-truncate, render. Returns either the
      # formatted listing, a "no files match" message, or
      # +"Error: ..."+.
      #
      # @param workspace [Workspace]
      # @param pattern [String]
      # @param path [String, nil]
      # @return [String]
      def self.search(workspace:, pattern:, path:)
        return 'Error: empty pattern.' if pattern.empty?

        search_target = '.'
        if path
          resolved = workspace.resolve_for_read(path)
          return "Error: path not found: #{path}" unless resolved.exist?
          if resolved.file?
            return "Error: #{path} is a file, not a directory; use the read tool to view it."
          end

          rel = resolved.relative_path_from(workspace.project_root).to_s
          search_target = rel
        end

        argv = build_argv(path: search_target)
        result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.project_root.to_s).wait
        exit_code = result.status.exitstatus

        case exit_code
        when 0
          format_output(result.output, workspace: workspace,
                        pattern: pattern, path: path)
        when 1
          no_match_message(pattern: pattern, path: path)
        else
          stderr = result.output.strip
          stderr = "exited #{exit_code}" if stderr.empty?
          "Error: ripgrep: #{stderr}"
        end
      rescue Filesystem::Error => e
        "Error: #{e.message}"
      end

      # @return [Integer] flags for {File.fnmatch?}: +FNM_PATHNAME+ for
      #   +**+ recursion + path-aware +/+ matching, +FNM_EXTGLOB+ for
      #   +{a,b}+ alternation, +FNM_DOTMATCH+ to match dotfiles (rg
      #   does this when +--hidden+ is set).
      FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

      # Build the +rg+ argv. User pattern is NOT passed to rg — see
      # the class header for why (rg's +--glob+ overrides
      # +.gitignore+).
      #
      # @return [Array<String>]
      def self.build_argv(path:)
        [
          'rg',
          '--files',
          '--color=never',
          '--hidden',
          '--glob', '!.git/*',
          '--', path
        ]
      end
      private_class_method :build_argv

      # Strip the +./+ prefix rg adds when invoked with +.+ as the
      # search path, filter to the user pattern with +fnmatch+,
      # mtime-sort descending (path ascending as tiebreaker),
      # head-truncate at {MAX_BYTES}, append a footer summarizing the
      # count.
      #
      # @return [String]
      def self.format_output(raw, workspace:, pattern:, path:)
        all_paths = raw.split("\n").reject(&:empty?).map { |p| p.sub(%r{\A\./}, '') }
        paths = all_paths.select { |p| File.fnmatch?(pattern, p, FNMATCH_FLAGS) }
        return no_match_message(pattern: pattern, path: path) if paths.empty?

        sorted = mtime_sort(paths, workspace.project_root)
        joined = sorted.join("\n") + "\n"
        content, truncation_marker = head_truncate(joined)
        stripped = content.chomp
        count = stripped.split("\n").size

        footer = "Found #{pluralize(count, 'file', 'files')}."
        [stripped, '', footer + truncation_marker].join("\n")
      end
      private_class_method :format_output

      # mtime descending; path ascending for stable order on ties.
      #
      # @return [Array<String>]
      def self.mtime_sort(paths, base)
        paths
          .map { |p| [p, mtime_of(base + p)] }
          .sort_by { |(p, m)| [-m, p] }
          .map(&:first)
      end
      private_class_method :mtime_sort

      # @return [Float] epoch-seconds mtime; 0 for paths we can't stat
      #   (race between rg listing and our stat, deleted symlinks,
      #   etc.). The fallback puts unstattable entries at the bottom.
      def self.mtime_of(absolute)
        File.mtime(absolute).to_f
      rescue Errno::ENOENT
        0.0
      end
      private_class_method :mtime_of

      # Head-truncate +raw+ to {MAX_BYTES}, cutting at the last newline
      # boundary so the final row is never partial. Returns the
      # truncated content and a marker String (empty if no truncation).
      #
      # @return [Array(String, String)]
      def self.head_truncate(raw)
        total = raw.bytesize
        return [raw, ''] if total <= MAX_BYTES

        head = raw.byteslice(0, MAX_BYTES)
        last_nl = head.rindex("\n")
        head = head.byteslice(0, last_nl) if last_nl
        omitted = total - head.bytesize
        marker = "\n\n... [#{omitted} bytes omitted; total was #{total} bytes; " \
                 'refine pattern or path] ...'
        [head, marker]
      end
      private_class_method :head_truncate

      # @return [String]
      def self.no_match_message(pattern:, path:)
        base = "No files match pattern '#{pattern}'"
        base += " in #{path}" if path
        "#{base}."
      end
      private_class_method :no_match_message

      # @return [String] +"1 file"+ / +"2 files"+
      def self.pluralize(n, sing, plural)
        "#{n} #{n == 1 ? sing : plural}"
      end
      private_class_method :pluralize

      # Verify +rg+ is reachable on +PATH+. Routed through
      # {Pikuri::Subprocess.spawn} to honor the subprocess seam. rg
      # missing surfaces as +Errno::ENOENT+; an installed rg returns
      # exit 0 from +--version+.
      #
      # @return [void]
      # @raise [RuntimeError] if rg is missing
      def self.check_binaries!
        result = Pikuri::Subprocess.spawn('rg', '--version', chdir: '/').wait
        return if result.status.success?

        raise install_hint
      rescue Errno::ENOENT
        raise install_hint
      end
      private_class_method :check_binaries!

      # @return [String]
      def self.install_hint
        "Glob requires 'rg' (ripgrep) on PATH; install via your " \
          "distro's package manager (e.g. 'apt install ripgrep')."
      end
      private_class_method :install_hint
    end
  end
end
