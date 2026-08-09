# frozen_string_literal: true

require 'pathname'
require 'fileutils'

module Pikuri
  module Workspace
    # Defines which paths the agent can see and write to. Constructed with
    # explicit +readable+/+writable+ prefix lists; every Read/Write/Edit/Grep/
    # Glob/Bash path is checked against them before touching disk. Returned
    # Pathnames are absolute, post-symlink-resolution.
    #
    # == Project root, readable, writable
    #
    # +project_root+ is the writable containment ceiling — auto-folded into both
    # +readable+ and +writable+ (read/write anywhere under it), the base for
    # resolving relative LLM paths, and the chdir target for {Bash}/{Grep}/
    # {Glob}. There is no separate "cwd": a host wanting the agent in a subtree
    # passes that subtree as +project_root+ (+bin/pikuri-code+ also +Dir.chdir+s
    # the process there so process and workspace share one anchor). The extra
    # +readable+ list grants read-only roots (toolchains, caches); the extra
    # +writable+ list grants read+write roots.
    #
    # {#resolve_for_read} checks +readable ∪ writable+; {#resolve_for_write}
    # checks +writable+ only. Neither checks existence — the workspace owns
    # *containment*, not filesystem state (Read errors on a missing file, Write
    # +mkdir_p+s its own parents).
    #
    # == Session umbrella ({#internal_temp})
    #
    # Every workspace owns a per-process umbrella dir, minted lazily (workspaces
    # that never touch it pay nothing) as a {Pikuri::Paths.new_temp} — so it
    # lands under +~/.cache/pikuri+ (NOT +/tmp+: the sandbox binds {#temp} at
    # +/tmp+ inside, and an umbrella already there would bind on top of itself),
    # is removed at exit via {Pikuri::Finalizers}, and is stale-swept by
    # {Pikuri::Paths.sweep_stale_temps!} at core load. Everything ephemeral lives
    # inside it — the {#temp} playground, the Bubblewrap sandbox's per-toolchain
    # overlay state — so one +remove_entry+ cleans the lot.
    #
    # == Optional temp playground / /tmp alias
    #
    # +temp: true+ adds +<internal_temp>/playground+ to {#writable}, exposed via
    # {#temp} as LLM scratch space (default +false+ so specs don't pay the
    # mkdir). +alias_tmp_to_temp: true+ (only with +temp:+) rewrites +/tmp/*+
    # inputs to {#temp} before containment — the host-side counterpart to the
    # sandbox's +--bind <temp> /tmp+, so the LLM uses one path for both.
    # +bin/pikuri-code+ flips it on with the bubblewrap sandbox.
    #
    # == Subprocess environment ({#env})
    #
    # Workspaces own an {#env} hash that subprocess tools ({Pikuri::Code::Bash})
    # thread into {Pikuri::Subprocess.spawn}. Motivating case: the bubblewrap
    # sandbox doesn't bind +~/.gitconfig+, so +git commit+ inside fails; the
    # workspace resolves the host's effective git identity at {#project_root}
    # (so +includeIf+ rules apply) and exposes +GIT_AUTHOR_*+/+GIT_COMMITTER_*+
    # that override config with no file in the sandbox. Lazy + memoized (the
    # constructor doesn't shell out), falling back to +{}+ if git isn't on PATH
    # or no identity is configured. An explicit +env:+ is used verbatim, skipping
    # the lookup. Always frozen on the way out.
    #
    # == Containment algorithm
    #
    # {#resolve} walks up the input to its deepest existing ancestor,
    # +realpath+s that (resolving symlinks in the existing portion), and checks
    # the resolved base against the candidate roots:
    #
    # 1. +lib/foo.rb+ (exists) → base matches a root → realpath'd file.
    # 2. +lib/new/dir/foo.rb+ (intermediates missing) → deepest existing parent
    #    in a root → the intended new path (caller +mkdir_p+s).
    # 3. +lib/../../etc/passwd+ (+..+ escape) → +cleanpath+ collapses +..+, lands
    #    outside every root → {Error}.
    # 4. +link/foo.rb+, +link → /etc+ (symlink escape) → +realpath+ resolves
    #    through the link to +/etc+, outside every root → {Error}.
    #
    # Lexical normalization alone catches 1–3 but misses 4; the walk-up
    # +realpath+ closes that gap.
    #
    # == Project-root denylist
    #
    # A +project_root+ of a system root or home dir makes the whole tree
    # writable — almost always a fat-finger. The constructor rejects
    # {DENIED_PROJECT_ROOTS} and any direct child of +/home+. A sanity guard,
    # not a security perimeter (the +readable+/+writable+ lists are that).
    # Linux-first: other-OS home roots (+/Users/$USER+) aren't denied.
    class Filesystem
      # Raised for any path resolving outside the workspace. Recoverable at the
      # tool layer (tools rescue it into +"Error: ..."+ observations). Also
      # raised at construction for a denied project root.
      class Error < StandardError; end

      # System-root project_roots the constructor refuses (exact-match, not
      # prefix — +/home/user/project+ passes; +/home/user+ is caught by the
      # parent-is-/home check). Downstream hosts with unusual layouts can
      # subclass.
      DENIED_PROJECT_ROOTS = %w[
        / /etc /var /proc /sys /dev /boot /root
        /usr /opt /lib /lib64 /bin /sbin /tmp
      ].map { |p| Pathname.new(p) }.freeze

      # @return [Pathname] project root, post-realpath — the writable
      #   containment ceiling, relative-path base, and Bash/Grep/Glob chdir
      #   target; always in {#readable}/{#writable}.
      attr_reader :project_root

      # @return [Array<Pathname>] read-only roots (writable roots are also
      #   readable). Post-realpath, deduped.
      attr_reader :readable

      # @return [Array<Pathname>] writable roots (read+write); includes
      #   {#project_root} and, with +temp: true+, {#temp}. Post-realpath, deduped.
      attr_reader :writable

      # Whether these roots may hold data worth exfiltrating — the lethal
      # trifecta's private leg, which the file tools inherit from here.
      #
      # The framework cannot answer this for you: sensitivity is a property of
      # the *data*, not of the tool, and +~/work/scratch+ and +~/work/payroll+
      # are indistinguishable from the outside. Declaring it is what lets
      # {Pikuri::Trifecta} stay quiet over a public checkout and speak up over
      # your real one.
      #
      # @return [Boolean] default +false+
      def private? = @private

      # Whether every byte reachable here is user-authored — the opt-out from
      # the file tools' default +:hard+ untrusted leg.
      #
      # Default +false+, because broad disk access means cloned dependencies,
      # fetched PR branches, saved downloads and package caches: attacker-authored
      # bytes are the norm, and a hostile README reaches the model verbatim.
      # Claim it only when the trusted area is the tool's *entire* reachable set
      # — a vouched-for island inside a broad root buys nothing, since the tool
      # can still reach everything else. That is why {AllowAll} refuses the flag
      # outright rather than merely discouraging it.
      #
      # Distinct from the trust-this-directory question a host may ask at boot:
      # that one asks whether a hostile +.gitattributes+ can *execute code*, this
      # one whether the repo's *bytes* are attacker-authored. A repo routinely
      # passes the first and fails the second — you control +.git/config+;
      # +vendor/+ is someone else's.
      #
      # @return [Boolean] default +false+
      def trusted? = @trusted

      # @return [Pathname, nil] the LLM-visible scratch playground (writable, at
      #   +<internal_temp>/playground+) when +temp: true+, else +nil+; wiped with
      #   the umbrella at exit.
      attr_reader :temp

      # @param project_root [String, Pathname] project root; +realpath+'d once,
      #   must exist, must not match {DENIED_PROJECT_ROOTS} or be a +/home+ child.
      # @param readable [Array<String, Pathname>] extra read-only roots;
      #   +realpath+'d (missing entries raise).
      # @param writable [Array<String, Pathname>] extra read+write roots; same.
      # @param temp [Boolean] +true+ adds +<internal_temp>/playground+ to
      #   {#writable} and exposes it via {#temp} (minting the umbrella up-front).
      # @param alias_tmp_to_temp [Boolean] +true+ (with +temp:+) rewrites +/tmp/*+
      #   inputs to {#temp}; pairs with the sandbox's +--bind <temp> /tmp+.
      # @param env [Hash{String=>String}, nil] subprocess env via {#env}; +nil+
      #   lazy-derives host git identity from {#project_root}, an explicit hash
      #   is used verbatim (see §"Subprocess environment").
      # @param private [Boolean] these roots may hold sensitive data; see
      #   {#private?}.
      # @param trusted [Boolean] every byte under these roots is user-authored;
      #   see {#trusted?}.
      # @raise [Errno::ENOENT] if any of +project_root+/+readable+/+writable+
      #   doesn't exist.
      # @raise [Error] if +project_root+ is denied (system root or +/home/*+).
      def initialize(project_root:, readable: [], writable: [], temp: false, alias_tmp_to_temp: false, env: nil,
                     private: false, trusted: false)
        @project_root = Pathname.new(project_root).realpath
        validate_project_root!(@project_root)

        @private = private
        @trusted = trusted

        @internal_temp = nil
        @temp = temp ? mint_playground : nil
        @alias_tmp_to_temp = alias_tmp_to_temp && !@temp.nil?
        @env_override = env

        @writable = ([@project_root] + writable.map { |p| Pathname.new(p).realpath } + [@temp].compact).uniq
        @readable = (@writable + readable.map { |p| Pathname.new(p).realpath }).uniq
      end

      # @return [Boolean] whether {#resolve_for_read}/{#resolve_for_write} rewrite
      #   +/tmp/*+ inputs to {#temp}.
      attr_reader :alias_tmp_to_temp

      # Environment variables for subprocesses spawned in this workspace. Lazy,
      # memoized, frozen. With +env: nil+ the first call resolves the host git
      # identity for {#project_root} (+GIT_AUTHOR_*+/+GIT_COMMITTER_*+, or +{}+
      # if none / no git); an explicit hash is returned frozen without shelling
      # out. See §"Subprocess environment".
      #
      # @return [Hash{String=>String}]
      def env
        @env ||= (@env_override || compute_git_identity_env).freeze
      end

      # Per-workspace ephemeral umbrella, minted lazily as a fresh
      # {Pikuri::Paths.new_temp} (reaped at exit, stale-swept at core load) — so
      # anything placed inside (the playground, Bubblewrap overlay state) is
      # wiped together. Put workspace-owned ephemeral state here, not in a
      # sibling.
      #
      # @return [Pathname]
      def internal_temp
        @internal_temp ||= Paths.new_temp
      end

      # Resolve a user path against the read-set (readable ∪ writable). Returned
      # Pathname is absolute and may not exist; the caller checks existence.
      #
      # @param path [String]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every root
      def resolve_for_read(path)
        resolve(path, @readable)
      end

      # Resolve a user path against the write-set.
      #
      # @param path [String]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every writable root
      def resolve_for_write(path)
        resolve(path, @writable)
      end

      private

      # Eager-create +<internal_temp>/playground+ (only when +temp: true+):
      # touches {#internal_temp} so the umbrella mints now, since the playground
      # must be in {#writable} by the end of +initialize+.
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

      # Resolve the host's effective git identity for {#project_root} via
      # +git -C project_root config+ — git's full chain (system → global →
      # includeIf → per-repo), so it matches what +git commit+ attributes on
      # the host. No git on PATH, a non-zero exit, or an empty field all fall
      # back to +{}+; otherwise the full four-entry hash.
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
      # {#alias_tmp_to_temp} is set; other inputs pass through. In the base
      # class so {AllowAll} inherits it.
      def apply_tmp_alias(path)
        return path unless @alias_tmp_to_temp
        return @temp.to_s if path == '/tmp'
        return File.join(@temp.to_s, path[5..]) if path.start_with?('/tmp/')

        path
      end

      # Unrestricted variant of {Filesystem}: every path resolves, except paths
      # under +denylist:+ (default {DEFAULT_CREDENTIAL_DENYLIST} — +~/.ssh+,
      # +~/.aws+, +~/.gnupg+, +~/.docker+, +~/.kube+, +~/.netrc+, +/etc/shadow+)
      # still raise. For dev-container / Docker mode where the container is the
      # boundary; the denylist is defense-in-depth against prompt-injected
      # exfiltration of host credentials bind-mounted in. Pairs with +--yolo+
      # (no Confirmer) — but combining with +Code::Bash::Sandbox::Bubblewrap+
      # defeats the sandbox (the whole fs ends up bound in), and bash inside the
      # sandbox bypasses the denylist anyway, so the intended combo is ALLOW_ALL
      # + +Sandbox::NONE+ inside a container.
      #
      # +project_root:+ is accepted for parity but is not a containment ceiling
      # and is NOT validated against {DENIED_PROJECT_ROOTS} (+'/'+ is legitimate
      # in a container); it still anchors relative paths and the chdir target.
      # +temp:+ behaves as in {Filesystem}.
      #
      # == Denylist semantics
      #
      # Each entry is realpath'd lazily at check time when it exists (so a
      # symlink +/tmp/decoy → ~/.ssh/id_rsa+ is caught), else falls back to a
      # literal-prefix match (blocks the agent *creating* a credential dir the
      # user lacks). Pass a reduced or empty +denylist:+ to widen access — but
      # only behind an outer egress boundary, since bash bypasses it anyway.
      # Prefer the parameter over subclassing.
      class AllowAll < Filesystem
        # Default credential floor even ALLOW_ALL refuses (read and write) — the
        # default +denylist:+, so an unconfigured AllowAll is safe out of the
        # box; widen only by explicitly passing a smaller list. Expanded via
        # +ENV['HOME']+ at load, unioned with the +/root+ variants (dev-container
        # default user). Frozen.
        DEFAULT_CREDENTIAL_DENYLIST = begin
          homes = [ENV.fetch('HOME', nil), '/root'].compact.uniq
          per_home = %w[.ssh .aws .gnupg .docker .kube .netrc]
          user_paths = homes.flat_map { |h| per_home.map { |p| File.join(h, p) } }
          (user_paths + %w[/etc/shadow]).map { |p| Pathname.new(p) }.uniq.freeze
        end

        # @param project_root [String, Pathname] surface-level root; not
        #   validated against {DENIED_PROJECT_ROOTS}.
        # @param temp [Boolean] as in {Filesystem}.
        # @param alias_tmp_to_temp [Boolean] as in {Filesystem} (with +temp:+,
        #   +/tmp/*+ inputs rewrite to {#temp}).
        # @param env [Hash{String=>String}, nil] as in {Filesystem#env}.
        # @param denylist [Array<String, Pathname>] paths refused for read or
        #   write (symlink-resolved descendant match); default
        #   {DEFAULT_CREDENTIAL_DENYLIST}. Reduce — or +[]+ — ONLY behind an
        #   outer boundary (kernel-severed/confirmed egress, or a container);
        #   emptying it without one re-opens credential exfiltration.
        # @param private [Boolean] as in {Filesystem#private?}. Accepted, and
        #   usually right: a whole-host workspace is exactly where someone means
        #   it.
        # @param trusted [Boolean] must be +false+; see {Filesystem#trusted?}.
        # @raise [ArgumentError] if +trusted: true+ — the flag cannot be honest
        #   when the reachable set is the whole host.
        def initialize(project_root: Dir.pwd, temp: false, alias_tmp_to_temp: false,
                       env: nil, denylist: DEFAULT_CREDENTIAL_DENYLIST,
                       private: false, trusted: false)
          # Unrepresentable rather than merely inadvisable: the reachable set is
          # the whole host, so no human can vouch for every byte in it.
          raise ArgumentError, 'trusted: is not representable on AllowAll — scope the workspace instead' if trusted

          @project_root = Pathname.new(project_root).realpath

          @private = private
          @trusted = false

          @internal_temp = nil
          @temp = temp ? mint_playground : nil
          @alias_tmp_to_temp = alias_tmp_to_temp && !@temp.nil?
          @env_override = env
          @denylist = denylist.map { |p| Pathname.new(p) }.uniq.freeze

          # Advertise "everything is in scope" via the accessor surface so
          # callers inspecting +readable+/+writable+ (prompt rendering, Bubblewrap
          # binds) see the intended semantics; actual containment is the denylist.
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
