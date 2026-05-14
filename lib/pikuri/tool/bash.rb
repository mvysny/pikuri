# frozen_string_literal: true

require 'rainbow'

module Pikuri
  class Tool
    # The +bash+ tool — run an arbitrary shell command in the workspace.
    # Instantiating +Tool::Bash.new(workspace: ws, confirmer: c)+ produces
    # a tool whose {Tool#to_ruby_llm_tool} wiring is identical to any
    # bundled tool's. Same shape as {Tool::Write} (workspace + confirmer
    # captured by the +execute+ closure at construction).
    #
    # == Confirmation
    #
    # Every command requires confirmation. Bash composes the full prompt
    # (header line, +$ <command>+ echo, +(y/n)?+ cue) and hands it to the
    # confirmer; the confirmer renders + parses the answer. The command
    # echo passes through {.visible} which escapes control bytes so the
    # model can't smuggle a +\r\033[2K rm -rf ~/+ behind the displayed
    # text. Execution uses the raw command; only the *display* is
    # sanitized.
    #
    # == Subprocess wiring
    #
    # The command runs through {Pikuri::Subprocess.spawn} with argv:
    #
    #   timeout --signal=TERM --kill-after=5s <timeout>s bash -c <command>
    #
    # +bash -c+ (no +-l+) — no profile/rc sourcing, no inherited login
    # environment beyond what pikuri itself runs in. +timeout(1)+ from
    # GNU coreutils handles the SIGTERM-then-SIGKILL race; we never use
    # Ruby's +Timeout.timeout+ (can't reliably kill subprocesses). The
    # +--kill-after=5s+ gives the command 5 seconds to handle SIGTERM
    # cleanly before SIGKILL is sent.
    #
    # == Timeout detection
    #
    # GNU coreutils' +timeout+ exits +124+ after a successful SIGTERM,
    # +137+ after escalating to SIGKILL. We treat both as "command timed
    # out". A third code, +125+, is also accepted: uutils-coreutils 0.2.2
    # (the Rust reimplementation shipped on some distros) sends the
    # SIGTERM correctly but then mis-reports +125+ ("timeout itself
    # failed") instead of +124+ whenever +--kill-after+ is in play. False-
    # positive risk on real GNU coreutils is low — our argv is fixed and
    # well-formed, so a +125+ there would indicate a misconfigured PATH
    # rather than a routine timeout.
    #
    # Caveat: +137+ is ambiguous — a command killed by the OOM-killer
    # also exits +137+. v1 accepts the mis-classification; the
    # observation tells the user "sent SIGTERM, then SIGKILL" regardless.
    #
    # == Output handling
    #
    # Combined stdout+stderr (popen2e). Head+tail truncation at
    # {OUTPUT_HEAD} + {OUTPUT_TAIL} bytes with a marker reporting both
    # bytes-omitted and the original total — the model needs the scale
    # to decide whether to re-run with +head+/+tail+/+grep+.
    #
    # == Backgrounded subprocesses
    #
    # Plain +cmd &+ does NOT detach — the backgrounded child inherits our
    # combined-output pipe by default, so {Pikuri::Subprocess#wait} blocks
    # on +io.read+ until the backgrounded process exits. The model must
    # redirect fds away from our pipe to genuinely background:
    # +cmd >/dev/null 2>&1 &+. Such commands stay in our pgroup and get
    # SIGTERM on pikuri exit via {Pikuri::Subprocess.cleanup!}; +nohup+ /
    # +setsid+ plus redirection opt out of cleanup.
    #
    # == Refusals
    #
    # All returned as +"Error: ..."+ observations:
    #
    # * Empty / whitespace-only +command+ → fast reject before confirming.
    # * +timeout+ outside +[1, MAX_TIMEOUT]+ → bounds error.
    # * User declined the confirmation → +"Error: user declined ..."+.
    # * +timeout+ exit (+124+ / +137+) → timeout error with partial output.
    class Bash < Tool
      # Pikuri-convention per-module logger; the +Bash+ progname tags the
      # construction-time warning below so it's clear in the shared
      # +Pikuri.log_io+ stream which tool issued it.
      # @return [Logger]
      LOGGER = Pikuri.logger_for('Bash')

      # @return [Integer] default value of the +timeout+ parameter (seconds).
      DEFAULT_TIMEOUT = 120

      # @return [Integer] hard upper bound on the +timeout+ parameter.
      MAX_TIMEOUT = 600

      # @return [String] grace period between SIGTERM and SIGKILL,
      #   passed to +timeout --kill-after=...+.
      KILL_AFTER = '5s'

      # @return [Integer] bytes preserved from the start of the output
      #   when the combined-output stream exceeds {OUTPUT_HEAD} + {OUTPUT_TAIL}.
      OUTPUT_HEAD = 15 * 1024

      # @return [Integer] bytes preserved from the end of the output.
      OUTPUT_TAIL = 15 * 1024

      # Description shown to the LLM. opencode-shape: summary + +Usage:+
      # bullets. Per-parameter constraints (default, max) live in the
      # parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Run a bash command in the workspace.

        Usage:
        - Use for tasks the dedicated tools can't do: git, tests, package managers, multi-step shell pipelines.
        - Prefer `read` / `write` / `edit` / `grep` / `glob` over `cat` / `sed` / `rg` / `find` — they're workspace-resolved.
        - Each call starts in the workspace root; there is no pwd persistence between calls. Use `cd /path && cmd` in one command.
        - stdin is closed; interactive commands hang until timeout. Use non-interactive flags (`apt -y`, `git commit -m`).
        - Plain `cmd &` does NOT detach — the backgrounded process inherits our output pipe and blocks. To genuinely background, redirect fds: `cmd >/dev/null 2>&1 &`. Add `nohup` or `setsid` to survive pikuri exit.
        - Combined stdout+stderr is returned. Suppress either via `2>/dev/null` etc.
        - Large outputs are head+tail-truncated. Pipe through `head`/`tail`/`grep`/`wc` to control volume.
        - Non-zero exit status is a normal observation, not an error.
        - The user must confirm every command before it runs; on rejection an Error is returned.
      DESC

      # @param workspace [Tool::Workspace] captured for +chdir+; commands
      #   run in +workspace.cwd+. Bash does NOT path-resolve individual
      #   arguments — the +command+ string is opaque shell syntax.
      # @param confirmer [Tool::Confirmer] consulted before every command.
      # @raise [RuntimeError] if +bash+ or +timeout+ aren't on +PATH+;
      #   fail-loud at construction rather than the first tool call.
      # @return [Bash]
      def initialize(workspace:, confirmer:)
        Bash.send(:check_binaries!)
        # Prototype-stage capability advisory. The Bash tool runs commands
        # with pikuri's own UID and inherits its filesystem view — there is
        # no chroot, container, seccomp, or syscall filter today. Anything
        # readable to the user is readable to the LLM via +cat ~/.ssh/id_*+
        # / +aws configure list+ / etc. The per-command +Confirmer+ is the
        # only line of defense; logged loud so anyone wiring this tool up
        # sees the warning at startup, not on the day of an incident.
        LOGGER.warn(
          'Tool::Bash is a prototype: commands run unsandboxed under your UID and can read ' \
          'sensitive files (~/.ssh, AWS credentials, browser sessions, ...). Use with care; ' \
          'a future release will gate this behind a sandbox.'
        )
        super(
          name: 'bash',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :command,
                              'Bash command to execute. Multi-line is fine. ' \
                              'Example: "ls -la lib/".'
            p.optional_string :description,
                              'Short 3-7 word label shown to the user alongside ' \
                              'the command, e.g. "Run unit tests".'
            p.optional_integer :timeout,
                               "Timeout in seconds. Defaults to #{DEFAULT_TIMEOUT}, " \
                               "max #{MAX_TIMEOUT}, e.g. 300."
          },
          execute: ->(command:, description: nil, timeout: DEFAULT_TIMEOUT) {
            Bash.run(workspace: workspace, confirmer: confirmer,
                     command: command, description: description, timeout: timeout)
          }
        )
      end

      # Bounds-check, confirm, spawn, and render the observation. Returns
      # either +"$ ...\n<out>\n\nexit status: N"+ on a normal exit, or
      # +"Error: ..."+ on rejection / timeout / bad inputs.
      #
      # @param workspace [Tool::Workspace]
      # @param confirmer [Tool::Confirmer]
      # @param command [String] raw command as supplied by the LLM
      # @param description [String, nil] optional short label for the user
      # @param timeout [Integer] seconds before SIGTERM is sent
      # @return [String]
      def self.run(workspace:, confirmer:, command:, description:, timeout:)
        return 'Error: empty bash command.' if command.strip.empty?
        return "Error: timeout must be >= 1, got #{timeout}" if timeout < 1
        return "Error: timeout must be <= #{MAX_TIMEOUT}, got #{timeout}" if timeout > MAX_TIMEOUT

        prompt = compose_prompt(command: command, description: description, timeout: timeout)
        return 'Error: user declined the bash command.' unless confirmer.confirm?(prompt: prompt)

        result = Pikuri::Subprocess.spawn(
          'timeout', '--signal=TERM', "--kill-after=#{KILL_AFTER}", "#{timeout}s",
          'bash', '-c', command,
          chdir: workspace.cwd.to_s
        ).wait

        output = truncate(result.output)
        exit_code = result.status.exitstatus

        # 124 (GNU SIGTERM), 137 (GNU SIGKILL), 125 (uutils-coreutils
        # 0.2.2 bug when --kill-after is set). See class header.
        if exit_code == 124 || exit_code == 137 || exit_code == 125
          "Error: command timed out after #{timeout}s (sent SIGTERM, then SIGKILL).\n\n" \
            "$ #{visible(command)}\n#{output}"
        else
          "$ #{visible(command)}\n#{output}\n\nexit status: #{exit_code}"
        end
      end

      # Compose the multi-line confirmation prompt. Three lines:
      #
      # 1. +OK to run bash[: <desc>][ \[Timeout: Ns\]]+ (bold)
      # 2. +$ <visible(command)>+ (dim)
      # 3. +(y/n)?+
      #
      # Colon after +bash+ is dropped when there's no description, since a
      # trailing colon with nothing after it reads as broken. Timeout
      # suffix appears only when non-default.
      #
      # @return [String]
      def self.compose_prompt(command:, description:, timeout:)
        header = +'OK to run bash'
        desc_clean = description&.strip
        header << ": #{desc_clean}" if desc_clean && !desc_clean.empty?
        header << " [Timeout: #{timeout}s]" if timeout != DEFAULT_TIMEOUT

        [
          Rainbow(header).bold,
          Rainbow("$ #{visible(command)}").dimgray,
          '(y/n)?'
        ].join("\n")
      end
      private_class_method :compose_prompt

      # Escape control bytes for safe display while preserving +\n+
      # (multi-line shell commands are normal). Catches +\r+, +\x1b+
      # (ESC, the ANSI introducer), +\b+, NUL, DEL, etc. — without this,
      # a model could craft +command: "\rrm -rf ~/"+ that visually
      # overwrites the echo line after the user has already read it.
      #
      # @param command [String]
      # @return [String]
      def self.visible(command)
        command.gsub(/[\x00-\x09\x0b-\x1f\x7f]/) { |c| format('\\x%02x', c.ord) }
      end
      private_class_method :visible

      # Head+tail-truncate +output+ to {OUTPUT_HEAD} + {OUTPUT_TAIL}
      # bytes with a marker reporting both bytes-omitted and total.
      # No-op when the output already fits.
      #
      # @param output [String]
      # @return [String]
      def self.truncate(output)
        total = output.bytesize
        return output if total <= OUTPUT_HEAD + OUTPUT_TAIL

        omitted = total - (OUTPUT_HEAD + OUTPUT_TAIL)
        head = output.byteslice(0, OUTPUT_HEAD)
        tail = output.byteslice(total - OUTPUT_TAIL, OUTPUT_TAIL)
        "#{head}\n... [#{omitted} bytes omitted; total was #{total} bytes] ...\n#{tail}"
      end
      private_class_method :truncate

      # Verify +bash+ and GNU +timeout+ are reachable on +PATH+. Routed
      # through {Pikuri::Subprocess.spawn} to honor the subprocess seam
      # (no direct +system+ / +backtick+ in +lib/+). +bash+ missing
      # surfaces as +Errno::ENOENT+ from +popen2e+; +timeout+ missing
      # surfaces as a non-zero exit from +command -v+.
      #
      # @return [void]
      # @raise [RuntimeError] if either binary is missing
      def self.check_binaries!
        result = Pikuri::Subprocess.spawn('bash', '-c', 'command -v timeout >/dev/null', chdir: '/').wait
        raise "Tool::Bash requires GNU coreutils 'timeout' on PATH" unless result.status.success?
      rescue Errno::ENOENT
        raise "Tool::Bash requires 'bash' on PATH"
      end
      private_class_method :check_binaries!
    end
  end
end
