# frozen_string_literal: true

module Pikuri
  module Code
    # The +bash+ tool — run an arbitrary shell command in the workspace.
    # Instantiating +Code::Bash.new(workspace: ws, confirmer: c)+ produces
    # a tool whose {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to
    # any bundled tool's. Same shape as {Pikuri::Workspace::Write}
    # (workspace + confirmer captured by the +execute+ closure at
    # construction).
    #
    # == Confirmation
    #
    # Every command requires confirmation. Bash composes a semantic
    # {Pikuri::Workspace::Confirmer::Request} — question (header line)
    # plus detail (+$ <command>+ echo) — and hands it to the confirmer,
    # which owns ALL presentation: color, the answer cue, answer
    # parsing, and medium-appropriate escaping of the raw bytes (a
    # terminal neutralizes control bytes, a web client HTML-escapes).
    # The request deliberately carries the command verbatim so each
    # renderer can escape for its own medium. The *observation* echo
    # (+$ ...+ in the tool result) stays on this side of the seam and
    # passes through {.visible}, so the model can't smuggle a
    # +\r\033[2K rm -rf ~/+ behind the displayed text there either.
    # Execution uses the raw command; only displays are sanitized.
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
    # The subprocess environment is "de-bundlerized" first — pikuri is
    # usually launched under Bundler, which would otherwise leak its own
    # +BUNDLE_GEMFILE+ / +RUBYOPT+ / ... into the command so a +bundle
    # exec+ run against another project picks up *pikuri's* Gemfile. See
    # {.subprocess_env} / {.bundler_clean_delta}.
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
    class Bash < Pikuri::Tool
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
        - Working directory is ALWAYS the project root: `pwd` returns it, and relative paths in commands resolve from there. To operate in a subfolder, chain `cd` in the same command (`cd src/foo && make test`) — `cd` does NOT persist across calls; each call starts fresh at the project root.
        - stdin is closed; interactive commands hang until timeout. Use non-interactive flags (`apt -y`, `git commit -m`).
        - Plain `cmd &` does NOT detach — the backgrounded process inherits our output pipe and blocks. To genuinely background, redirect fds: `cmd >/dev/null 2>&1 &`. Add `nohup` or `setsid` to survive pikuri exit.
        - Combined stdout+stderr is returned. Suppress either via `2>/dev/null` etc.
        - Large outputs are head+tail-truncated. Pipe through `head`/`tail`/`grep`/`wc` to control volume.
        - Non-zero exit status is a normal observation, not an error.
        - The user must confirm every command before it runs; on rejection an Error is returned.
      DESC

      # @param workspace [Pikuri::Workspace::Filesystem] captured for
      #   +chdir+; commands run in +workspace.project_root+, always.
      #   Even when the surrounding Ruby process has already chdir'd
      #   to the project root (e.g. +bin/pikuri-code+ does this at
      #   startup), Bash still passes the explicit +chdir:+ — so a
      #   sub-agent, future host, or anyone embedding Bash directly
      #   gets the same predictable cwd. Bash does NOT path-resolve
      #   individual arguments — the +command+ string is opaque shell
      #   syntax.
      # @param confirmer [Pikuri::Workspace::Confirmer] consulted before
      #   every command.
      # @param sandbox [Code::Bash::Sandbox] filesystem-sandbox seam
      #   (default {Sandbox::NONE} — identity passthrough). Pass
      #   {Sandbox::Bubblewrap.new(workspace: workspace)+} for an
      #   isolated subprocess whose filesystem view is the workspace's
      #   readable/writable roots plus the OS-runtime baseline. See
      #   {Sandbox} for the rationale.
      # @raise [RuntimeError] if +bash+ or +timeout+ aren't on +PATH+;
      #   fail-loud at construction rather than the first tool call.
      # @return [Bash]
      def initialize(workspace:, confirmer:, sandbox: Sandbox::NONE)
        Bash.send(:check_binaries!)
        # Capability advisory when no sandbox is in play. Without a
        # sandbox, +bash+ runs with pikuri's own UID + filesystem view —
        # anything readable to the user is readable to the LLM via +cat
        # ~/.ssh/id_*+ / +aws configure list+ / etc. The per-command
        # +Confirmer+ is the only line of defense in that mode. The
        # bundled {Sandbox::Bubblewrap} addresses this concern with a
        # filesystem-restricted subprocess; warn only when the host has
        # opted out (or never opted in).
        if sandbox.equal?(Sandbox::NONE)
          LOGGER.warn(
            'Code::Bash is unsandboxed: commands run under your UID and can read ' \
            'sensitive files (~/.ssh, AWS credentials, browser sessions, ...). ' \
            'Use Sandbox::Bubblewrap or an outer container for isolation.'
          )
        end
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
            Bash.run(workspace: workspace, confirmer: confirmer, sandbox: sandbox,
                     command: command, description: description, timeout: timeout)
          }
        )
      end

      # Bounds-check, confirm, spawn, and render the observation. Returns
      # either +"$ ...\n<out>\n\nexit status: N"+ on a normal exit, or
      # +"Error: ..."+ on rejection / timeout / bad inputs.
      #
      # @param workspace [Pikuri::Workspace::Filesystem]
      # @param confirmer [Pikuri::Workspace::Confirmer]
      # @param sandbox [Code::Bash::Sandbox] wraps the spawned argv;
      #   {Sandbox::NONE} for identity passthrough,
      #   {Sandbox::Bubblewrap} for filesystem isolation.
      # @param command [String] raw command as supplied by the LLM
      # @param description [String, nil] optional short label for the user
      # @param timeout [Integer] seconds before SIGTERM is sent
      # @return [String]
      def self.run(workspace:, confirmer:, command:, description:, timeout:, sandbox: Sandbox::NONE)
        return 'Error: empty bash command.' if command.strip.empty?
        return "Error: timeout must be >= 1, got #{timeout}" if timeout < 1
        return "Error: timeout must be <= #{MAX_TIMEOUT}, got #{timeout}" if timeout > MAX_TIMEOUT

        request = compose_request(command: command, description: description, timeout: timeout)
        return 'Error: user declined the bash command.' unless confirmer.confirm?(request: request)

        argv = sandbox.wrap([
          'timeout', '--signal=TERM', "--kill-after=#{KILL_AFTER}", "#{timeout}s",
          'bash', '-c', command
        ])
        result = Pikuri::Subprocess.spawn(*argv, chdir: workspace.project_root.to_s,
                                                 env: subprocess_env(workspace)).wait

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

      # Compose the semantic confirmation request:
      #
      # * question — +OK to run bash[: <desc>][ \[Timeout: Ns\]]+
      # * detail — +$ <command>+, the command VERBATIM (the confirmer
      #   escapes for its medium; see the class header's Confirmation
      #   section)
      #
      # Colon after +bash+ is dropped when there's no description, since a
      # trailing colon with nothing after it reads as broken. Timeout
      # suffix appears only when non-default.
      #
      # @return [Pikuri::Workspace::Confirmer::Request]
      def self.compose_request(command:, description:, timeout:)
        question = +'OK to run bash'
        desc_clean = description&.strip
        question << ": #{desc_clean}" if desc_clean && !desc_clean.empty?
        question << " [Timeout: #{timeout}s]" if timeout != DEFAULT_TIMEOUT

        Pikuri::Workspace::Confirmer::Request.new(question: question, detail: "$ #{command}")
      end
      private_class_method :compose_request

      # Environment for the bash subprocess: the workspace's git-identity
      # vars ({Pikuri::Workspace::Filesystem#env}) layered over a
      # "de-bundlerized" base.
      #
      # pikuri is typically launched under Bundler — the +bin/pikuri-code+
      # demo and every downstream host (e.g. pikuri-tui) pin
      # +BUNDLE_GEMFILE+ to their *own* Gemfile and +require
      # 'bundler/setup'+ at boot. Doing so makes Bundler rewrite
      # +BUNDLE_GEMFILE+ / +RUBYOPT+ / +GEM_HOME+ / +GEM_PATH+ / +RUBYLIB+
      # / +PATH+ in the *process* environment (stashing the pre-bundler
      # values under +BUNDLER_ORIG_*+). Those vars are inherited by every
      # subprocess we spawn — so a +bundle exec rspec+ the agent runs in
      # *another* Ruby project would resolve against PIKURI's Gemfile and
      # die with a baffling "the Gemfile specifies ... is missing" error.
      #
      # The fix is to hand bash the environment as it was *before* bundler
      # touched it (see {.bundler_clean_delta}), with the workspace's git
      # identity on top.
      #
      # @param workspace [Pikuri::Workspace::Filesystem]
      # @return [Hash{String=>(String,nil)}] +env:+ delta for
      #   {Pikuri::Subprocess.spawn} (a +nil+ value unsets the key in the
      #   child).
      def self.subprocess_env(workspace)
        bundler_clean_delta.merge(workspace.env)
      end
      private_class_method :subprocess_env

      # The delta that, merged onto the current (bundler-polluted) +ENV+
      # via {Pikuri::Subprocess.spawn}'s +env:+, reconstructs
      # +Bundler.unbundled_env+ — the environment as it was before
      # +bundler/setup+ ran.
      #
      # +Bundler.unbundled_env+ restores each +BUNDLER_ORIG_*+ backup, so
      # a host-level +GEM_HOME+/+GEM_PATH+ from a +sudo apt install ruby+
      # install (pointing at +~/.gem+) passes straight through and the
      # subprocess still finds the user's gems — it is *not* a blanket
      # +GEM_*+ wipe — while the bundler-only vars (+BUNDLE_*+, the
      # +-rbundler/setup+ +RUBYOPT+) are dropped. We diff against the live
      # +ENV+ rather than passing the full hash because +spawn+'s +env:+
      # is additive: changed/added keys carry their clean value, keys
      # bundler injected that aren't in the clean env map to +nil+
      # (+Open3.popen2e+ unsets a +nil+-valued key in the child).
      #
      # When pikuri runs *without* Bundler (gem-installed, or a host that
      # never required +bundler/setup+) this is empty and the child
      # inherits the environment unchanged.
      #
      # @return [Hash{String=>(String,nil)}]
      def self.bundler_clean_delta
        return {} unless defined?(Bundler) && Bundler.respond_to?(:unbundled_env)

        env_delta(current: ENV.to_h, clean: Bundler.unbundled_env)
      end
      private_class_method :bundler_clean_delta

      # Pure diff between two environment hashes: the additive delta that,
      # applied to +current+ via {Pikuri::Subprocess.spawn}'s +env:+,
      # yields +clean+. A key whose value differs (or is new in +clean+)
      # carries the +clean+ value; a key present in +current+ but absent
      # from +clean+ maps to +nil+ (which +Open3.popen2e+ unsets). Keys
      # equal in both are omitted, keeping the delta minimal.
      #
      # @param current [Hash{String=>String}]
      # @param clean [Hash{String=>String}]
      # @return [Hash{String=>(String,nil)}]
      def self.env_delta(current:, clean:)
        delta = {}
        clean.each { |k, v| delta[k] = v unless current[k] == v }
        current.each_key { |k| delta[k] = nil unless clean.key?(k) }
        delta
      end
      private_class_method :env_delta

      # Neutralize control bytes for safe display in the *observation*
      # echo (+"$ ..."+ in the tool result) — without this, a model could
      # craft +command: "\rrm -rf ~/"+ that visually overwrites the echo
      # line after the user has already read it. Delegates to the shared
      # {Pikuri::Sanitizer}, which preserves +\n+ (multi-line shell
      # commands are normal) and visualizes the rest; the confirmation
      # prompt routes the same command through the same primitive (see
      # +Confirmer::Terminal+). The echo is passive, so the
      # {Pikuri::Sanitizer::Warning}s are dropped here — they surface at
      # the confirmation prompt, before the user approves.
      #
      # @param command [String]
      # @return [String]
      def self.visible(command)
        Pikuri::Sanitizer.sanitize(command).text
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
        raise "Code::Bash requires GNU coreutils 'timeout' on PATH" unless result.status.success?
      rescue Errno::ENOENT
        raise "Code::Bash requires 'bash' on PATH"
      end
      private_class_method :check_binaries!
    end
  end
end
