# frozen_string_literal: true

module Pikuri
  module Workspace
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
    # ({Filesystem::Error}); nonexistent path.
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
        - Respects `.gitignore` — for unfiltered search use bash `rg --no-ignore <pattern>`.
        - Use `glob` to filter by filename, e.g. `"*.rb"` or `"src/**/*.{ts,tsx}"`.
        - `output_mode` controls verbosity: `content` (default, file:line:text), `files_with_matches` (paths only), `count` (matches per file).
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
                              'File or directory to search. Relative paths ' \
                              'resolve against the workspace root. Defaults ' \
                              'to the workspace root, e.g. "lib/" or "lib/foo.rb".'
            p.optional_string :glob,
                              'Filename glob to filter files, e.g. "*.rb" ' \
                              'or "src/**/*.{ts,tsx}".'
            p.optional_boolean :case_insensitive,
                               'Match case-insensitively. Defaults to false, e.g. true.'
            p.optional_string :output_mode,
                              "One of #{OUTPUT_MODES.join(', ')}. Defaults to " \
                              "#{DEFAULT_OUTPUT_MODE}, e.g. \"files_with_matches\"."
          },
          execute: lambda { |pattern:, path: nil, glob: nil,
                            case_insensitive: false, output_mode: DEFAULT_OUTPUT_MODE|
            Grep.search(workspace: workspace, pattern: pattern, path: path,
                        glob: glob, case_insensitive: case_insensitive,
                        output_mode: output_mode)
          }
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
      # @return [String]
      def self.search(workspace:, pattern:, path:, glob:, case_insensitive:, output_mode:)
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

        if (refusal = oversized_root_refusal(resolved_root))
          return refusal
        end

        argv = build_argv(pattern: pattern, glob: glob,
                          case_insensitive: case_insensitive,
                          output_mode: output_mode, path: search_target)

        result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.project_root.to_s).wait
        exit_code = result.status.exitstatus

        case exit_code
        when 0
          format_output(result.output, output_mode: output_mode,
                        pattern: pattern, path: path)
        when 1
          no_match_message(pattern: pattern, path: path)
        else
          "Error: ripgrep: #{truncate_error(result.output, exit_code)}"
        end
      rescue Filesystem::Error => e
        "Error: #{e.message}"
      end

      # Refuse a search rooted at +/+ or the user's whole home dir: either walks
      # an enormous tree and — under an +AllowAll+ workspace — floods rg with
      # unreadable-path diagnostics the model pays context for. Refused
      # regardless of any +glob+: rg traverses the tree *before* the glob narrows
      # which files it searches, so a filter doesn't bound traversal. Lesser
      # roots (a project dir, +~/work+) stay allowed.
      #
      # @param resolved [Pathname] the absolute search root
      # @return [String, nil] the +"Error: ..."+ refusal, or +nil+ to proceed
      def self.oversized_root_refusal(resolved)
        roots = [Pathname.new('/'), Pathname.new(Dir.home)].map { |r| normalize_root(r) }
        return nil unless roots.include?(normalize_root(resolved))

        "Error: refusing to search from #{resolved} — searching the entire " \
          'filesystem root or your whole home directory is too broad. Narrow ' \
          '`path` to a specific subdirectory.'
      end
      private_class_method :oversized_root_refusal

      # @param path [String, Pathname]
      # @return [String] symlink-resolved absolute path; falls back to a
      #   lexical cleanup when the path doesn't exist on disk.
      def self.normalize_root(path)
        Pathname.new(path).realpath.to_s
      rescue SystemCallError
        Pathname.new(path).expand_path.cleanpath.to_s
      end
      private_class_method :normalize_root

      # Build the +rg+ argv. Path is always passed (defaults to +.+) — see the
      # class header.
      #
      # @return [Array<String>]
      def self.build_argv(pattern:, glob:, case_insensitive:, output_mode:, path:)
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
      # @return [String]
      def self.format_output(raw, output_mode:, pattern:, path:)
        cleaned = strip_dot_slash(raw)
        content, truncation_marker = head_truncate(cleaned)
        stripped = content.chomp

        return no_match_message(pattern: pattern, path: path) if stripped.empty?

        footer = build_footer(stripped, output_mode)
        [stripped, '', footer + truncation_marker].join("\n")
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

      # One-line footer summarizing the result; format depends on +output_mode+.
      #
      # @return [String]
      def self.build_footer(content, output_mode)
        lines = content.split("\n").reject(&:empty?)
        case output_mode
        when 'content'
          files = lines.map { |l| l.split(':', 2).first }.uniq
          "Found #{pluralize(lines.size, 'match', 'matches')} in " \
            "#{pluralize(files.size, 'file', 'files')}."
        when 'files_with_matches'
          "Found #{pluralize(lines.size, 'file', 'files')}."
        when 'count'
          total = lines.sum { |l| Integer(l.split(':').last) }
          "Found #{pluralize(total, 'match', 'matches')} in " \
            "#{pluralize(lines.size, 'file', 'files')}."
        end
      end
      private_class_method :build_footer

      # @return [String] +"1 match"+ / +"2 matches"+
      def self.pluralize(n, sing, plural)
        "#{n} #{n == 1 ? sing : plural}"
      end
      private_class_method :pluralize

      # @return [String]
      def self.no_match_message(pattern:, path:)
        base = "No matches for pattern '#{pattern}'"
        base += " in #{path}" if path
        "#{base}."
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
