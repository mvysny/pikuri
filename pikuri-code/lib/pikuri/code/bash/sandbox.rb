# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'set'

module Pikuri
  module Code
    class Bash
      # Filesystem-sandbox seam for the bash tool. {Bash} runs +bash -c
      # <command>+ unmediated by default ({NONE}, identity wrap); host
      # binaries that want isolation pass {Bubblewrap.new(filesystem:)+}
      # to get a +bwrap+-wrapped subprocess whose filesystem view is
      # constrained to the {Workspace::Filesystem}'s readable/writable
      # roots plus a curated OS-runtime baseline.
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
        # * +/tmp+ — when {Workspace::Filesystem#temp} is set, bound
        #   to the workspace temp dir (so the LLM's reflexive +/tmp+
        #   writes land in a persistent dir that survives between bash
        #   calls). When no workspace temp is wired in, falls back to
        #   +--tmpfs /tmp+ (per-call ephemeral). The host's +/tmp+ is
        #   never exposed. +/proc+ (synthetic, sees only the sandbox's
        #   own processes due to +--unshare-pid+) and +/dev+ (synthetic,
        #   +null+/+zero+/+random+/+tty+ only) round out the synthetic
        #   mounts.
        # * +workspace.readable+ → mounted as a *read-write ephemeral
        #   overlay* each (when the kernel supports overlayfs in a user
        #   namespace; +--ro-bind+ fallback otherwise — see "Overlay
        #   support" below). The host's real dir is the lower
        #   (read-through), and a per-session upper + workdir under
        #   +<workspace.internal_temp>/overlay-<slug>/+ absorb writes.
        #   Result: the bash subprocess sees a fully read-write view of
        #   +/usr+, +~/.rbenv+, +~/.gradle/caches+, +~/.m2/repository+,
        #   …, so +gem install+ / +bundle install+ / +mvn+ / +gradle+ /
        #   +cargo+ / +pip+ all succeed; the host's real toolchain and
        #   caches are untouched; and on process exit the umbrella (and
        #   with it every upper layer) is removed by the workspace's
        #   {Pikuri::Finalizers} registration. Within one pikuri-code
        #   session writes survive across bash calls (warm cache after
        #   the first build — the upper is a persistent dir on disk,
        #   re-mounted each call, *not* a tmpfs that dies with the
        #   bwrap process); across sessions they don't (so a session
        #   that gets prompt-injected into poisoning the in-sandbox
        #   view of gradle's cache or a toolchain binary cannot
        #   propagate the damage to the host's normal +gradle+
        #   invocations or to a future pikuri-code session). Note: the
        #   cache entries in {Pikuri::Code::ToolchainPaths} are
        #   deliberately *narrow* subdirs (e.g. +~/.gradle/caches+, not
        #   +~/.gradle+) so +gradle.properties+ / +init.d+ /
        #   +.credentials+ never reach the sandbox at all — the lower
        #   layer is the host's real file, so a narrow mount, not the
        #   write's ephemerality, is what keeps secrets out. See
        #   {Pikuri::Code::ToolchainPaths} for the credential /
        #   persistence exclusion rationale.
        # * +workspace.writable+ → +--bind+ (read+write, *persistent* —
        #   not an overlay) each path. The workspace temp's host path
        #   (under +~/.cache/pikuri+, not under +/tmp+) is bound at its
        #   host path too — so the same dir is reachable via both
        #   +/tmp+ (LLM reflex) and the host path (advertised by the
        #   system prompt, used consistently by the file tools off the
        #   host filesystem).
        #
        # == Overlay support
        #
        # overlayfs in a user namespace needs Linux ≥ 5.11. The
        # constructor probes for it once and remembers the result:
        # when supported, +workspace.readable+ dirs are overlaid (the
        # writes-just-work path above); when not, they fall back to
        # +--ro-bind+ and the sandbox still functions — but writes into
        # a read-only toolchain dir (e.g. +gem install+ into
        # +~/.rbenv+) fail with +EROFS+, surfaced to the LLM as the
        # bash observation. The probe degrades with a logged warning
        # rather than raising, so an old-kernel host still gets a
        # working (if less convenient) sandbox. {SYSTEM_ROOTS} and
        # {ETC_BASELINE} stay +--ro-bind+ regardless — nothing writes
        # to +/lib+ or +/etc/resolv.conf+ (and overlayfs is
        # directory-only, so the single-file +/etc+ entries can't be
        # overlays anyway).
        #
        # == Concurrency contract
        #
        # Each {Bubblewrap} instance must own its upper/workdir paths
        # exclusively — overlayfs returns +EBUSY+ when two live mounts
        # share an upper or workdir. The bundled wiring guarantees
        # this:
        #
        # * One {Workspace::Filesystem} mints one umbrella
        #   ({Workspace::Filesystem#internal_temp}).
        # * One umbrella feeds one {Bubblewrap}, which derives its
        #   per-path +overlay-<slug>/+ subdirs from that umbrella.
        # * {Bash} runs +bash -c+ synchronously
        #   ({Pikuri::Subprocess#wait}), and sub-agents block their
        #   parent's loop while running (the +agent+ tool from
        #   +pikuri-subagents+ runs its child's loop synchronously
        #   in its +execute+ closure), so two +bwrap+ invocations
        #   spawned by the same pikuri process never overlap in time.
        #
        # Two concurrent pikuri-code processes are independent — each
        # mints its own umbrella, each gets its own
        # +overlay-<slug>/+ tree, the host's real cache (the shared
        # *lower* layer) is read-only and per kernel docs may be
        # shared across overlay mounts without restriction. A
        # downstream host that builds something fan-out-y (e.g. N
        # parallel shell tasks reusing one {Bubblewrap}) would
        # collide on its own; pikuri itself doesn't.
        #
        # == What the overlay does NOT defend
        #
        # Bubblewrap as a whole is *blast-radius containment* for the
        # bash subprocess, not a malware-resistant boundary. Prompt
        # injection that reaches the LLM can still:
        #
        # * Modify project source under +project_root+ (the LLM
        #   legitimately needs Write access there — overlay isn't an
        #   option without breaking the agent).
        # * Inject a malicious dependency in the project's
        #   +build.gradle.kts+/+pom.xml+/+package.json+, which the next
        #   build will execute.
        # * Exfiltrate over the network — +--share-net+ is intentional
        #   so +git pull+ / +mvn+ / +gem install+ / +curl+ work.
        #
        # The overlay specifically prevents *cross-project*
        # contamination via shared $HOME caches. Users who need
        # adversarial isolation run pikuri-code inside a container /
        # devcontainer; the container is the outer boundary, the
        # bwrap sandbox is the inner one. See CLAUDE.md "Scope
        # decisions" / "Workspace seam" and the matching note on
        # +Filesystem::AllowAll+.
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
        # * Workspace has +temp+ but +alias_tmp_to_temp+ is off —
        #   inconsistent setup: this sandbox would bind +workspace.temp+
        #   at +/tmp+ inside the subprocess (so the LLM's reflexive
        #   +/tmp+ writes persist), but file tools running on the host
        #   would still reject +/tmp/foo+ as outside the workspace.
        #   The LLM would write via bash and then fail to read via the
        #   file tools; fail at construction instead of letting that
        #   trap fire mid-conversation.
        # * +bwrap+ not on +PATH+ → +Errno::ENOENT+ wrapped as +RuntimeError+.
        # * Kernel lacks user-namespace support entirely (some hardened
        #   distros) → the basic +bwrap+ probe exits non-zero, surfaced
        #   as +RuntimeError+.
        #
        # The constructor *also* probes overlayfs support, but a failure
        # there does NOT raise — it degrades to read-only binds with a
        # logged warning (see "Overlay support" above). A working
        # sandbox on an old kernel beats no sandbox at all.
        #
        # The raising cases fail at boot, not on the first +bash+ tool
        # call — matches the "errors are loud" convention. The host
        # opts out of sandboxing entirely via +--no-sandbox+ / +--yolo+.
        class Bubblewrap
          BWRAP_BINARY = 'bwrap'

          LOGGER = Pikuri.logger_for('Sandbox')

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

          # Container / VM control sockets that, if reachable from
          # inside the sandbox, give the bash subprocess a one-step
          # path to root-equivalent host access. The Docker daemon
          # cheerfully honors +docker run --privileged -v / /host+,
          # so exposing +/var/run/docker.sock+ to a sandboxed agent
          # effectively undoes the sandbox. Same story for containerd,
          # CRI-O, podman (rootful), buildkit, libvirt, LXD.
          #
          # The pikuri default workspace doesn't expose +/var+ or
          # +/run+ at all (none of {SYSTEM_ROOTS}, {ETC_BASELINE}, or
          # {ToolchainPaths.readable} touches them), so these sockets
          # are unreachable by default. {.reject_container_socket_exposure!}
          # guards the *configuration* surface — a downstream binary
          # adding the docker socket to +workspace.writable+ "so the
          # agent can run +docker build+" would unknowingly hand the
          # LLM the keys, and we'd rather fail loud at construction.
          #
          # Rootless variants under +$XDG_RUNTIME_DIR+ /
          # +/run/user/$UID/+ are computed at class-load time. The
          # list is not exhaustive; it covers the engines most likely
          # to be installed on a Linux dev box. A downstream host
          # with an unusual setup can subclass and extend.
          DENIED_CONTAINER_SOCKETS = begin
            xdg_runtime = ENV['XDG_RUNTIME_DIR'] || "/run/user/#{Process.uid}"
            paths = %w[
              /var/run/docker.sock
              /run/docker.sock
              /var/run/containerd/containerd.sock
              /run/containerd/containerd.sock
              /var/run/crio/crio.sock
              /run/crio/crio.sock
              /run/podman/podman.sock
              /var/run/podman/podman.sock
              /run/buildkit/buildkitd.sock
              /var/run/buildkit/buildkitd.sock
              /var/run/libvirt/libvirt-sock
              /run/libvirt/libvirt-sock
              /var/lib/lxd/unix.socket
              /var/snap/lxd/common/lxd/unix.socket
            ]
            paths.concat([
              "#{xdg_runtime}/docker.sock",
              "#{xdg_runtime}/podman/podman.sock"
            ])
            paths.map { |p| Pathname.new(p) }.uniq.freeze
          end

          # @param filesystem [Pikuri::Workspace::Filesystem] the source of
          #   per-host readable/writable roots, the +chdir+ target for
          #   the subprocess, and the parent of the per-session
          #   overlay state ({Workspace::Filesystem#internal_temp}).
          #   Every +filesystem.readable+ dir is mounted as a read-write
          #   ephemeral overlay (or +--ro-bind+ if the kernel lacks
          #   overlayfs-in-userns support); see the class header.
          # @raise [RuntimeError] if the filesystem lists +/+ as writable
          #   (Bubblewrap is for filesystem containment, which is moot
          #   when the entire filesystem is the workspace — typically
          #   {Workspace::Filesystem::AllowAll}; the host should pass
          #   {NONE} instead).
          # @raise [RuntimeError] if the filesystem has +temp+ set but
          #   +alias_tmp_to_temp+ unset — see the class header.
          # @raise [RuntimeError] if any filesystem path equals or is
          #   an ancestor of a known container/VM control socket
          #   (+/var/run/docker.sock+, +containerd.sock+, +podman.sock+,
          #   …); see {DENIED_CONTAINER_SOCKETS}.
          # @raise [RuntimeError] if +bwrap+ isn't on +PATH+ or fails
          #   its basic probe (typically: kernel without user-namespace
          #   support). A *separate* overlayfs probe failure does NOT
          #   raise — it degrades to read-only binds (see the class
          #   header's "Overlay support").
          def initialize(filesystem:)
            @filesystem = filesystem
            reject_unbounded_workspace!
            reject_unaliased_temp!
            reject_container_socket_exposure!
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
            return unless @filesystem.writable.include?(Pathname.new('/').realpath)

            raise "Code::Bash::Sandbox::Bubblewrap: workspace lists '/' as " \
                  'writable (likely Workspace::Filesystem::AllowAll). ' \
                  'Bubblewrap exists to contain the subprocess to a subset ' \
                  'of the filesystem, which is moot when the whole filesystem ' \
                  'is the workspace. Pass Sandbox::NONE instead.'
          end

          # When the workspace has a temp dir, this sandbox binds it at
          # +/tmp+ inside the subprocess so the LLM's reflexive +/tmp+
          # writes persist across bash calls. That bind only pays off
          # if the workspace also rewrites +/tmp/*+ in the file tools
          # via +alias_tmp_to_temp+; otherwise the LLM writes via bash
          # and then hits "outside workspace" on every Read/Write/Edit/
          # Grep/Glob against the same +/tmp/*+ path. Fail at boot.
          def reject_unaliased_temp!
            return if @filesystem.temp.nil?
            return if @filesystem.alias_tmp_to_temp

            raise 'Code::Bash::Sandbox::Bubblewrap: workspace has temp set ' \
                  'but alias_tmp_to_temp is off. This sandbox binds ' \
                  'workspace.temp at /tmp inside the subprocess, which ' \
                  'requires the workspace to rewrite /tmp/* in the file ' \
                  'tools so bash and file tools agree on one path. ' \
                  'Construct the workspace with alias_tmp_to_temp: true, ' \
                  'or pass Sandbox::NONE if you do not want the bind.'
          end

          # A workspace path that *contains* a container/VM control
          # socket (e.g. a host pinning +/var/run+ to
          # +workspace.writable+ "so docker works") effectively
          # neutralizes the sandbox: from inside, +docker run
          # --privileged -v / /host+ is a one-step root escape. The
          # pikuri default workspace never exposes +/var/run+ or
          # +/run+, but a downstream host could; refuse loudly at
          # construction so the operator notices.
          #
          # The check compares each socket path against every
          # +workspace.writable+ / +workspace.readable+ root: a
          # workspace root +R+ exposes socket +S+ iff +R == S+ or
          # +S+ is below +R+ (so a +--bind+/+--ro-bind+ at +R+ would
          # carry +S+ along).
          def reject_container_socket_exposure!
            exposed = []
            roots = (@filesystem.writable + @filesystem.readable).uniq
            DENIED_CONTAINER_SOCKETS.each do |sock|
              root = roots.find do |r|
                r == sock || sock.to_s.start_with?(r.to_s + File::SEPARATOR)
              end
              exposed << [root, sock] if root
            end
            return if exposed.empty?

            details = exposed.map { |r, s| "  - #{s} (via workspace root #{r})" }.join("\n")
            raise "Code::Bash::Sandbox::Bubblewrap: workspace would expose " \
                  "container/VM control sockets to the sandbox:\n#{details}\n\n" \
                  "Reaching any of these from inside the sandbox is a one-step " \
                  "root escape (e.g. 'docker run --privileged -v / /host'). " \
                  'Remove the offending paths from workspace.readable / ' \
                  'workspace.writable, or pass Sandbox::NONE if you genuinely ' \
                  'intend the agent to drive a container daemon.'
          end

          # Probes +bwrap+ itself (raises if missing or user namespaces
          # are unsupported), then probes overlayfs support and caches
          # the result in +@overlay_supported+. The overlay probe runs
          # only when there's at least one dir that would actually be
          # overlaid — i.e. a +workspace.readable+ entry that isn't
          # already a +workspace.writable+ +--bind+ (a project-root-only
          # workspace overlays nothing, so the second spawn would be
          # wasted).
          def check_bwrap!
            result = Pikuri::Subprocess.spawn(
              BWRAP_BINARY,
              '--unshare-all', '--share-net',
              '--ro-bind', '/', '/',
              '--die-with-parent',
              '/bin/true',
              chdir: '/'
            ).wait
            unless result.status.success?
              raise "Code::Bash::Sandbox::Bubblewrap: bwrap probe failed " \
                    "(exit #{result.status.exitstatus}). Is user-namespace " \
                    'support enabled in the kernel? Pass --no-sandbox to skip.'
            end

            overlayable = @filesystem.readable - @filesystem.writable
            @overlay_supported = overlayable.empty? ? false : probe_overlay_support?
          rescue Errno::ENOENT
            raise "Code::Bash::Sandbox::Bubblewrap: 'bwrap' not found on PATH. " \
                  'Install bubblewrap (apt-get install bubblewrap / dnf install ' \
                  'bubblewrap / pacman -S bubblewrap) or pass --no-sandbox.'
          end

          # Second-stage probe: overlayfs in a user namespace requires
          # Linux ≥ 5.11. The basic +check_bwrap!+ probe succeeds on
          # older kernels too (it doesn't touch overlay), so we probe
          # separately here. Unlike the basic probe this does NOT raise
          # on failure — it logs a warning and returns +false+, and
          # {#bwrap_args} falls back to +--ro-bind+ for the readable
          # dirs. A working sandbox (toolchain dirs visible read-only,
          # writes failing with +EROFS+) beats no sandbox on an old
          # kernel; the host can still pass +--no-sandbox+ to opt out.
          #
          # Uses +--overlay-src /usr --tmp-overlay /tmp+: declares
          # +/usr+ as the read-only lower layer (always present on
          # Linux, not an ancestor of +/tmp+ — overlayfs forbids
          # ancestor relationships between layers) and lets bwrap
          # back the upper with tmpfs. No host paths to manage, no
          # leftover state, and the +--overlay-src+ is required —
          # +--tmp-overlay+ refuses to construct without at least one.
          #
          # @return [Boolean] whether overlayfs-in-userns works here.
          def probe_overlay_support?
            result = Pikuri::Subprocess.spawn(
              BWRAP_BINARY,
              '--unshare-all', '--share-net',
              '--ro-bind', '/', '/',
              '--overlay-src', '/usr',
              '--tmp-overlay', '/tmp',
              '--die-with-parent',
              '/bin/true',
              chdir: '/'
            ).wait
            return true if result.status.success?

            LOGGER.warn(
              "overlayfs in a user namespace is unavailable (bwrap overlay probe " \
              "exit #{result.status.exitstatus}; Linux >= 5.11 required). Falling " \
              'back to read-only binds for toolchain dirs — gem/bundle/pip/build ' \
              'installs into read-only toolchain dirs will fail with EROFS. Pass ' \
              '--no-sandbox to disable the sandbox entirely.'
            )
            false
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

            # 2. Synthetic /proc + /dev. /tmp is handled separately
            #    below — when the workspace has a temp dir we bind it
            #    at /tmp (so the LLM's reflexive /tmp writes persist
            #    across bash calls); otherwise we fall back to tmpfs.
            args.concat(['--proc', '/proc', '--dev', '/dev'])

            if @filesystem.temp
              args.concat(['--bind', @filesystem.temp.to_s, '/tmp'])
              mounted << '/tmp'
            else
              args.concat(['--tmpfs', '/tmp'])
              mounted << '/tmp'
            end

            # 3. Workspace-derived mounts. Writable wins on overlap
            #    (writable ⊆ readable in the Workspace constructor;
            #    iterating writable first + the `mounted` guard
            #    ensures each path is mounted once). Writable paths are
            #    plain read+write --bind (persistent). Readable paths
            #    are read-write ephemeral overlays when overlayfs is
            #    supported (so toolchain installs succeed but vanish at
            #    session exit), falling back to --ro-bind otherwise.
            @filesystem.writable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(['--bind', s, s])
              mounted << s
            end
            @filesystem.readable.each do |p|
              s = p.to_s
              next if mounted.include?(s)
              args.concat(@overlay_supported ? overlay_mount_args(s) : ['--ro-bind', s, s])
              mounted << s
            end

            # 4. Isolation + chdir.
            args.concat([
              '--unshare-all', '--share-net',
              '--die-with-parent', '--new-session',
              '--chdir', @filesystem.project_root.to_s
            ])
            args
          end

          # Lazily mint +<workspace.internal_temp>/overlay-<slug>/{upper,work}+
          # for +path+ and return the +bwrap+ argv fragment that
          # mounts an overlayfs at +path+ with the host's real +path+
          # as the read-only lower. The umbrella + its Finalizers-driven cleanup are
          # owned by the workspace; touching {Workspace::Filesystem#internal_temp}
          # here is what triggers the lazy mint the first time any
          # overlay path needs storage.
          #
          # Calling this on every +wrap+ invocation is intentional:
          # +mkdir_p+ is idempotent, and a fresh mkdir on each call
          # is the cheapest way to recover from "someone wiped the
          # umbrella mid-session" without per-instance bookkeeping.
          #
          # *Concurrency:* the returned +upper+ and +work+ paths are
          # *not* safe to mount from two live overlay mounts at the
          # same time — overlayfs returns +EBUSY+. This is fine in
          # pikuri because {Bash} serializes bash calls and sub-agents
          # block their parent's loop; see the class header's
          # "Concurrency contract" section. A downstream host that
          # parallelizes two bash invocations through the same
          # {Bubblewrap} would hit +EBUSY+ at the second mount.
          def overlay_mount_args(path)
            slug = path.gsub(/[^A-Za-z0-9._-]/, '_').sub(/\A_+/, '')
            overlay_dir = @filesystem.internal_temp + "overlay-#{slug}"
            upper = overlay_dir + 'upper'
            work  = overlay_dir + 'work'
            FileUtils.mkdir_p(upper)
            FileUtils.mkdir_p(work)
            ['--overlay-src', path, '--overlay', upper.to_s, work.to_s, path]
          end
        end

        # Full-filesystem, network-severed sandbox: the *inverse* of
        # {Bubblewrap}. Where Bubblewrap contains the subprocess to a
        # curated subset of the filesystem while *keeping* the network
        # (+--unshare-all --share-net+), {FullFsNoNet} does the opposite —
        # it binds the entire real root read-write (+--bind / /+) and
        # unshares *only* the network (+--unshare-net+).
        #
        # This is the sandbox for the offline OS-helper agent
        # (+pikuri-os+ / +bin/pikuri-os-assistant+; design in
        # +ideas/os-assistant.md+). That agent's whole job is to operate
        # the real host, so filesystem *containment* is the wrong tool —
        # there is deliberately no fs sandbox. The one isolation that
        # matters is egress: with the network namespace unshared, an
        # injection in a file the agent reads has nowhere to exfiltrate
        # to. The trifecta's egress leg is cut by the kernel, not by a
        # prompt — the load-bearing invariant of that design.
        #
        # == What's bound
        #
        # * +--bind / /+ — the entire real root, read-write. No overlays,
        #   no allowlist: the agent sees and edits the host as it is.
        #   Running unprivileged, +bwrap+ creates a user namespace that
        #   maps the caller's uid to itself, so root-owned files
        #   (+/etc/*+, +/usr/*+, another user's +$HOME+) appear owned by
        #   an unmapped id and are *not* writable — and +/etc/shadow+ &
        #   friends stay unreadable. That lines up exactly with the
        #   OS-helper's "advise, don't execute, anything privileged" rule:
        #   privileged edits need +sudo+, which isn't available in the
        #   namespace and is handed to the user instead.
        # * +--proc /proc+ + +--dev /dev+ — a fresh procfs and a minimal
        #   synthetic +/dev+ (null/zero/random/tty …) layered over the
        #   bound root. Because the PID namespace is *not* unshared (see
        #   "Isolation"), the fresh +/proc+ still shows host processes —
        #   essential for the agent's job (+ps+, +top+, +systemctl
        #   status+, resource diagnosis). Raw block devices aren't in the
        #   synthetic +/dev+, but reading them needs root anyway, so that
        #   path is user-run regardless.
        #
        # == Isolation: network only, deliberately
        #
        # +--unshare-net+ and nothing else. In particular the PID, IPC,
        # and UTS namespaces are *kept shared* — unlike {Bubblewrap}'s
        # +--unshare-all+ — because an OS helper must see and reason about
        # host processes and services. Unsharing PID would make
        # +ps+/+systemctl+ see only the sandbox's own processes and break
        # core use-cases. +--die-with-parent --new-session+ are kept for
        # the same hygiene as Bubblewrap (dies with pikuri; own session,
        # no controlling-terminal injection).
        #
        # == No fallback if the network can't be severed
        #
        # If +bwrap+ is missing, or the kernel forbids unprivileged user /
        # network namespaces, the constructor *raises* — it does NOT
        # degrade to a networked sandbox. This is the opposite of
        # {Bubblewrap}'s overlay probe (a convenience that degrades): here
        # the severed network IS the security property, so silently
        # running with the network attached would void the no-egress
        # invariant. A host that genuinely cannot unshare the network must
        # fix the kernel setting (e.g. +kernel.unprivileged_userns_clone+)
        # or accept that this agent can't run safely there — never fall
        # back.
        #
        # == What this does NOT defend
        #
        # +--bind / /+ exposes everything, including container/VM control
        # sockets (+/var/run/docker.sock+, …). Unsharing the *bash
        # process's* own network namespace does not constrain a container
        # the agent asks the *host daemon* to spawn — a confirmed +docker
        # run --network=host …+ would have full connectivity. So this is
        # NOT a malware boundary; it severs the agent's own egress, and
        # the guard against socket abuse is the confirmer: +docker+/+nc+/
        # +curl+ are mutating, non-allowlisted commands, so they reach the
        # human (see {Bash} confirmation + the OS-helper's read-only
        # auto-confirmer). Users who need a hard boundary run the whole
        # agent inside a container / VM.
        class FullFsNoNet
          BWRAP_BINARY = 'bwrap'

          # @param filesystem [Pikuri::Workspace::Filesystem] used only
          #   for its +project_root+ (the subprocess's +--chdir+ target);
          #   the bind set is the whole real root regardless, so the
          #   readable/writable lists are intentionally ignored. Pairs
          #   naturally with {Workspace::Filesystem::AllowAll}, which
          #   {Bubblewrap} rejects and this sandbox embraces.
          # @raise [RuntimeError] if +bwrap+ isn't on +PATH+, or if the
          #   kernel refuses an unprivileged user / network namespace (so
          #   the network cannot be severed). There is deliberately no
          #   fallback — see the class header.
          def initialize(filesystem:)
            @filesystem = filesystem
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+
          #   argv {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + full-root bind + fresh
          #   /proc + /dev + +--unshare-net+ + isolation + +argv+, ready
          #   to hand to {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [
              BWRAP_BINARY,
              '--bind', '/', '/',
              '--dev', '/dev',
              '--proc', '/proc',
              '--unshare-net',
              '--die-with-parent', '--new-session',
              '--chdir', @filesystem.project_root.to_s,
              *argv
            ]
          end

          private

          # Probe the exact isolation we rely on: a full-root bind in a
          # fresh, *network-unshared* namespace. Unlike {Bubblewrap}'s
          # probe (which keeps +--share-net+), this MUST exercise
          # +--unshare-net+ so a kernel that forbids unprivileged net
          # namespaces fails here, loudly, rather than at the first bash
          # call — and never degrades to a networked run.
          #
          # @raise [RuntimeError] on probe failure or missing +bwrap+.
          def check_bwrap!
            result = Pikuri::Subprocess.spawn(
              BWRAP_BINARY,
              '--bind', '/', '/',
              '--unshare-net',
              '--die-with-parent',
              '/bin/true',
              chdir: '/'
            ).wait
            return if result.status.success?

            raise 'Code::Bash::Sandbox::FullFsNoNet: bwrap probe failed ' \
                  "(exit #{result.status.exitstatus}). The network sandbox " \
                  'needs unprivileged user + network namespaces; some hardened ' \
                  'kernels disable them (e.g. kernel.unprivileged_userns_clone=0). ' \
                  'This sandbox does NOT fall back to a networked run — severing ' \
                  'the network is the security property. Fix the kernel setting, ' \
                  'or do not run the OS assistant on this host.'
          rescue Errno::ENOENT
            raise "Code::Bash::Sandbox::FullFsNoNet: 'bwrap' not found on PATH. " \
                  'Install bubblewrap (apt-get install bubblewrap / dnf install ' \
                  'bubblewrap / pacman -S bubblewrap). This agent runs every bash ' \
                  'command in a network-severed namespace; there is no fallback.'
          end
        end
      end
    end
  end
end
