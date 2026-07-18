# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'set'

module Pikuri
  module Code
    class Bash
      # Filesystem-sandbox seam for the bash tool. A sandbox responds to
      # +#wrap(argv) → Array<String>+, transforming the +timeout … bash -c
      # <cmd>+ argv {Bash.run} would spawn into the argv actually spawned:
      # {NONE} returns it unchanged (the default), {Bubblewrap} prepends
      # +bwrap+ + bind/isolation flags, {FullFsNoNet} is Bubblewrap's inverse.
      #
      # Distinct from Workspace, deliberately: Workspace is "what the LLM
      # observes via Read/Write/Edit/Grep/Glob"; Sandbox is "what the executed
      # subprocess sees." They overlap on project + toolchain dirs but diverge
      # on the OS-runtime baseline ({Bubblewrap::ETC_BASELINE} — TLS certs,
      # DNS, tz, hosts): the LLM has no need to {Read} +/etc/resolv.conf+, the
      # +curl+ subprocess does. Separate objects keep each allowlist with its
      # owner.
      module Sandbox
        # Identity sandbox — passthrough. The {Bash.new} default and the
        # +--no-sandbox+ / +--yolo+ opt-out.
        module NONE
          # @param argv [Array<String>]
          # @return [Array<String>] argv unchanged
          def self.wrap(argv)
            argv
          end
        end

        # Bubblewrap (+bwrap+(1)) sandbox: composes a +bwrap+ argv from the
        # supplied {Workspace} plus a curated OS-runtime baseline, so the bash
        # subprocess sees only project + toolchain + ephemeral temp + the few
        # +/etc+ files needed for TLS/DNS/timezone/name-resolution.
        #
        # == What's bound
        #
        # * {SYSTEM_ROOTS} (+/lib+ +/lib64+ +/bin+ +/sbin+) and {ETC_BASELINE}
        #   — +--ro-bind+. Not in {Workspace#readable} (the LLM has no business
        #   grepping +/sbin+), but the subprocess needs them for the dynamic
        #   linker, standard utilities, and a TLS/DNS/tz/hostname handshake.
        #   +/usr+ and +/opt+ arrive via {Workspace#readable} instead (added by
        #   {Pikuri::Code::ToolchainPaths.readable}).
        # * +/tmp+ — bound to {Workspace::Filesystem#temp} when set (so the
        #   LLM's reflexive +/tmp+ writes persist across bash calls), else
        #   +--tmpfs+ (per-call ephemeral). The host's +/tmp+ is never exposed.
        #   +/proc+ (synthetic, +--unshare-pid+) and +/dev+ (null/zero/random/
        #   tty) round out the synthetic mounts.
        # * +workspace.writable+ — +--bind+ (read+write, *persistent*).
        # * +workspace.readable+ — read-write *ephemeral overlay* (host dir is
        #   the read-through lower; a per-session upper under
        #   +<internal_temp>/overlay-<slug>/+ absorbs writes), so +gem install+
        #   / +bundle+ / +mvn+ / +gradle+ / +cargo+ / +pip+ succeed against
        #   +/usr+, +~/.rbenv+, +~/.gradle/caches+, … while the host's real
        #   toolchain is untouched. Writes survive across bash calls within one
        #   session (warm cache — the upper is a persistent dir, re-mounted each
        #   call, not a tmpfs that dies with the bwrap process) but not across
        #   sessions (a poisoned session can't propagate into the host's normal
        #   +gradle+ or a future session). The cache entries in {ToolchainPaths}
        #   are deliberately narrow subdirs (+~/.gradle/caches+, not
        #   +~/.gradle+) so +gradle.properties+ / +init.d+ / +.credentials+
        #   never reach the sandbox — the lower is the host's real file, so the
        #   narrow *mount*, not the write's ephemerality, keeps secrets out.
        #
        # == Overlay support
        #
        # overlayfs-in-userns needs Linux ≥ 5.11; the constructor probes once.
        # Unsupported → +--ro-bind+ fallback: the sandbox still works, but a
        # write into a read-only toolchain dir (+gem install+ into +~/.rbenv+)
        # fails with +EROFS+, surfaced as the bash observation. This degrades
        # with a logged warning, never raises — a working sandbox on an old
        # kernel beats none. {SYSTEM_ROOTS} / {ETC_BASELINE} stay +--ro-bind+
        # regardless (nothing writes there, and overlayfs is directory-only so
        # the single-file +/etc+ entries can't be overlays anyway).
        #
        # == Concurrency
        #
        # Each instance must own its upper/workdir exclusively — overlayfs
        # returns +EBUSY+ on a shared upper. The bundled wiring guarantees it:
        # one {Workspace::Filesystem} mints one umbrella
        # ({Workspace::Filesystem#internal_temp}) feeding one {Bubblewrap}, and
        # {Bash} runs +bash -c+ synchronously ({Pikuri::Subprocess#wait}) while
        # sub-agents block their parent's loop — so two +bwrap+ invocations
        # from one pikuri process never overlap in time. Two pikuri-code
        # *processes* are independent (each its own umbrella; the shared
        # read-only lower may be shared across mounts per kernel docs). A host
        # that reuses one {Bubblewrap} across parallel bash tasks would collide
        # on its own; pikuri doesn't.
        #
        # == What the overlay does NOT defend
        #
        # Blast-radius containment for the subprocess, not a malware boundary.
        # Prompt injection reaching the LLM can still modify project source
        # under +project_root+ (the LLM legitimately needs Write there), inject
        # a malicious dependency the next build executes, or exfiltrate over the
        # network (+--share-net+ is intentional so +git pull+/+mvn+/+curl+
        # work). The overlay specifically prevents *cross-project* contamination
        # via shared $HOME caches. Users needing adversarial isolation run
        # pikuri-code inside a container — the container is the outer boundary,
        # bwrap the inner. See CLAUDE.md's "Workspace seam" and the matching
        # note on +Filesystem::AllowAll+.
        #
        # == Isolation
        #
        # +--unshare-all --share-net+: PID/mount/IPC/user/UTS unshared (can't
        # see host processes, mount on the host, or ptrace); the network is
        # *kept* shared because bash routinely needs +git pull+/+mvn+/+gem
        # install+/+curl+. +--die-with-parent --new-session+: dies with pikuri,
        # own session group (no terminal-control bleed).
        #
        # == Failures at construction (loud, not on the first tool call)
        #
        # Three cases raise; the overlay probe does NOT (see above):
        #
        # * workspace lists +/+ as writable (typically {Filesystem::AllowAll})
        #   — containment is structurally moot when the whole filesystem is the
        #   workspace; the host should pass {NONE}.
        # * workspace has +temp+ but +alias_tmp_to_temp+ off — this binds
        #   +workspace.temp+ at +/tmp+ inside the subprocess, but the host-side
        #   file tools would still reject +/tmp/foo+ as outside the workspace,
        #   so the LLM would write via bash then fail to read via the tools;
        #   fail now rather than mid-conversation.
        # * +bwrap+ missing (+Errno::ENOENT+) or its basic probe exits non-zero
        #   (kernel without user-namespace support).
        class Bubblewrap
          BWRAP_BINARY = 'bwrap'

          LOGGER = Pikuri.logger_for('Sandbox')

          # System-root dirs the subprocess needs that aren't in
          # {Workspace#readable}. Each is +--ro-bind+'d if it exists on
          # the host; missing entries are skipped silently (older or
          # unusual layouts).
          SYSTEM_ROOTS = %w[/lib /lib64 /bin /sbin].freeze

          # +/etc+ file allowlist for the subprocess. Each is +--ro-bind+'d
          # if it exists on the host. Nothing else from +/etc+ is exposed —
          # no +shadow+, no SSH config, no NetworkManager state.
          ETC_BASELINE = %w[
            /etc/ssl
            /etc/ca-certificates
            /etc/pki
            /etc/resolv.conf
            /etc/nsswitch.conf
            /etc/localtime
            /etc/hosts
          ].freeze

          # Container / VM control sockets that, if reachable from inside the
          # sandbox, give the bash subprocess a one-step path to
          # root-equivalent host access (the Docker daemon honors +docker run
          # --privileged -v / /host+; same for containerd, CRI-O, rootful
          # podman, buildkit, libvirt, LXD). The pikuri default workspace never
          # exposes +/var+ or +/run+, so these are unreachable by default;
          # {.reject_container_socket_exposure!} guards the *configuration*
          # surface — a downstream binary adding the docker socket to
          # +workspace.writable+ would unknowingly hand the LLM the keys.
          #
          # Rootless variants under +$XDG_RUNTIME_DIR+ / +/run/user/$UID/+ are
          # computed at class-load time. Not exhaustive; covers the engines
          # most likely on a Linux dev box. A downstream host can subclass and
          # extend.
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

          # @param filesystem [Pikuri::Workspace::Filesystem] source of the
          #   per-host readable/writable roots, the +chdir+ target, and the
          #   parent of the per-session overlay state
          #   ({Workspace::Filesystem#internal_temp}). Every +readable+ dir is
          #   mounted as a read-write ephemeral overlay (or +--ro-bind+ without
          #   overlayfs-in-userns); see the class header.
          # @raise [RuntimeError] if +/+ is writable (pass {NONE} instead), if
          #   +temp+ is set but +alias_tmp_to_temp+ isn't, if any path equals or
          #   contains a {DENIED_CONTAINER_SOCKETS} entry, or if +bwrap+ is
          #   missing / fails its basic probe. A *separate* overlayfs probe
          #   failure does NOT raise — it degrades to read-only binds.
          def initialize(filesystem:)
            @filesystem = filesystem
            reject_unbounded_workspace!
            reject_unaliased_temp!
            reject_container_socket_exposure!
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+ argv
          #   {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + isolation flags + bind-mounts +
          #   +argv+, ready for {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [BWRAP_BINARY, *bwrap_args, *argv]
          end

          private

          # Refuse to construct when +/+ is in the writable set (typically
          # {Workspace::Filesystem::AllowAll}) — filesystem containment is moot
          # when the whole filesystem is the workspace.
          def reject_unbounded_workspace!
            return unless @filesystem.writable.include?(Pathname.new('/').realpath)

            raise "Code::Bash::Sandbox::Bubblewrap: workspace lists '/' as " \
                  'writable (likely Workspace::Filesystem::AllowAll). ' \
                  'Bubblewrap exists to contain the subprocess to a subset ' \
                  'of the filesystem, which is moot when the whole filesystem ' \
                  'is the workspace. Pass Sandbox::NONE instead.'
          end

          # A temp bind at +/tmp+ only pays off if the workspace also rewrites
          # +/tmp/*+ in the file tools via +alias_tmp_to_temp+; otherwise the
          # LLM writes via bash then hits "outside workspace" on every file-tool
          # access to the same path. Fail at boot.
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

          # A workspace root that equals or contains a container/VM control
          # socket effectively neutralizes the sandbox (+docker run
          # --privileged -v / /host+ from inside is a one-step root escape).
          # A root +R+ exposes socket +S+ iff +R == S+ or +S+ is below +R+.
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

          # Probe +bwrap+ (raises if missing or user namespaces are
          # unsupported), then probe overlayfs and cache the verdict in
          # +@overlay_supported+. The overlay probe runs only when at least one
          # dir would actually be overlaid (a +readable+ entry not already a
          # +writable+ +--bind+), so a project-root-only workspace skips it.
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

          # Second-stage probe: overlayfs-in-userns needs Linux ≥ 5.11, which
          # the basic {#check_bwrap!} probe doesn't exercise. Unlike that one
          # this does NOT raise on failure — it logs a warning and returns
          # +false+, and {#bwrap_args} falls back to +--ro-bind+.
          #
          # Uses +--overlay-src /usr --tmp-overlay /tmp+: +/usr+ is the
          # read-only lower (always present, not an ancestor of +/tmp+ —
          # overlayfs forbids ancestor relationships), tmpfs backs the upper.
          # No host paths to manage; +--tmp-overlay+ refuses to construct
          # without at least one +--overlay-src+.
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
          # for +path+ and return the +bwrap+ fragment mounting an overlayfs at
          # +path+ with the host's real +path+ as the read-only lower. The
          # umbrella + its Finalizers-driven cleanup are owned by the workspace;
          # touching {Workspace::Filesystem#internal_temp} here triggers the
          # lazy mint. Called on every +wrap+: +mkdir_p+ is idempotent and is
          # the cheapest recovery from a mid-session umbrella wipe.
          #
          # *Concurrency:* the +upper+/+work+ paths are not safe to mount from
          # two live overlays at once (+EBUSY+) — fine because {Bash} serializes
          # bash calls; see the class header's "Concurrency". A downstream host
          # parallelizing through one {Bubblewrap} would hit +EBUSY+ at the
          # second mount.
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

        # Full-filesystem, network-severed sandbox: the inverse of {Bubblewrap}.
        # Where Bubblewrap contains the subprocess to a curated subset while
        # keeping the network, {FullFsNoNet} binds the entire real root
        # read-write (+--bind / /+) and unshares *only* the network
        # (+--unshare-net+).
        #
        # This is the sandbox for the offline OS-helper agent (+pikuri-os+;
        # design in +ideas/pikuri-os.md+). That agent's job is to operate
        # the real host, so filesystem *containment* is the wrong tool — there
        # is deliberately no fs sandbox. The one isolation that matters is
        # egress: with the network namespace unshared, an injection in a file
        # the agent reads has nowhere to exfiltrate to. The trifecta's egress
        # leg is cut by the kernel, not by a prompt — the load-bearing invariant
        # of that design.
        #
        # == What's bound
        #
        # * +--bind / /+ — the entire real root, read-write, no overlays.
        #   Running unprivileged, +bwrap+'s user namespace maps the caller's
        #   uid to itself, so root-owned files (+/etc/*+, another user's
        #   +$HOME+) appear owned by an unmapped id and are *not* writable (and
        #   +/etc/shadow+ stays unreadable) — matching the OS-helper's "advise,
        #   don't execute anything privileged" rule: privileged edits need
        #   +sudo+, unavailable in the namespace, so they go to the user.
        # * +--bind /dev /dev+ — the *real* device tree, not bwrap's synthetic
        #   +--dev+. It's redundant with +--bind / /+ but stated explicitly so
        #   it survives someone narrowing the root bind. A synthetic +/dev+
        #   (correct for {Bubblewrap}, whose job is containment) would omit the
        #   block-device nodes (+/dev/nvme0n1+, +/dev/sda+), and *that omission
        #   corrupts the agent's error signal*: +smartctl -a /dev/nvme0n1+ then
        #   fails +ENOENT+ ("No such device") while +lsblk+/+/sys+ still show a
        #   healthy disk — an incoherent machine the model can't reason about,
        #   so it retry-loops instead of escalating. With the real node present
        #   the unprivileged open fails +EACCES+ ("Permission denied"), the
        #   honest error that says "escalate" — and here escalation *is* the
        #   answer: +sudo+ is unavailable in the namespace, so a privileged read
        #   becomes advice to the human, matching the "advise, don't execute
        #   privileged" rule. This isn't a security regression — the root is
        #   already bound read-write, so the synthetic +/dev+ was hiding nothing
        #   an attacker couldn't otherwise reach; it only mangled the error.
        # * +--proc /proc+ over the bound root. Because the PID namespace is
        #   *not* unshared (see "Isolation"), the fresh +/proc+ still shows host
        #   processes — essential for +ps+/+top+/+systemctl status+.
        #
        # == Isolation: network only, deliberately
        #
        # +--unshare-net+ and nothing else. PID, IPC and UTS are *kept shared*
        # — unlike {Bubblewrap}'s +--unshare-all+ — because an OS helper must
        # see and reason about host processes and services (unsharing PID would
        # blind +ps+/+systemctl+). +--die-with-parent --new-session+ for the
        # same hygiene as Bubblewrap.
        #
        # == No fallback if the network can't be severed
        #
        # If +bwrap+ is missing, or the kernel forbids unprivileged user /
        # network namespaces, the constructor *raises* — it does NOT degrade to
        # a networked sandbox (the opposite of {Bubblewrap}'s overlay probe).
        # Here the severed network IS the security property, so a silent
        # networked run would void the no-egress invariant. A host that can't
        # unshare the network must fix the kernel setting (e.g.
        # +kernel.unprivileged_userns_clone+) or not run this agent there.
        #
        # == What this does NOT defend
        #
        # +--bind / /+ exposes everything, including container/VM control
        # sockets. Unsharing the *bash process's* own network namespace does
        # not constrain a container the agent asks the *host daemon* to spawn —
        # a confirmed +docker run --network=host+ would have full connectivity.
        # So this is NOT a malware boundary; it severs the agent's own egress,
        # and the guard against socket abuse is the confirmer (+docker+/+nc+/
        # +curl+ are mutating, non-allowlisted, so they reach the human). A hard
        # boundary means running the whole agent inside a container / VM.
        class FullFsNoNet
          BWRAP_BINARY = 'bwrap'

          # @param filesystem [Pikuri::Workspace::Filesystem] used only for its
          #   +project_root+ (the +--chdir+ target); the bind set is the whole
          #   real root regardless, so the readable/writable lists are ignored.
          #   Pairs naturally with {Workspace::Filesystem::AllowAll}, which
          #   {Bubblewrap} rejects and this sandbox embraces.
          # @raise [RuntimeError] if +bwrap+ isn't on +PATH+, or if the kernel
          #   refuses an unprivileged user / network namespace (so the network
          #   can't be severed). Deliberately no fallback — see the class header.
          def initialize(filesystem:)
            @filesystem = filesystem
            check_bwrap!
          end

          # @param argv [Array<String>] the +timeout … bash -c <cmd>+ argv
          #   {Bash.run} would have spawned unmediated.
          # @return [Array<String>] +bwrap+ + full-root bind + the real /dev +
          #   fresh /proc + +--unshare-net+ + isolation + +argv+, ready for
          #   {Pikuri::Subprocess.spawn}.
          def wrap(argv)
            [
              BWRAP_BINARY,
              '--bind', '/', '/',
              '--bind', '/dev', '/dev',
              '--proc', '/proc',
              '--unshare-net',
              '--die-with-parent', '--new-session',
              '--chdir', @filesystem.project_root.to_s,
              *argv
            ]
          end

          private

          # Probe the exact isolation we rely on: a full-root bind in a
          # *network-unshared* namespace. Unlike {Bubblewrap}'s probe (which
          # keeps +--share-net+), this MUST exercise +--unshare-net+ so a
          # kernel forbidding unprivileged net namespaces fails here, loudly —
          # never degrading to a networked run.
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
