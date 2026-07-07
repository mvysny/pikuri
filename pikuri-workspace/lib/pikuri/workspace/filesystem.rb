# frozen_string_literal: true

require 'pathname'
require 'tmpdir'
require 'fileutils'

module Pikuri
  module Workspace
    # Defines which paths the agent can see and write to. Constructed with
    # explicit +readable+ / +writable+ prefix lists; every Read/Write/Edit/
    # Grep/Glob/Bash path the agent supplies is checked against those lists
    # before touching the filesystem. Returned Pathnames are absolute,
    # post-symlink-resolution.
    #
    # == Project root, readable, writable
    #
    # +project_root+ is the writable containment ceiling — automatically
    # folded into both +readable+ and +writable+; you can read and write
    # anywhere under the project unconditionally. It is also the base
    # for resolving relative paths supplied by the LLM, and the chdir
    # target tools like {Bash} / {Grep} / {Glob} pass to the subprocess.
    # There is deliberately no separate "cwd" concept: hosts that want
    # the agent to operate inside a specific subtree pass that subtree
    # as +project_root+. +bin/pikuri-code+ enforces this by
    # +Dir.chdir+'ing the Ruby process to the discovered project root
    # at startup if it differs from the launch +Dir.pwd+, so the
    # workspace and the surrounding process agree on one anchor.
    #
    # The extra +readable+ list grants read-only access to additional
    # roots (system toolchains, dependency caches, skill catalogs);
    # the extra +writable+ list grants read+write to additional roots
    # (other project directories the agent should be able to touch).
    #
    # == Session umbrella ({#internal_temp})
    #
    # Every workspace owns a per-process umbrella dir at
    # +~/.cache/pikuri/workspace-XXX/+ ({#internal_temp}). It is minted
    # lazily on first access — workspaces that never touch it (most
    # specs, hosts that don't want a playground and don't use the
    # bubblewrap overlay) pay nothing — and removed at process exit via
    # a {Pikuri::Finalizers} registration. Everything ephemeral this
    # workspace produces lives inside the umbrella, so one
    # +remove_entry+ at process exit cleans the lot:
    #
    # * {#temp} — the LLM-visible playground subdir, present only when
    #   +temp: true+ (see below).
    # * The bubblewrap sandbox's per-toolchain overlay state
    #   (+overlay-<slug>/{upper,work}+ for +~/.gradle/caches+, +~/.m2/repository+,
    #   …), used to keep cross-project toolchain caches isolated to one
    #   pikuri-code session. See
    #   {Pikuri::Code::Bash::Sandbox::Bubblewrap}.
    #
    # The umbrella deliberately lives in +~/.cache/pikuri+ rather than
    # +/tmp+: the {Pikuri::Code::Bash::Sandbox::Bubblewrap} sandbox
    # binds {#temp} at +/tmp+ inside the sandbox (so the LLM's
    # reflexive +/tmp+ writes persist across bash calls). With the
    # umbrella already under +/tmp+, that bind would land on top of
    # itself and per-call mountpoint creation would pollute the dir
    # recursively. +~/.cache/pikuri+ avoids the collision.
    #
    # At gem load, {.sweep_stale_internal_temps!} prunes umbrella dirs
    # older than seven days — a safety net for sessions that died
    # before the {Pikuri::Finalizers} sweep could run (SIGKILL, OOM).
    # Recent umbrellas are left alone so a concurrent pikuri-code in
    # another shell isn't disturbed.
    #
    # == Optional temp playground
    #
    # When constructed with +temp: true+, the workspace adds
    # +<internal_temp>/playground+ to +writable+ and exposes it via
    # {#temp}. The binary advertises this path to the LLM (e.g. in the
    # system prompt) as scratch space. Default is +false+: specs and
    # tests that build many workspaces don't pay the mkdir cost, and
    # hosts that don't need a playground don't get one. Either way,
    # the umbrella is shared with everything else that wants ephemeral
    # state — no second tempdir is minted.
    #
    # == Optional /tmp alias
    #
    # When +alias_tmp_to_temp: true+ AND +temp:+ is set, file paths
    # supplied to {#resolve_for_read} / {#resolve_for_write} that
    # start with +/tmp/+ (or are exactly +/tmp+) are rewritten to the
    # host {#temp} path before containment is checked. This is the
    # host-side counterpart to the sandbox's +--bind <temp> /tmp+: bash
    # inside the sandbox writes to +/tmp/foo+, then the file tools
    # (which run on the host, not in the sandbox) accept the same
    # +/tmp/foo+ path and resolve it to the workspace temp's host
    # path. Without this, the LLM would have to remember two paths
    # for the same dir. Off by default; +bin/pikuri-code+ flips it on
    # when the bubblewrap sandbox is enabled.
    #
    # == Read-set vs. write-set
    #
    # {#resolve_for_read} checks against +readable + writable+ (you can
    # read anything writable). {#resolve_for_write} checks against
    # +writable+ only. Tools that mutate state route through the second
    # method; tools that only inspect route through the first.
    #
    # == Existence is not the workspace's concern
    #
    # +resolve_for_read('foo.rb')+ succeeds (returns a +Pathname+) even if
    # +foo.rb+ doesn't exist; the caller ({Read}) errors with
    # file-not-found when it tries to open it. +resolve_for_write+
    # tolerates entirely non-existent paths (Write can create
    # +lib/new/dir/foo.rb+ even when +lib/new/+ doesn't exist) — the
    # caller is responsible for any +mkdir_p+ before writing. This split
    # keeps the workspace narrowly responsible for *containment*, not for
    # filesystem-state checks.
    #
    # == Subprocess environment ({#env})
    #
    # Workspaces own a {#env} +Hash<String,String>+ that subprocess-
    # spawning tools (currently {Pikuri::Code::Bash}) thread into
    # {Pikuri::Subprocess.spawn}. The motivating case: the bubblewrap
    # sandbox doesn't bind-mount +~/.gitconfig+, so +git commit+ inside
    # fails (modern git refuses rather than synthesizing a default
    # from +/etc/passwd+ — which isn't bind-mounted either). The
    # workspace resolves the host's effective git identity at
    # {#project_root} (so +includeIf+ rules apply: a repo under
    # +~/work/my/+ that's covered by a +gitdir:~/work/my/+ include
    # gets that identity, not the global default) and exposes it as
    # +GIT_AUTHOR_*+ / +GIT_COMMITTER_*+ env vars that override config
    # entirely and need no file in the sandbox.
    #
    # The lookup is *lazy* and *memoized*: the constructor doesn't
    # shell out, so building a workspace stays cheap (specs that
    # never read +#env+ pay nothing). First access runs +git -C
    # project_root config user.{name,email}+ once. Falls back to +{}+
    # if +git+ isn't on +PATH+ or no identity is configured — the
    # subprocess then runs unmediated and git's own "please tell me
    # who you are" surfaces inside the sandbox.
    #
    # Hosts that want a different env (extra vars, no git resolution,
    # explicit identity) pass +env:+ to the constructor; that value
    # is used verbatim and the git lookup is skipped. Always frozen
    # by the time it leaves the workspace.
    #
    # == Containment algorithm
    #
    # {#resolve} walks up the input path to its deepest existing ancestor,
    # +realpath+'s that ancestor (resolving any symlinks in the existing
    # portion), then verifies the resolved base matches one of the
    # candidate roots. Four cases:
    #
    # 1. +lib/foo.rb+ (exists) → +existing+ = full path, +base+ matches a
    #    root → returns the realpath'd file.
    # 2. +lib/new/dir/foo.rb+ (intermediates missing) → walks up to the
    #    deepest existing parent inside a root → returns the intended new
    #    path (caller +mkdir_p+s the parent before writing).
    # 3. +lib/../../etc/passwd+ (+..+ escape) → +cleanpath+ collapses +..+
    #    syntactically, walks land outside every root → {Error}.
    # 4. +link/foo.rb+ where +link → /etc+ (symlink escape) → walks to
    #    +link+ (which exists), +realpath+ resolves through the symlink to
    #    +/etc+, outside every root → {Error}.
    #
    # Pure lexical normalization (+cleanpath+ + prefix check) catches cases
    # 1–3 but misses case 4. The walk-up +realpath+ pass closes that gap.
    #
    # == Project-root denylist
    #
    # Setting +project_root+ to a system root or a user's home directory
    # is almost always a misconfiguration: it makes the entire system or
    # home tree writable. The constructor rejects {DENIED_PROJECT_ROOTS}
    # (system tops: +/+, +/etc+, +/var+, …) and any directory whose
    # parent is +/home+ (catches +/home/$USER+ and +/home/$OTHER_USER+).
    # This is a sanity guard against fat-fingering, not a security
    # perimeter — the real security is the +readable+/+writable+ lists.
    # Other-OS home roots (+/Users/$USER+ on macOS) are not denied;
    # Linux-first per +CLAUDE.md+.
    class Filesystem
      # Raised for any path that resolves outside the workspace. Recoverable
      # at the tool layer — tools rescue this and emit +"Error: ..."+
      # observations so the LLM can self-correct on the next turn. Also
      # raised at construction time for a denied project root.
      class Error < StandardError; end

      # Umbrella dirs older than this are reaped by
      # {.sweep_stale_internal_temps!} at gem load. Generous enough
      # that a long-lived pikuri session in another shell isn't
      # disturbed; tight enough that a process killed last week
      # doesn't leak forever.
      INTERNAL_TEMP_STALE_SECONDS = 7 * 24 * 60 * 60

      # System-root project_roots the constructor refuses. Exact-match
      # (not prefix) — +/home/user/project+ passes, +/home/user+ is
      # rejected by the parent-is-/home check below. Frozen list;
      # downstream hosts with unusual layouts can subclass if they
      # really need a different policy.
      DENIED_PROJECT_ROOTS = %w[
        / /etc /var /proc /sys /dev /boot /root
        /usr /opt /lib /lib64 /bin /sbin /tmp
      ].map { |p| Pathname.new(p) }.freeze

      # @return [Pathname] project root, post-realpath. The writable
      #   containment ceiling, the base for relative-path resolution,
      #   and the chdir target for Bash/Grep/Glob — always in
      #   {#readable} and {#writable}.
      attr_reader :project_root

      # @return [Array<Pathname>] read-only roots (in addition to writable
      #   ones, which are also readable). Post-realpath, deduped.
      attr_reader :readable

      # @return [Array<Pathname>] writable roots (read+write). Includes
      #   {#project_root} and, if +temp: true+, {#temp}. Post-realpath,
      #   deduped.
      attr_reader :writable

      # @return [Pathname, nil] the LLM-visible scratch playground
      #   (writable, owned by this workspace) when constructed with
      #   +temp: true+, else +nil+. Lives at +<internal_temp>/playground+;
      #   removed transitively when the umbrella is wiped on process exit.
      attr_reader :temp

      # @param project_root [String, Pathname] absolute (or working-
      #   directory-relative) path to the project root. +realpath+'d
      #   once; must exist; must not match {DENIED_PROJECT_ROOTS} or be
      #   a direct child of +/home+.
      # @param readable [Array<String, Pathname>] additional read-only
      #   roots. +realpath+'d at construction; missing entries raise
      #   loudly via {Pathname#realpath}.
      # @param writable [Array<String, Pathname>] additional read+write
      #   roots. Same treatment as +readable+.
      # @param temp [Boolean] when +true+, adds
      #   +<internal_temp>/playground+ to {#writable} and exposes it
      #   via {#temp}. Forces the umbrella to mint up-front (the
      #   playground is created eagerly so {#writable} reflects it).
      # @param alias_tmp_to_temp [Boolean] when +true+ AND +temp:+ is
      #   set, +/tmp/*+ paths supplied to {#resolve_for_read} /
      #   {#resolve_for_write} are rewritten to point at {#temp}.
      #   Pairs with the bubblewrap sandbox's +--bind <temp> /tmp+.
      # @param env [Hash{String=>String}, nil] subprocess environment
      #   exposed via {#env}. +nil+ (default) → lazy-derive the host
      #   git identity from {#project_root} on first access; explicit
      #   hash → use verbatim (and skip the git lookup entirely). See
      #   the class header §"Subprocess environment" for the
      #   rationale.
      # @raise [Errno::ENOENT] if +project_root+ or any
      #   +readable+/+writable+ entry does not exist.
      # @raise [Error] if +project_root+ is denied (system root or
      #   +/home/*+).
      def initialize(project_root:, readable: [], writable: [], temp: false, alias_tmp_to_temp: false, env: nil)
        @project_root = Pathname.new(project_root).realpath
        validate_project_root!(@project_root)

        @internal_temp = nil
        @temp = temp ? mint_playground : nil
        @alias_tmp_to_temp = alias_tmp_to_temp && !@temp.nil?
        @env_override = env

        @writable = ([@project_root] + writable.map { |p| Pathname.new(p).realpath } + [@temp].compact).uniq
        @readable = (@writable + readable.map { |p| Pathname.new(p).realpath }).uniq
      end

      # @return [Boolean] whether {#resolve_for_read} / {#resolve_for_write}
      #   rewrite +/tmp/*+ inputs to {#temp}.
      attr_reader :alias_tmp_to_temp

      # Environment variables for subprocesses spawned in this
      # workspace. Lazy, memoized, frozen.
      #
      # When the constructor received +env: nil+ (the default), the
      # first call here runs +git -C project_root config user.name+ +
      # +user.email+ once and returns +GIT_AUTHOR_*+ / +GIT_COMMITTER_*+
      # accordingly. When the constructor received an explicit hash,
      # this returns that hash (frozen) and never shells out. Returns
      # +{}+ if git resolution finds no identity for {#project_root}
      # or +git+ isn't on +PATH+.
      #
      # @return [Hash{String=>String}]
      def env
        @env ||= (@env_override || compute_git_identity_env).freeze
      end

      # Per-workspace ephemeral umbrella. Minted lazily on first call
      # under {Paths::cache}. Registered with {Pikuri::Finalizers} for
      # removal the moment it's minted, so anything subsequently placed inside
      # (the playground, {Pikuri::Code::Bash::Sandbox::Bubblewrap}'s
      # overlay state) gets wiped together. Callers that want
      # ephemeral state owned by the workspace should put it under
      # this dir rather than minting their own siblings.
      #
      # @return [Pathname]
      def internal_temp
        @internal_temp ||= Filesystem.mint_internal_temp
      end

      # @api private — minting helper shared with {AllowAll}.
      # Registers umbrella removal with {Pikuri::Finalizers} (block
      # form — the umbrella is a dir to wipe, not a closeable object)
      # rather than its own +at_exit+, so process teardown stays on the
      # one registry. The +path.exist?+ guard makes the removal a no-op
      # when the dir is already gone (test cleanup, manual rm).
      def self.mint_internal_temp
        FileUtils.mkdir_p(Paths.cache)
        path = Pathname.new(Dir.mktmpdir('workspace-', Paths.cache)).realpath
        Pikuri::Finalizers.register { FileUtils.remove_entry(path.to_s) if path.exist? }
        path
      end

      # Reap +workspace-*+ umbrella dirs that have outlived
      # {INTERNAL_TEMP_STALE_SECONDS}. Called once at gem load via
      # {Pikuri::Workspace} so each process boot inherits a tidy
      # {Paths::cache}. Failures (permission denied, racing concurrent
      # sweeper) are swallowed — best-effort cleanup; the
      # {Pikuri::Finalizers} removal is the load-bearing path.
      #
      # @return [void]
      def self.sweep_stale_internal_temps!
        return unless File.directory?(Paths.cache)

        cutoff = Time.now - INTERNAL_TEMP_STALE_SECONDS
        Dir.children(Paths.cache).each do |entry|
          next unless entry.start_with?('workspace-')
          path = File.join(Paths.cache, entry)
          next unless File.directory?(path)
          next if File.mtime(path) > cutoff

          FileUtils.remove_entry(path)
        rescue StandardError
          # best-effort sweep; never block the host on dead state
        end
      end

      # Resolve a user-supplied path against the read-set (readable ∪
      # writable). Returned Pathname is absolute and may not exist on
      # disk; the caller validates existence separately.
      #
      # @param path [String]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every root
      def resolve_for_read(path)
        resolve(path, @readable)
      end

      # Resolve a user-supplied path against the write-set.
      #
      # @param path [String]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every writable root
      def resolve_for_write(path)
        resolve(path, @writable)
      end

      private

      # Eager-create +<internal_temp>/playground+. Used only when
      # +temp: true+; touches {#internal_temp} so the umbrella is
      # minted now (the playground needs a parent dir to live under
      # AND has to be in {#writable} by the end of +initialize+).
      def mint_playground
        path = internal_temp + 'playground'
        FileUtils.mkdir_p(path)
        path.realpath
      end

      def validate_project_root!(canonical)
        if DENIED_PROJECT_ROOTS.include?(canonical) || canonical.parent.to_s == '/home'
          raise Error,
                "project_root '#{canonical}' is a system or home root; the workspace " \
                'project_root must be a project subdirectory (a system or home root would expose ' \
                'the entire tree as writable).'
        end
      end

      # See the class header for the algorithm rationale.
      def resolve(path, roots)
        path = apply_tmp_alias(path)
        pn = Pathname.new(path)
        pn = @project_root + pn unless pn.absolute?
        cleaned = pn.cleanpath

        existing = cleaned
        existing = existing.parent until existing.exist? || existing.parent == existing
        base = existing.realpath

        matched = roots.find { |r| base == r || base.to_s.start_with?(r.to_s + File::SEPARATOR) }
        unless matched
          raise Error, "path '#{path}' is outside the workspace " \
                       "(roots: #{roots.map(&:to_s).join(', ')})"
        end

        base + cleaned.relative_path_from(existing)
      end

      # Resolve the host's effective git identity for {#project_root}
      # via +git -C project_root config+ — runs git's full chain
      # (system → global → includeIf → per-repo), so what comes back
      # is what +git commit+ would attribute to on the host outside
      # the sandbox. +Errno::ENOENT+ (no +git+ on +PATH+) and a
      # non-zero exit (no value configured) both fall back to a nil
      # entry; an empty identity field is treated the same. Result:
      # either the full four-entry hash or +{}+.
      def compute_git_identity_env
        name  = git_config('user.name')
        email = git_config('user.email')
        return {} if name.nil? || name.empty? || email.nil? || email.empty?

        {
          'GIT_AUTHOR_NAME'     => name,
          'GIT_AUTHOR_EMAIL'    => email,
          'GIT_COMMITTER_NAME'  => name,
          'GIT_COMMITTER_EMAIL' => email
        }
      end

      def git_config(key)
        result = Pikuri::Subprocess.spawn(
          'git', '-C', @project_root.to_s, 'config', key,
          chdir: @project_root.to_s
        ).wait
        result.status.success? ? result.output.strip : nil
      rescue Errno::ENOENT
        nil
      end

      # Rewrite +/tmp+ / +/tmp/foo+ inputs to land under {#temp} when
      # {#alias_tmp_to_temp} is set. Other inputs pass through. Lives
      # in the base class so {AllowAll} inherits identical behavior.
      def apply_tmp_alias(path)
        return path unless @alias_tmp_to_temp
        return @temp.to_s if path == '/tmp'
        return File.join(@temp.to_s, path[5..]) if path.start_with?('/tmp/')

        path
      end

      # Unrestricted variant of {Filesystem}: every path resolves, with one
      # carve-out — paths under the +denylist:+ (default
      # {DEFAULT_CREDENTIAL_DENYLIST}: the user's +~/.ssh+, +~/.aws+,
      # +~/.gnupg+, +~/.docker+, +~/.kube+, +~/.netrc+, and +/etc/shadow+)
      # still raise. Intended for dev-container / Docker
      # mode where the container is the security boundary; the denylist
      # remains as defense-in-depth against prompt-injection exfiltration
      # of credentials that are commonly bind-mounted into a container
      # from the host. Pairs naturally with +--yolo+ (no Confirmer
      # prompt) — but note that combining with
      # +Code::Bash::Sandbox::Bubblewrap+ defeats the sandbox (the
      # whole filesystem ends up bind-mounted in), and bash inside
      # the sandbox bypasses the denylist anyway, so the intended
      # combo is ALLOW_ALL + +Sandbox::NONE+ inside a container.
      #
      # == Project root, temp
      #
      # +project_root:+ is still accepted for parity with {Filesystem},
      # even though it's not a real containment ceiling under AllowAll.
      # It is NOT validated against {DENIED_PROJECT_ROOTS} (passing
      # +'/'+ is legitimate inside a container). It still serves as the
      # base for relative-path resolution and the chdir target tools
      # like Bash use. +temp:+ behaves the same way as {Filesystem}.
      #
      # == Denylist semantics
      #
      # Each entry is realpath'd lazily at check time when it exists
      # (so a symlink at e.g. +/tmp/decoy → ~/.ssh/id_rsa+ still gets
      # caught — the resolved path lands under +~/.ssh+). Non-existent
      # entries fall back to a literal-prefix match — blocks the agent
      # from *creating* a credential dir the user doesn't have yet (e.g.
      # planting +~/.gnupg+ for a later GPG operation to pick up). The
      # list is a constructor parameter (+denylist:+, default
      # {DEFAULT_CREDENTIAL_DENYLIST}); pass a reduced or empty list to
      # widen access — but only behind an outer egress boundary, since
      # bash bypasses this denylist anyway (see the header). Prefer the
      # parameter over subclassing — composition over inheritance.
      class AllowAll < Filesystem
        # Default credential floor: locations even ALLOW_ALL refuses,
        # for both reads and writes. This is the *default* value of the
        # +denylist:+ constructor parameter, so an unconfigured
        # AllowAll is safe out of the box; a caller widens access only by
        # explicitly passing a smaller (or empty) list. Expanded via
        # +ENV['HOME']+ at class-load time and unioned with the +/root+
        # variants (dev-container default user). Frozen.
        DEFAULT_CREDENTIAL_DENYLIST = begin
          homes = [ENV.fetch('HOME', nil), '/root'].compact.uniq
          per_home = %w[.ssh .aws .gnupg .docker .kube .netrc]
          user_paths = homes.flat_map { |h| per_home.map { |p| File.join(h, p) } }
          (user_paths + %w[/etc/shadow]).map { |p| Pathname.new(p) }.uniq.freeze
        end

        # @param project_root [String, Pathname] surface-level project
        #   root. Not validated against {DENIED_PROJECT_ROOTS}.
        # @param temp [Boolean] same semantics as {Filesystem}.
        # @param alias_tmp_to_temp [Boolean] same semantics as
        #   {Filesystem} — when +true+ AND +temp:+ is set, +/tmp/*+
        #   inputs rewrite to land under {#temp}.
        # @param env [Hash{String=>String}, nil] same semantics as
        #   {Filesystem}; see {Filesystem#env}.
        # @param denylist [Array<String, Pathname>] paths this
        #   filesystem refuses to resolve for read *or* write
        #   (symlink-resolved descendant match). Defaults to
        #   {DEFAULT_CREDENTIAL_DENYLIST}. Pass a reduced list — or +[]+ —
        #   ONLY when an outer boundary makes reaching secrets acceptable
        #   (kernel-severed / user-confirmed egress, or a container);
        #   emptying it without such a boundary re-opens credential
        #   exfiltration.
        def initialize(project_root: Dir.pwd, temp: false, alias_tmp_to_temp: false,
                       env: nil, denylist: DEFAULT_CREDENTIAL_DENYLIST)
          @project_root = Pathname.new(project_root).realpath

          @internal_temp = nil
          @temp = temp ? mint_playground : nil
          @alias_tmp_to_temp = alias_tmp_to_temp && !@temp.nil?
          @env_override = env
          @denylist = denylist.map { |p| Pathname.new(p) }.uniq.freeze

          # Advertise "everything is in scope" via the accessor surface so
          # callers that inspect +readable+/+writable+ (system-prompt
          # rendering, Bubblewrap bind-mount construction) see the
          # intended semantics. The actual containment is the denylist
          # in {#resolve_for_read}/{#resolve_for_write}.
          @writable = [Pathname.new('/').realpath, @temp].compact.uniq
          @readable = @writable.dup
        end

        # @param path [String]
        # @return [Pathname]
        # @raise [Error] if the resolved path lands under the credential denylist.
        def resolve_for_read(path)
          resolve_unrestricted(path)
        end

        # @param path [String]
        # @return [Pathname]
        # @raise [Error] if the resolved path lands under the credential denylist.
        def resolve_for_write(path)
          resolve_unrestricted(path)
        end

        private

        def resolve_unrestricted(path)
          path = apply_tmp_alias(path)
          pn = Pathname.new(path)
          pn = @project_root + pn unless pn.absolute?
          cleaned = pn.cleanpath

          existing = cleaned
          existing = existing.parent until existing.exist? || existing.parent == existing
          base = existing.realpath
          resolved = base + cleaned.relative_path_from(existing)

          @denylist.each do |denied|
            candidate = denied.exist? ? denied.realpath : denied
            next unless resolved == candidate ||
                        resolved.to_s.start_with?(candidate.to_s + File::SEPARATOR)

            raise Error,
                  "path '#{path}' resolves under a denied credential location " \
                  "('#{denied}') — this AllowAll's denylist blocks it. " \
                  'Reduce denylist: only behind an outer egress boundary.'
          end

          resolved
        end
      end
    end
  end
end
