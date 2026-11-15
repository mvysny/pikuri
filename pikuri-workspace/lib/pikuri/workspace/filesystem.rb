# frozen_string_literal: true

require 'pathname'

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
    # resolving relative LLM paths, and the chdir target for {Search::Grep},
    # {Search::Glob} and a co-wired shell. There is no separate "cwd": a host
    # wanting the agent in a subtree passes that subtree as +project_root+ (and
    # may +Dir.chdir+ the process there so process and workspace share one anchor). The extra
    # +readable+ list grants read-only roots (toolchains, caches); the extra
    # +writable+ list grants read+write roots.
    #
    # {#resolve_for_read} checks +readable ∪ writable+; {#resolve_for_write}
    # checks +writable+ only. Neither checks existence — the workspace owns
    # *containment*, not filesystem state (Read errors on a missing file, Write
    # +mkdir_p+s its own parents).
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
      #   containment ceiling, relative-path base, and shell/Grep/Glob chdir
      #   target; always in {#readable}/{#writable}.
      attr_reader :project_root

      # @return [Array<Pathname>] read-only roots (writable roots are also
      #   readable). Post-realpath, deduped.
      attr_reader :readable

      # @return [Array<Pathname>] writable roots (read+write); includes
      #   {#project_root}. Post-realpath, deduped.
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

      # @param project_root [String, Pathname] project root; +realpath+'d once,
      #   must exist, must not match {DENIED_PROJECT_ROOTS} or be a +/home+ child.
      # @param readable [Array<String, Pathname>] extra read-only roots;
      #   +realpath+'d (missing entries raise).
      # @param writable [Array<String, Pathname>] extra read+write roots; same.
      # @param private [Boolean] these roots may hold sensitive data; see
      #   {#private?}.
      # @param trusted [Boolean] every byte under these roots is user-authored;
      #   see {#trusted?}.
      # @raise [Errno::ENOENT] if any of +project_root+/+readable+/+writable+
      #   doesn't exist.
      # @raise [Error] if +project_root+ is denied (system root or +/home/*+).
      def initialize(project_root:, readable: [], writable: [], private: false, trusted: false)
        @project_root = Pathname.new(project_root).realpath
        validate_project_root!(@project_root)

        @private = private
        @trusted = trusted

        @writable = ([@project_root] + writable.map { |p| Pathname.new(p).realpath }).uniq
        @readable = (@writable + readable.map { |p| Pathname.new(p).realpath }).uniq
      end

      # Resolve a user path against the read-set (readable ∪ writable). Returned
      # Pathname is absolute and may not exist; the caller checks existence.
      #
      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every root
      def resolve_for_read(path)
        resolve(path, @readable)
      end

      # Resolve a user path against the write-set.
      #
      # @param path [String, Pathname]
      # @return [Pathname]
      # @raise [Error] if the resolved path falls outside every writable root
      def resolve_for_write(path)
        resolve(path, @writable)
      end

      # Whether +path+ sits under a credential denylist entry.
      #
      # {#resolve_for_read} gates a path the *model* supplied; this gates a
      # path a tool **walked** to on its own (a {Listing} row, an +rg+ hit),
      # which no +resolve_+ call ever sees. A scoped Filesystem has no
      # denylist — containment is the readable/writable ceiling — so this is
      # always +false+ here; {AllowAll} overrides it.
      #
      # @param path [String, Pathname]
      # @return [Boolean]
      def denied?(_path) = false

      # @return [Array<Pathname>] the denied roots, for callers that can prune
      #   a walk up front (+rg --glob '!…'+) instead of filtering its results.
      #   Empty here; see {#denied?}.
      def denied_roots = []

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
        path = expand_home(path)
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

      # Expand a leading +~+ / +~/+ to the home folder, as a shell would:
      #
      #   expand_home('~/.bashrc')   # => "/home/alex/.bashrc"
      #   expand_home('a/~/b')       # => "a/~/b"
      #
      # Models write +~/.bashrc+ out of shell habit; left alone it resolves to
      # +<project_root>/~/.bashrc+ and fails as *not found* instead of *outside
      # the workspace*, sending the model off on a detour. +~user+ is left
      # alone (Ruby's expansion of it raises on an unknown user).
      #
      # @param path [String, Pathname]
      # @return [String]
      def expand_home(path)
        path = path.to_s
        return Dir.home if path == '~'
        return File.join(Dir.home, path[2..]) if path.start_with?('~/')

        path
      end

      # Unrestricted variant of {Filesystem}: every path resolves, except paths
      # under +denylist:+ (default {DEFAULT_CREDENTIAL_DENYLIST} — +~/.ssh+,
      # +~/.aws+, +~/.gnupg+, +~/.docker+, +~/.kube+, +~/.netrc+, +/etc/shadow+)
      # still raise. For dev-container / Docker mode where the container is the
      # boundary; the denylist is defense-in-depth against prompt-injected
      # exfiltration of host credentials bind-mounted in. Pairs with +--yolo+
      # (no Confirmer) — but combining with a bubblewrap-sandboxed shell
      # defeats the sandbox (the whole fs ends up bound in), and a shell inside
      # the sandbox bypasses the denylist anyway, so the intended combo is
      # ALLOW_ALL with an unsandboxed shell inside a container.
      #
      # +project_root:+ is accepted for parity but is not a containment ceiling
      # and is NOT validated against {DENIED_PROJECT_ROOTS} (+'/'+ is legitimate
      # in a container); it still anchors relative paths and the chdir target.
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
        # Default credential floor even ALLOW_ALL refuses (read *and* write, and
        # {#denied?} for anything a tool walks to) — the default +denylist:+, so
        # an unconfigured AllowAll keeps its credential floor out of the box;
        # widen only by explicitly passing a smaller list. It is a floor, not a
        # boundary: a co-wired shell tool walks around it entirely. Expanded via
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
        def initialize(project_root: Dir.pwd, denylist: DEFAULT_CREDENTIAL_DENYLIST,
                       private: false, trusted: false)
          # Unrepresentable rather than merely inadvisable: the reachable set is
          # the whole host, so no human can vouch for every byte in it.
          raise ArgumentError, 'trusted: is not representable on AllowAll — scope the workspace instead' if trusted

          @project_root = Pathname.new(project_root).realpath

          @private = private
          @trusted = false

          @denylist = denylist.map { |p| Pathname.new(p) }.uniq.freeze

          # Advertise "everything is in scope" via the accessor surface so
          # callers inspecting +readable+/+writable+ (prompt rendering, Bubblewrap
          # binds) see the intended semantics; actual containment is the denylist.
          @writable = [Pathname.new('/').realpath]
          @readable = @writable.dup
        end

        # @param path [String, Pathname]
        # @return [Pathname]
        # @raise [Error] if the resolved path lands under the credential denylist.
        def resolve_for_read(path)
          resolve_unrestricted(path)
        end

        # @param path [String, Pathname]
        # @return [Pathname]
        # @raise [Error] if the resolved path lands under the credential denylist.
        def resolve_for_write(path)
          resolve_unrestricted(path)
        end

        # The walked-path gate (see {Filesystem#denied?}). Symlink-resolves
        # +path+ first, so a +decoy → ~/.ssh+ inside the workspace is caught
        # even though nothing ever handed it to a +resolve_+ call.
        #
        # @param path [String, Pathname]
        # @return [Boolean]
        def denied?(path)
          !denying_root(normalize(path)).nil?
        end

        # @return [Array<Pathname>]
        def denied_roots = @denylist

        private

        # @param resolved [Pathname] symlink-resolved absolute path
        # @return [Pathname, nil] the denylist entry containing +resolved+
        def denying_root(resolved)
          @denylist.find do |denied|
            candidate = denied.exist? ? denied.realpath : denied
            resolved == candidate ||
              resolved.to_s.start_with?(candidate.to_s + File::SEPARATOR)
          end
        end

        # @return [Pathname] symlink-resolved; falls back to a lexical cleanup
        #   for a path that doesn't exist (the agent creating a credential dir
        #   the user lacks must still be blocked).
        def normalize(path)
          Pathname.new(path).realpath
        rescue SystemCallError
          Pathname.new(path).expand_path.cleanpath
        end

        def resolve_unrestricted(path)
          path = expand_home(path)
          pn = Pathname.new(path)
          pn = @project_root + pn unless pn.absolute?
          cleaned = pn.cleanpath

          existing = cleaned
          existing = existing.parent until existing.exist? || existing.parent == existing
          base = existing.realpath
          resolved = base + cleaned.relative_path_from(existing)

          # +resolved+ is already realpath-based, so it goes to the shared
          # containment test directly rather than through {#denied?}.
          if (denied = denying_root(resolved))
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
