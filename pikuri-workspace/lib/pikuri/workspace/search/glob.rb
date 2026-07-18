# frozen_string_literal: true

module Pikuri
  module Workspace
    module Search
      # The +glob+ tool — list files matching a glob pattern via +rg --files+,
      # sorted by mtime (newest first). +Glob.new(workspace: ws)+ produces a tool
      # wired like any bundled tool's (workspace captured by the +execute+ closure,
      # no confirmer — read-only).
      #
      # == Why a separate tool from Grep
      #
      # The unique capability is *mtime-descending sort* — "what's been touched
      # recently", which Grep can't express. The rest is reachable via Grep with
      # +pattern="."+, but a separate tool keeps Read/Grep/Glob three clean roles:
      # read one file, search content, list files by name.
      #
      # == ripgrep dependency
      #
      # Hard: {.check_binaries!} runs in +initialize+ and raises if +rg+ isn't on
      # +PATH+. Each tool owns its probe so construction order doesn't matter.
      #
      # == Argv & filter pipeline
      #
      #   rg --files --color=never --hidden --glob '!.git/*' -- <path-or-dot>
      #   # …then filter the list in Ruby with File.fnmatch?
      #
      # The user pattern is NOT passed to rg as +--glob+: rg's +--glob+ *"always
      # overrides any other ignore logic"*, so it would re-include +.gitignore+'d
      # files, breaking the gitignore-respect promise. Instead rg produces the
      # full gitignore-respecting list and Ruby filters with
      # +File.fnmatch?(pattern, p, FNM_PATHNAME | FNM_EXTGLOB | FNM_DOTMATCH)+ —
      # the three flags covering +**+ recursion, +{a,b}+ alternation, and dotfiles
      # (matching +--hidden+). The +.git/+ exclusion stays on the rg side (an
      # explicit +--glob+, so it survives +--no-ignore+). Output +./+ prefixes
      # (from search path +.+) are stripped post-rg.
      #
      # == Sort / truncation / exit codes
      #
      # mtime-descending in Ruby (path-ascending tiebreaker), one +stat+ per
      # result — bounded in practice by rg's +.gitignore+ filter. Output
      # head-truncated to {MAX_BYTES} *after* sort so the newest rows survive; the
      # exit-2 error blob shares the same ceiling ({.truncate_error} — rg emits one
      # diagnostic per unreadable path). Exit +0+ → listing with footer; +1+ → "No
      # files match"; +2+ → +"Error: ripgrep: ..."+.
      #
      # == Refusals (all as +"Error: ..."+)
      #
      # Empty +pattern+; +path+ is a regular file (→ read tool); +path+ not found;
      # +path+ outside the workspace ({Filesystem::Error}); an oversized root (+/+
      # or the whole home dir — {Utils.oversized_root_refusal}).
      class Glob < Pikuri::Tool
        # @return [Integer] hard byte cap on combined rg output. Same value as
        #   {Grep::MAX_BYTES}; re-declared rather than cross-referenced because
        #   Zeitwerk's eager-load order between siblings isn't guaranteed.
        MAX_BYTES = 50 * 1024

        # @return [String] human-readable {MAX_BYTES} for the truncation marker.
        MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

        # Description shown to the LLM (opencode-shape). Per-parameter constraints
        # live in the parameter descriptions.
        #
        # @return [String]
        DESCRIPTION = <<~DESC
          List files matching a glob pattern, sorted by modification time (newest first).

          Usage:
          - Respects `.gitignore` by default; set `include_gitignored: true` to also list ignored files.
          - Default search root is the workspace root; pass `path` to narrow to a subdirectory.
          - Use `glob` to find files by name; use `grep` to find files by content.
          - Output is sorted by mtime descending — recently-touched files come first, so broad patterns still surface relevant files near the top.
          - Output is truncated to #{MAX_BYTES_LABEL}; refine the pattern or narrow `path` if the response ends in a truncation marker.
        DESC

        # @param workspace [Workspace] captured for path resolution and as +chdir+
        #   for rg; path arguments route through +resolve_for_read+.
        # @raise [RuntimeError] if +rg+ isn't on +PATH+ (fail-loud at construction).
        # @return [Glob]
        def initialize(workspace:)
          Glob.send(:check_binaries!)
          super(
            name: 'glob',
            description: DESCRIPTION,
            parameters: Parameters.build { |p|
              p.required_string :pattern,
                                'Glob pattern: ** matches any number of ' \
                                'directories, * matches any filename chars ' \
                                '(not /), {a,b} is alternation. E.g. ' \
                                '"src/**/*.{ts,tsx}" finds every TS/TSX file ' \
                                'anywhere under src/.'
              p.optional_string :path,
                                'Directory to search in. Relative paths resolve ' \
                                'against the workspace root. Defaults to the ' \
                'workspace root if missing.'
              p.optional_boolean :include_gitignored,
                                 'Also list files excluded by .gitignore. ' \
                                 'Defaults to false, e.g. true.'
            },
            execute: lambda { |pattern:, path: nil, include_gitignored: false|
              Glob.search(workspace: workspace, pattern: pattern, path: path,
                          include_gitignored: include_gitignored)
            }
          )
        end

        # A new {Glob} bound to +workspace+. Used by
        # {Pikuri::SubAgent::SubAgentTool} when a persona supplies a
        # +workspace_factory:+, so paths resolve against the sub-agent's root.
        #
        # @param workspace [Workspace]
        # @return [Glob]
        def with_workspace(workspace)
          self.class.new(workspace: workspace)
        end

        # Validate inputs, resolve the path, spawn rg, mtime-sort, head-truncate,
        # render. Returns the listing, a "no files match" message, or +"Error:
        # ..."+.
        #
        # @param workspace [Workspace]
        # @param pattern [String]
        # @param path [String, nil]
        # @param include_gitignored [Boolean] pass +--no-ignore+ to rg, so
        #   +.gitignore+'d files are listed too. Defaults to false.
        # @return [String]
        def self.search(workspace:, pattern:, path:, include_gitignored: false)
          return 'Error: empty pattern.' if pattern.empty?

          search_target = '.'
          resolved_root = workspace.project_root
          if path
            resolved = workspace.resolve_for_read(path)
            return "Error: path not found: #{path}" unless resolved.exist?
            if resolved.file?
              return "Error: #{path} is a file, not a directory; use the read tool to view it."
            end

            resolved_root = resolved
            rel = resolved.relative_path_from(workspace.project_root).to_s
            search_target = rel
          end

          if (refusal = Utils.oversized_root_refusal(resolved_root, verb: 'list'))
            return refusal
          end

          argv = build_argv(path: search_target, include_gitignored: include_gitignored)
          result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.project_root.to_s).wait
          exit_code = result.status.exitstatus

          case exit_code
          when 0
            format_output(result.output, workspace: workspace,
                          pattern: pattern, path: path)
          when 1
            no_match_message(pattern: pattern, path: path)
          else
            "Error: ripgrep: #{truncate_error(result.output, exit_code)}"
          end
        rescue Filesystem::Error => e
          "Error: #{e.message}"
        end

        # @return [Integer] flags for {File.fnmatch?}: +FNM_PATHNAME+ for
        #   +**+ recursion + path-aware +/+ matching, +FNM_EXTGLOB+ for
        #   +{a,b}+ alternation, +FNM_DOTMATCH+ to match dotfiles (rg
        #   does this when +--hidden+ is set).
        FNMATCH_FLAGS = File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH

        # Build the +rg+ argv. The user pattern is NOT passed to rg — see the
        # class header (rg's +--glob+ overrides +.gitignore+). The +.git/+
        # exclusion is an explicit +--glob+, so it survives +--no-ignore+.
        #
        # @return [Array<String>]
        def self.build_argv(path:, include_gitignored:)
          argv = [
            'rg',
            '--files',
            '--color=never',
            '--hidden',
            '--glob', '!.git/*'
          ]
          argv << '--no-ignore' if include_gitignored
          argv.push('--', path)
        end
        private_class_method :build_argv

        # Strip the +./+ prefix, filter to the user pattern with +fnmatch+,
        # mtime-sort descending (path-ascending tiebreaker), head-truncate at
        # {MAX_BYTES}, append a count footer.
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

        # Head-truncate +raw+ to {MAX_BYTES}, cutting at the last newline so the
        # final row is never partial. Returns the content and a marker (empty if
        # no truncation).
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

        # Head-truncate an rg error blob to {MAX_BYTES}. rg writes one diagnostic
        # per unreadable path (broken symlinks, permission denials — a listing
        # escaping into +~/.local/share/docker+ overlays), so on exit 2 the merged
        # stderr can run to hundreds of KB and overflow context; this gives the
        # error path the same ceiling as the success path.
        #
        # @param raw [String] rg's merged stdout+stderr
        # @param exit_code [Integer] for the empty-output fallback
        # @return [String]
        def self.truncate_error(raw, exit_code)
          stderr = raw.strip
          return "exited #{exit_code}" if stderr.empty?

          content, marker = head_truncate(stderr)
          content + marker
        end
        private_class_method :truncate_error

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

        # Verify +rg+ is on +PATH+ (via {Pikuri::Subprocess.spawn}, honoring the
        # subprocess seam). Missing → +Errno::ENOENT+; installed → exit 0.
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
end
