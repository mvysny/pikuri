# frozen_string_literal: true

module Pikuri
  module Workspace
    module Search
      # The +grep+ tool — content search across the workspace via +ripgrep+.
      # +Grep.new(workspace: ws)+ produces a tool wired like any bundled tool's
      # (workspace captured by the +execute+ closure, no confirmer — read-only).
      #
      # == ripgrep dependency
      #
      # Hard: {.check_binaries!} runs in +initialize+ and raises if +rg+ isn't on
      # +PATH+. No Ruby fallback — replicating rg's Rust-regex dialect, globs, and
      # +.gitignore+ parsing is a dead end. The failure message includes the
      # install hint.
      #
      # == Argv
      #
      #   rg --line-number --color=never --no-heading --with-filename \
      #      --hidden --max-columns=2000 --max-columns-preview --sort=path \
      #      [-i] [--glob <g>] [--files-with-matches|--count-matches] \
      #      -- <pattern> <path-or-dot>
      #
      # * +--no-heading+ + +--with-filename+ → flat +path:line:content+ rows even
      #   for a single-file search (rg suppresses the filename there by default).
      # * +--hidden+ → search dotfiles (still respects +.gitignore+).
      # * +--max-columns=2000 --max-columns-preview+ → rg truncates long lines
      #   server-side with a preview marker.
      # * +--sort=path+ → deterministic (single-threaded; fine under ~10k files).
      # * The subprocess is *always* given an explicit path arg: {Subprocess}'s
      #   +popen2e+ gives the child a piped stdin, and rg's no-path heuristic would
      #   then search that (closed) stdin and match nothing. Output +./+ prefixes
      #   (from path +.+) are stripped post-rg.
      #
      # == Output modes
      #
      # +content+ (default, +path:line:content+) · +files_with_matches+ (paths) ·
      # +count+ (+path:count+). Use +files_with_matches+ to scope a broad search
      # cheaply before paying for +content+.
      # The cheap modes and the {MAX_BYTES} cap are one budget lever, confirmed
      # as such by an outside-model review (Grok 4.6, 2026-08): collapsing to a
      # +content+-only grep is a regression, not a simplification.
      #
      # == Credential paths
      #
      # Pruned twice: +rg --glob '!…'+ keeps rg out of the subtree, and every
      # surviving output line whose path sits under a denied root is dropped —
      # the guarantee if the pruning ever goes partial (see
      # {Utils.reject_denied_lines}). Without it a single
      # +grep 'BEGIN PRIVATE KEY'+ returns what {Read} refuses to open.
      #
      # == Truncation / exit codes
      #
      # Head-truncated to {MAX_BYTES} (head-only — grep tails carry less signal;
      # opposite bias from {Pikuri::Code::Bash}), cut at a line boundary with a
      # marker. The exit-2 error blob shares the ceiling ({.truncate_error} — rg
      # emits one diagnostic per unreadable path). Exit +0+ → results with footer;
      # +1+ → "No matches"; +2+ → +"Error: ripgrep: ..."+.
      #
      # == Refusals (all as +"Error: ..."+)
      #
      # Empty +pattern+; unknown +output_mode+; path outside the workspace
      # ({Filesystem::Error}); nonexistent path; an oversized root (+/+ or the
      # whole home dir). The oversized-root refusal doesn't dead-end: it hands
      # back a one-level listing of the root's entries so the model can pick a
      # subdir as +path+ and retry with no extra call (see
      # {Utils.oversized_root_refusal}).
      #
      # Sharing: +P_one_agent+, as {Glob} — stateless in itself, bound to one
      # agent's {Pikuri::Workspace::Workspace}. Each call shells out to a fresh
      # +rg+, so concurrent searches don't interact.
      class Grep < Pikuri::Tool
        # @return [Integer] hard byte cap on combined rg output. Same value as
        #   {Read::MAX_BYTES}.
        MAX_BYTES = 50 * 1024

        # @return [String] human-readable {MAX_BYTES} for the truncation marker.
        MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

        # @return [Integer] per-line cap passed to rg's +--max-columns+; long
        #   lines are truncated server-side with a preview marker.
        MAX_LINE_LENGTH = 2000

        # @return [Array<String>] valid +output_mode+ values.
        OUTPUT_MODES = %w[content files_with_matches count].freeze

        # @return [String] default +output_mode+.
        DEFAULT_OUTPUT_MODE = 'content'

        # Description shown to the LLM (opencode-shape). Per-parameter constraints
        # live in the parameter descriptions.
        #
        # @return [String]
        DESCRIPTION = <<~DESC
          Search file contents for a regex pattern across the workspace.

          Usage:
          - Wraps `ripgrep` — regex syntax is rg's Rust-regex dialect (mostly PCRE-compatible; no lookbehind).
          - Default search root is the workspace root; pass `path` to narrow to a file or subdirectory.
          - Respects `.gitignore` by default; set `include_gitignored: true` to also search ignored files.
          - Use `files_with_matches` first to scope a broad search, then `content` (or `read`) to investigate — saves tokens.
          - Output is truncated to #{MAX_BYTES_LABEL}; refine the pattern or narrow `path` if the response ends in a truncation marker.
          - Long lines are truncated to #{MAX_LINE_LENGTH} chars with a preview marker; use `read` to see full lines.
        DESC

        # @param workspace [Workspace] captured for path resolution and as +chdir+
        #   for rg; path arguments route through +resolve_for_read+.
        # @raise [RuntimeError] if +rg+ isn't on +PATH+ (fail-loud at construction).
        # @return [Grep]
        def initialize(workspace:)
          Grep.send(:check_binaries!)
          super(
            name: 'grep',
            description: DESCRIPTION,
            parameters: Parameters.build { |p|
              p.required_string :pattern,
                                'Regex pattern to search for (rg Rust-regex ' \
                                'dialect), e.g. "def\s+\w+" or "TODO".'
              p.optional_string :path,
                                'File or directory to search (e.g. "lib" or ' \
                                '"src/app.rb"). Relative paths resolve against ' \
                                'the workspace root. Defaults to the workspace root.'
              p.optional_string :glob,
                                'Filename glob restricting which files are ' \
                                'searched: ** matches any number of ' \
                                'directories, {a,b} is alternation. E.g. ' \
                                '"*.rb" or "src/**/*.{ts,tsx}".'
              p.optional_boolean :case_insensitive,
                                 'Match case-insensitively. Defaults to false, e.g. true.'
              p.optional_string :output_mode,
                                "One of #{OUTPUT_MODES.join(', ')}. Defaults to " \
                                "#{DEFAULT_OUTPUT_MODE}, e.g. \"files_with_matches\"."
              p.optional_boolean :include_gitignored,
                                 'Also search files excluded by .gitignore. ' \
                                 'Defaults to false, e.g. true.'
            },
            execute: lambda { |pattern:, path: nil, glob: nil, case_insensitive: false,
                              output_mode: DEFAULT_OUTPUT_MODE, include_gitignored: false|
              Grep.search(workspace: workspace, pattern: pattern, path: path,
                          glob: glob, case_insensitive: case_insensitive,
                          output_mode: output_mode, include_gitignored: include_gitignored)
            },
            trifecta_legs: Tool::TrifectaLegs.new(
              private: workspace.filesystem.private?,
              untrusted: workspace.filesystem.trusted? ? :none : :hard,
              egress_payload_review: :no_egress
            )
          )
        end

        # A new {Grep} bound to +workspace+. Used by
        # {Pikuri::SubAgent::SubAgentTool} when a persona supplies a
        # +workspace_factory:+, so paths resolve against the sub-agent's root.
        #
        # @param workspace [Workspace]
        # @return [Grep]
        def with_workspace(workspace)
          self.class.new(workspace: workspace)
        end

        # Validate inputs, resolve the path, spawn rg, render the observation.
        # Returns the results, a "no matches" string, or +"Error: ..."+.
        #
        # @param workspace [Workspace]
        # @param pattern [String]
        # @param path [String, nil]
        # @param glob [String, nil]
        # @param case_insensitive [Boolean]
        # @param output_mode [String]
        # @param include_gitignored [Boolean] pass +--no-ignore+ to rg, so
        #   +.gitignore+'d files are searched too. Defaults to false.
        # @return [String]
        def self.search(workspace:, pattern:, path:, glob:, case_insensitive:, output_mode:,
                        include_gitignored: false)
          return 'Error: empty pattern.' if pattern.empty?
          unless OUTPUT_MODES.include?(output_mode)
            return "Error: output_mode must be one of #{OUTPUT_MODES.join(', ')}, " \
                   "got #{output_mode.inspect}."
          end

          search_target = '.'
          resolved_root = workspace.project_root
          if path
            resolved = workspace.resolve_for_read(path)
            return "Error: path not found: #{path}" unless resolved.exist?

            resolved_root = resolved
            rel = resolved.relative_path_from(workspace.project_root).to_s
            search_target = rel
          end

          if (refusal = Utils.oversized_root_refusal(resolved_root, filesystem: workspace.filesystem,
                                                     verb: 'search'))
            return refusal
          end

          denied_prefixes = Utils.denied_prefixes(filesystem: workspace.filesystem,
                                                  root: workspace.project_root)
          argv = build_argv(pattern: pattern, glob: glob,
                            case_insensitive: case_insensitive,
                            output_mode: output_mode, path: search_target,
                            include_gitignored: include_gitignored,
                            denied_globs: denied_prefixes.flat_map { |rel| ['--glob', "!#{rel}"] })

          result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.project_root.to_s).wait
          exit_code = result.status.exitstatus

          case exit_code
          when 0
            format_output(result.output, output_mode: output_mode,
                          pattern: pattern, path: path,
                          denied_prefixes: denied_prefixes)
          when 1
            no_match_message(pattern: pattern, path: path)
          else
            "Error: ripgrep: #{truncate_error(result.output, exit_code)}"
          end
        rescue Filesystem::Error => e
          "Error: #{e.message}"
        end

        # Build the +rg+ argv. Path is always passed (defaults to +.+) — see the
        # class header.
        #
        # @return [Array<String>]
        def self.build_argv(pattern:, glob:, case_insensitive:, output_mode:, path:,
                            include_gitignored:, denied_globs: [])
          argv = [
            'rg',
            '--line-number',
            '--color=never',
            '--no-heading',
            '--with-filename',
            '--hidden',
            "--max-columns=#{MAX_LINE_LENGTH}",
            '--max-columns-preview',
            '--sort=path'
          ]
          argv.concat(denied_globs)
          argv << '--no-ignore' if include_gitignored
          argv << '-i' if case_insensitive
          argv.push('--glob', glob) if glob
          case output_mode
          when 'files_with_matches' then argv << '--files-with-matches'
          when 'count'              then argv << '--count-matches'
          end
          argv.push('--', pattern, path)
          argv
        end
        private_class_method :build_argv

        # Render rg output: strip the +./+ prefix, head-truncate at {MAX_BYTES},
        # append a count footer.
        #
        # @return [Tool::Result] the hits, carrying +"Found 7 matches in 3
        #   files"+
        def self.format_output(raw, output_mode:, pattern:, path:, denied_prefixes:)
          # The guarantee, after build_argv's pruning did the cheap 99%. Runs on
          # ./-stripped text so the prefixes are workspace-relative like rg's.
          cleaned = Utils.reject_denied_lines(strip_dot_slash(raw), prefixes: denied_prefixes)
          content, truncation_marker = head_truncate(cleaned)
          stripped = content.chomp

          return no_match_message(pattern: pattern, path: path) if stripped.empty?

          phrase = match_phrase(stripped, output_mode)
          Tool::Result.new(content: [stripped, '', "Found #{phrase}." + truncation_marker].join("\n"),
                           summary: "Found #{phrase}")
        end
        private_class_method :format_output

        # Strip leading +./+ from each line — rg emits it when invoked with +.+ as
        # the search path; we want clean workspace-relative paths.
        #
        # @return [String]
        def self.strip_dot_slash(raw)
          raw.gsub(/^\.\//, '')
        end
        private_class_method :strip_dot_slash

        # Head-truncate +raw+ to {MAX_BYTES}. Returns the content and a marker
        # (empty if no truncation).
        #
        # @return [Array(String, String)]
        def self.head_truncate(raw)
          Utils.head_truncate(raw, max_bytes: MAX_BYTES, hint: 'refine pattern or path')
        end
        private_class_method :head_truncate

        # Head-truncate an rg error blob to {MAX_BYTES}. rg writes one diagnostic
        # per unreadable path (broken symlinks, permission denials — a search
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

        # The counted phrase the observation's footer and the display summary are
        # both built from — +"7 matches in 3 files"+, +"3 files"+ in
        # +files_with_matches+ mode.
        #
        # @return [String]
        def self.match_phrase(content, output_mode)
          lines = content.split("\n").reject(&:empty?)
          case output_mode
          when 'content'
            files = lines.map { |l| l.split(':', 2).first }.uniq
            "#{Pikuri::Tool.pluralize(lines.size, 'match', 'matches')} in " \
              "#{Pikuri::Tool.pluralize(files.size, 'file', 'files')}"
          when 'files_with_matches'
            Pikuri::Tool.pluralize(lines.size, 'file', 'files')
          when 'count'
            total = lines.sum { |l| Integer(l.split(':').last) }
            "#{Pikuri::Tool.pluralize(total, 'match', 'matches')} in " \
              "#{Pikuri::Tool.pluralize(lines.size, 'file', 'files')}"
          end
        end
        private_class_method :match_phrase

        # @return [Tool::Result] the "nothing matched" observation, carrying
        #   +"Found 0 matches"+
        def self.no_match_message(pattern:, path:)
          base = "No matches for pattern '#{pattern}'"
          base += " in #{path}" if path
          Tool::Result.new(content: "#{base}.", summary: 'Found 0 matches')
        end
        private_class_method :no_match_message

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
          "Grep requires 'rg' (ripgrep) on PATH; install via your " \
            "distro's package manager (e.g. 'apt install ripgrep')."
        end
        private_class_method :install_hint
      end
    end
  end
end
