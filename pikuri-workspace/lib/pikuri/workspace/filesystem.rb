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
    # == Optional temp playground
    #
    # When constructed with +temp: true+, the workspace mints its own
    # ephemeral directory via {Dir.mktmpdir} and adds it to +writable+.
    # An +at_exit+ handler removes it when the process exits. {#temp}
    # exposes the path so the binary can advertise it to the LLM (e.g.
    # in the system prompt). Default is +false+: specs and tests that
    # build many workspaces don't pay the mktmpdir cost, and hosts that
    # don't need a playground don't get one.
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

      # @return [Pathname, nil] the ephemeral playground (writable, owned
      #   by this workspace) when constructed with +temp: true+, else
      #   +nil+. Removed via +at_exit+ on process exit.
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
      # @param temp [Boolean] when +true+, mints an ephemeral
      #   {Dir.mktmpdir}, adds it to +writable+, exposes via {#temp},
      #   registers +at_exit+ cleanup.
      # @raise [Errno::ENOENT] if +project_root+ or any
      #   +readable+/+writable+ entry does not exist.
      # @raise [Error] if +project_root+ is denied (system root or
      #   +/home/*+).
      def initialize(project_root:, readable: [], writable: [], temp: false)
        @project_root = Pathname.new(project_root).realpath
        validate_project_root!(@project_root)

        @temp = temp ? Pathname.new(Dir.mktmpdir('pikuri-temp-')).realpath : nil
        at_exit { FileUtils.remove_entry(@temp.to_s) if @temp && @temp.exist? } if @temp

        @writable = ([@project_root] + writable.map { |p| Pathname.new(p).realpath } + [@temp].compact).uniq
        @readable = (@writable + readable.map { |p| Pathname.new(p).realpath }).uniq
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

      # Unrestricted variant of {Filesystem}: every path resolves, with one
      # carve-out — paths under {CREDENTIAL_DENYLIST} (the user's +~/.ssh+,
      # +~/.aws+, +~/.gnupg+, +~/.docker+, +~/.kube+, +~/.netrc+, and
      # +/etc/shadow+) still raise. Intended for dev-container / Docker
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
      # list is hardcoded; subclass for a host with a different policy.
      class AllowAll < Filesystem
        # Credential locations that even ALLOW_ALL refuses. Expanded
        # via +ENV['HOME']+ at class-load time and unioned with the
        # +/root+ variants (dev-container default user). Frozen.
        CREDENTIAL_DENYLIST = begin
          homes = [ENV.fetch('HOME', nil), '/root'].compact.uniq
          per_home = %w[.ssh .aws .gnupg .docker .kube .netrc]
          user_paths = homes.flat_map { |h| per_home.map { |p| File.join(h, p) } }
          (user_paths + %w[/etc/shadow]).map { |p| Pathname.new(p) }.uniq.freeze
        end

        # @param project_root [String, Pathname] surface-level project
        #   root. Not validated against {DENIED_PROJECT_ROOTS}.
        # @param temp [Boolean] same semantics as {Filesystem}.
        def initialize(project_root: Dir.pwd, temp: false)
          @project_root = Pathname.new(project_root).realpath

          @temp = temp ? Pathname.new(Dir.mktmpdir('pikuri-temp-')).realpath : nil
          at_exit { FileUtils.remove_entry(@temp.to_s) if @temp && @temp.exist? } if @temp

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
        # @raise [Error] if the resolved path lands under {CREDENTIAL_DENYLIST}.
        def resolve_for_read(path)
          resolve_unrestricted(path)
        end

        # @param path [String]
        # @return [Pathname]
        # @raise [Error] if the resolved path lands under {CREDENTIAL_DENYLIST}.
        def resolve_for_write(path)
          resolve_unrestricted(path)
        end

        private

        def resolve_unrestricted(path)
          pn = Pathname.new(path)
          pn = @project_root + pn unless pn.absolute?
          cleaned = pn.cleanpath

          existing = cleaned
          existing = existing.parent until existing.exist? || existing.parent == existing
          base = existing.realpath
          resolved = base + cleaned.relative_path_from(existing)

          CREDENTIAL_DENYLIST.each do |denied|
            candidate = denied.exist? ? denied.realpath : denied
            next unless resolved == candidate ||
                        resolved.to_s.start_with?(candidate.to_s + File::SEPARATOR)

            raise Error,
                  "path '#{path}' resolves under a denied credential location " \
                  "('#{denied}') — even in ALLOW_ALL mode, ~/.ssh / ~/.aws / " \
                  '~/.gnupg / ~/.docker / ~/.kube / ~/.netrc / /etc/shadow ' \
                  'are off-limits.'
          end

          resolved
        end
      end
    end
  end
end
