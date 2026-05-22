# frozen_string_literal: true

module Pikuri
  class Tool
    # The +grep+ tool — content search across the workspace via
    # +ripgrep+. Instantiating +Tool::Grep.new(workspace: ws)+ produces a
    # tool whose {Tool#to_ruby_llm_tool} wiring is identical to any
    # bundled tool's. Same shape as {Tool::Read} (workspace captured by
    # the +execute+ closure, no confirmer — search is read-only).
    #
    # == ripgrep dependency
    #
    # Hard dependency: {.check_binaries!} runs in +initialize+ and raises
    # if +rg+ isn't on +PATH+. Mirrors {Tool::Bash}'s posture for
    # +bash+/+timeout+. We don't ship a Ruby fallback — replicating
    # rg's Rust-regex dialect, glob handling, and +.gitignore+ parsing
    # is a research-loop dead end. Failure message includes the install
    # hint.
    #
    # == Argv
    #
    #   rg --line-number --color=never --no-heading --with-filename \
    #      --hidden --max-columns=2000 --max-columns-preview \
    #      --sort=path \
    #      [-i] [--glob <g>] [--files-with-matches|--count-matches] \
    #      -- <pattern> <relative-path-or-dot>
    #
    # * +--no-heading+ + +--with-filename+ → flat +path:line:content+ rows
    #   regardless of whether the search target is a directory or a single
    #   file (rg defaults to suppressing the filename for single-file
    #   searches — we force it on for output consistency).
    # * +--hidden+ → search dotfiles (still respects +.gitignore+).
    # * +--max-columns=2000 --max-columns-preview+ → rg truncates lines
    #   longer than {MAX_LINE_LENGTH} bytes server-side and appends a
    #   preview marker, sparing us per-line truncation.
    # * +--sort=path+ → deterministic output (single-threaded; fine for
    #   typical repos under ~10k files). Makes specs assertable and gives
    #   the model a stable order to scan.
    # * Subprocess runs with +chdir: workspace.cwd+ and is *always* given
    #   an explicit path argument. {Pikuri::Subprocess.spawn} uses
    #   +popen2e+ which gives the child a piped (non-tty) stdin; rg's
    #   default heuristic on no-path-arg-with-piped-stdin is to search
    #   stdin (which we then close — yielding zero matches). Passing the
    #   path argument explicitly bypasses the heuristic. Output paths
    #   come back as +./...+ when the path is +.+; the leading +./+ is
    #   stripped post-rg so the model sees clean workspace-relative paths.
    #
    # == Output modes
    #
    # * +content+ (default) — +path:line:content+ rows.
    # * +files_with_matches+ — just file paths, one per line.
    # * +count+ — +path:count+ per file.
    #
    # Use +files_with_matches+ to scope a broad search cheaply before
    # paying tokens for +content+.
    #
    # == Truncation
    #
    # Total output is head-truncated to {MAX_BYTES} (head-only — grep
    # tails usually carry less signal than the first matches; opposite
    # bias from {Tool::Bash}). Cut at the last line boundary, with a
    # marker reporting omitted bytes and the original total so the model
    # knows how much it missed.
    #
    # == Exit codes
    #
    # * +0+ → matches; format with footer.
    # * +1+ → no matches; return +"No matches for pattern '...'"+.
    # * +2+ → rg error (bad regex, missing path); return +"Error: ripgrep: ..."+.
    #
    # == Refusals
    #
    # All returned as +"Error: ..."+ observations:
    #
    # * Empty +pattern+ → fast reject.
    # * Unknown +output_mode+ → enum error listing valid values.
    # * Path outside the workspace → caught from {Tool::Workspace::Error}.
    # * Nonexistent path → +"Error: path not found: <path>"+.
    class Grep < Tool
      # @return [Integer] hard byte cap on combined rg output. Same value
      #   as {Tool::Read::MAX_BYTES} so the two file-touching tools share
      #   a budget shape.
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES} for the
      #   truncation marker.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [Integer] per-line cap passed to rg's +--max-columns+.
      #   Long lines are truncated server-side with a preview marker.
      MAX_LINE_LENGTH = 2000

      # @return [Array<String>] valid +output_mode+ values.
      OUTPUT_MODES = %w[content files_with_matches count].freeze

      # @return [String] default +output_mode+.
      DEFAULT_OUTPUT_MODE = 'content'

      # Description shown to the LLM. opencode-shape (summary + +Usage:+
      # bullets). Per-parameter constraints live in parameter
      # descriptions.
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

      # @param workspace [Tool::Workspace] captured for path resolution
      #   and as +chdir+ for rg. All path arguments route through
      #   +workspace.resolve_for_read+.
      # @raise [RuntimeError] if +rg+ isn't on +PATH+; fail-loud at
      #   construction rather than the first tool call.
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

      # Validate inputs, resolve the path against the workspace, spawn
      # rg, and render the observation. Returns either the formatted
      # results, a "no matches" string, or +"Error: ..."+.
      #
      # @param workspace [Tool::Workspace]
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
        if path
          resolved = workspace.resolve_for_read(path)
          return "Error: path not found: #{path}" unless resolved.exist?

          rel = resolved.relative_path_from(workspace.cwd).to_s
          search_target = rel
        end

        argv = build_argv(pattern: pattern, glob: glob,
                          case_insensitive: case_insensitive,
                          output_mode: output_mode, path: search_target)

        result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.cwd.to_s).wait
        exit_code = result.status.exitstatus

        case exit_code
        when 0
          format_output(result.output, output_mode: output_mode,
                        pattern: pattern, path: path)
        when 1
          no_match_message(pattern: pattern, path: path)
        else
          stderr = result.output.strip
          stderr = "exited #{exit_code}" if stderr.empty?
          "Error: ripgrep: #{stderr}"
        end
      rescue Tool::Workspace::Error => e
        "Error: #{e.message}"
      end

      # Build the +rg+ argv. Path is always passed (defaults to +.+) —
      # see the class header for why.
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

      # Render rg output: strip the +./+ prefix rg adds when path is
      # +.+, head-truncate at {MAX_BYTES}, append a footer summarizing
      # the result count.
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

      # Strip leading +./+ from each line of rg output. rg emits this
      # prefix when invoked with +.+ as the search path; we want clean
      # workspace-relative paths regardless of whether the user passed a
      # path or we defaulted to +.+.
      #
      # @return [String]
      def self.strip_dot_slash(raw)
        raw.gsub(/^\.\//, '')
      end
      private_class_method :strip_dot_slash

      # Head-truncate +raw+ to {MAX_BYTES}, cutting at the last newline
      # boundary so the final row is never partial. Returns the truncated
      # content and a marker String (empty if no truncation).
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

      # Compose a one-line footer summarizing the result. Format depends
      # on +output_mode+; counts derive from rg's text output.
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

      # Verify +rg+ is reachable on +PATH+. Routed through
      # {Pikuri::Subprocess.spawn} to honor the subprocess seam.
      # rg missing surfaces as +Errno::ENOENT+; an installed rg returns
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
        "Tool::Grep requires 'rg' (ripgrep) on PATH; install via your " \
          "distro's package manager (e.g. 'apt install ripgrep')."
      end
      private_class_method :install_hint
    end
  end
end
