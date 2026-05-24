# frozen_string_literal: true

require 'pathname'
require 'set'

module Pikuri
  module Code
    class Bash
      # Filesystem-sandbox seam for the bash tool. {Bash} runs +bash -c
      # <command>+ unmediated by default ({NONE}, identity wrap); host
      # binaries that want isolation pass {Bubblewrap.new(workspace:)+}
      # to get a +bwrap+-wrapped subprocess whose filesystem view is
      # constrained to the {Workspace}'s readable/writable roots plus a
      # curated OS-runtime baseline.
      #
      # == Why a seam, not a flag on Bash
      #
      # The pure layered design: Workspace is "what the LLM observes via
      # Read/Write/Edit/Grep/Glob"; Sandbox is "what the executed
      # subprocess sees in its filesystem view." They overlap on the
      # project + toolchain dirs, but diverge on the OS-runtime baseline
      # ({Bubblewrap::ETC_BASELINE} — TLS certs, DNS resolver config, tz
      # data, hosts file). The LLM has no need to {Read} +/etc/resolv.conf+;
      # the +curl+ subprocess does. Keeping the two concerns in distinct
      # objects lets Workspace stay focused on the LLM-side allowlist while
      # Bubblewrap owns the runtime-side allowlist + the +bwrap+-specific
      # argv composition.
      #
      # == The contract
      #
      # A sandbox responds to +#wrap(argv) → Array<String>+, transforming
      # the +timeout ... bash -c <cmd>+ argv that {Bash.run} would have
      # spawned into the actual argv to spawn. {NONE} returns +argv+
      # unchanged; {Bubblewrap} prepends +bwrap+ + its bind/isolation
      # flags.
      module Sandbox
        # Identity sandbox — passthrough. Default for {Bash.new}, used
        # when the host opts out via +--no-sandbox+ / +--yolo+, and the
        # natural baseline for tests and any non-coding binary that
        # invokes {Bash} directly.
        module NONE
          # @param argv [Array<String>]
          # @return [Array<String>] argv unchanged
          def self.wrap(argv)
            argv
          end
        end

        # Bubblewrap (+bwrap+(1)) sandbox: composes a +bwrap+ argv from
        # the supplied {Workspace} plus a curated OS-runtime baseline,
        # so the bash subprocess sees only the project + toolchain +
        # ephemeral temp + the few +/etc+ files needed for TLS, DNS,
        # timezone, and name resolution.
        #
        # == What's bound, and why
        #
        # * {SYSTEM_ROOTS} — +/lib+, +/lib64+, +/bin+, +/sbin+
        #   (often symlinks to +/usr+ on modern distros). Not in
        #   {Workspace#readable} (the LLM has no business grepping
        #   +/sbin/+), but the subprocess needs them executable for the
        #   dynamic linker + standard utilities. +/usr+ and +/opt+ are
        #   *not* listed here because they already come in via
        #   {Workspace#readable} (added by
        #   +Pikuri::Code::ToolchainPaths.readable+).
        # * {ETC_BASELINE} — +/etc/ssl+, +/etc/ca-certificates+,
        #   +/etc/pki+, +/etc/resolv.conf+, +/etc/nsswitch.conf+,
        #   +/etc/localtime+, +/etc/hosts+. Allowlist (not the whole
        #   +/etc+!) of the files +bash+ subprocesses commonly need —
        #   TLS handshake, DNS, timezone, hostname resolution. Nothing
        #   sensitive (no +shadow+, no +ssh_config+, no NetworkManager
        #   state).
        # * Synthetic +/tmp+ (tmpfs), +/proc+ (synthetic, sees only the
        #   sandbox's own processes due to +--unshare-pid+), +/dev+
        #   (synthetic, +null+/+zero+/+random+/+tty+ only). The host's
        #   +/tmp+ is *not* exposed; the workspace's own +temp+ dir is
        #   bind-mounted explicitly via +workspace.writable+ so its
        #   contents persist across bash calls + survive sandbox
        #   teardown.
        # * +workspace.readable+ → +--ro-bind+ each path at the same
        #   path in the sandbox.
        # * +workspace.writable+ → +--bind+ (read+write) each path.
        #   Mounted *after* the synthetic +/tmp+ so the workspace temp
        #   dir (typically +/tmp/pikuri-temp-XXX+) overlays the tmpfs
        #   correctly.
        #
        # == Isolation
        #
        # +--unshare-all --share-net+: PID, mount, IPC, user, and UTS
        # namespaces are unshared (the sandbox can't see host
        # processes, can't mount on the host, can't ptrace, …); the
        # network namespace is *kept* shared because the agent's bash
        # routinely needs +git pull+, +mvn+, +gem install+, +curl+, etc.
        # +--die-with-parent --new-session+: subprocess dies with
        # pikuri, in its own session group (no terminal control bleed).
        #
        # == Failures that surface at construction
        #
        # The constructor probes the workspace shape, then +bwrap+ with a
        # no-op invocation. Three cases raise loudly:
        #
        # * Workspace lists +/+ as writable (typically
        #   {Workspace::Filesystem::AllowAll}) — Bubblewrap exists for
        #   filesystem containment, which is structurally meaningless
        #   when the whole filesystem is the workspace. The host should
        #   pass {NONE} instead.
        # * +bwrap+ not on +PATH+ → +Errno::ENOENT+ wrapped as +RuntimeError+.
        # * Kernel lacks user-namespace support (some hardened distros)
        #   → +bwrap+ exits non-zero, surfaced as +RuntimeError+.
        #
        # Either way the binary should fail at boot, not on the first
        # +bash+ tool call — matches the "errors are loud" convention.
        # The host opts out of sandboxing via +--no-sandbox+ /
        # +--yolo+.
        class Bubblewrap
          BWRAP_BINARY = 'bwrap'

          # System-root dirs the subprocess needs that aren't in
          # {Workspace#readable}. Each is +--ro-bind+'d if it exists on
          # the host; missing entries are skipped silently (older or
          # unusual layouts).
          SYSTEM_ROOTS = %w[/lib /lib64 /bin /sbin].freeze

          # +/etc+ file allowlist for the subprocess. Each is +--ro-bind+'d
          # if it exists on the host. Nothing else from +/etc+ is
          # exposed — no +shadow+, no +passwd+ beyond what +/etc/hosts+
          # touches, no SSH config, no NetworkManager state.
          ETC_BASELINE = %w[
            /etc/ssl
            /etc/ca-certificates
            /etc/pki
            /etc/resolv.conf
            /etc/nsswitch.conf
            /etc/localtime
            /etc/hosts
          ].freeze

          # @param workspace [Pikuri::Workspace::Filesystem] the source of
          #   per-host readable/writable roots and the +chdir+ target
          #   for the subprocess.
          # @raise [RuntimeError] if the workspace lists +/+ as writable
          #   (Bubblewrap is for filesystem containment, which is moot
          #   when the entire filesystem is the workspace — typically
          #   {Workspace::Filesystem::AllowAll}; the host should pass
          #   {NONE} instead).
          # @raise [RuntimeError] if +bwrap+ isn't on +PATH+ or fails
          #   its probe (typically: kernel without user-namespace
          #   support).
          def initialize(workspace:)
            @workspace = workspace
            reject_unbounded_workspace!
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+
          #   argv that {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + isolation flags +
          #   bind-mounts + +argv+, ready to hand to
          #   {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [BWRAP_BINARY, *bwrap_args, *argv]
          end

          private

          # Bubblewrap's whole job is filesystem containment; that's
          # structurally meaningless when the workspace's writable set
          # includes the root directory (typically because the host
          # wired in {Workspace::Filesystem::AllowAll}). Refuse to
          # construct rather than +--bind / /+ over our own
          # tmpfs/proc/dev layout.
          def reject_unbounded_workspace!
            return unless @workspace.writable.include?(Pathname.new('/').realpath)

            raise "Code::Bash::Sandbox::Bubblewrap: workspace lists '/' as " \
                  'writable (likely Workspace::Filesystem::AllowAll). ' \
                  'Bubblewrap exists to contain the subprocess to a subset ' \
                  'of the filesystem, which is moot when the whole filesystem ' \
                  'is the workspace. Pass Sandbox::NONE instead.'
          end

          def check_bwrap!
            result = Pikuri::Subprocess.spawn(
              BWRAP_BINARY,
              '--unshare-all', '--share-net',
              '--ro-bind', '/', '/',
              '--die-with-parent',
              '/bin/true',
              chdir: '/'
            ).wait
            return if result.status.success?

            raise "Code::Bash::Sandbox::Bubblewrap: bwrap probe failed " \
                  "(exit #{result.status.exitstatus}). Is user-namespace " \
                  'support enabled in the kernel? Pass --no-sandbox to skip.'
          rescue Errno::ENOENT
            raise "Code::Bash::Sandbox::Bubblewrap: 'bwrap' not found on PATH. " \
                  'Install bubblewrap (apt-get install bubblewrap / dnf install ' \
                  'bubblewrap / pacman -S bubblewrap) or pass --no-sandbox.'
          end

          def bwrap_args
            args = []
            mounted = Set.new

            # 1. OS-runtime baseline — NOT in workspace by design.
            (SYSTEM_ROOTS + ETC_BASELINE).each do |p|
              next unless File.exist?(p)
              next if mounted.include?(p)
              args.concat(['--ro-bind', p, p])
              mounted << p
            end

            # 2. Synthetic mounts. Placed BEFORE the workspace binds so
            #    that workspace.temp (typically /tmp/pikuri-temp-XXX)
            #    overlays the tmpfs rather than being shadowed by it.
            args.concat(['--tmpfs', '/tmp', '--proc', '/proc', '--dev', '/dev'])

            # 3. Workspace-derived mounts. Writable wins on overlap
            #    (writable ⊆ readable in the Workspace constructor;
            #    iterating writable first + the `mounted` guard
            #    ensures each path is mounted once).
            @workspace.writable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(['--bind', s, s])
              mounted << s
            end
            @workspace.readable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(['--ro-bind', s, s])
              mounted << s
            end

            # 4. Isolation + chdir.
            args.concat([
              '--unshare-all', '--share-net',
              '--die-with-parent', '--new-session',
              '--chdir', @workspace.project_root.to_s
            ])
            args
          end
        end
      end
    end
  end
end
