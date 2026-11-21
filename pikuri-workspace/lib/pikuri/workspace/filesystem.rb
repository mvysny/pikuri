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
    # +root_writable: false+ makes the project root read-only, so paths still
    # resolve against one base while writes land only in the +writable+ list:
    #
    #   Filesystem.new(project_root: '~/Documents', root_writable: false,
    #                  writable: ['~/Documents/Notes'])
    #   # read('Finance/invoice.pdf') ok; write('Notes/x.md') ok; write('x.md') refused
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

      # @return [Pathname] project root, post-realpath — the containment
      #   ceiling, relative-path base, and shell/Grep/Glob chdir target;
      #   always in {#readable}, in {#writable} unless +root_writable: false+.
      attr_reader :project_root

      # @return [Array<Pathname>] read-only roots (writable roots are also
      #   readable). Post-realpath, deduped.
      attr_reader :readable

      # @return [Array<Pathname>] writable roots (read+write); includes
      #   {#project_root} unless +root_writable: false+. Post-realpath, deduped.
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
      # The claim covers the tool's *entire* reachable set — a vouched-for island
      # inside a broad root buys nothing, since the tool can still reach
      # everything else — so +trusted: true+ refuses any root outside
      # +project_root+: a +~/.m2+ cache or a home skill dir is somebody else's
      # bytes.
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
      # @param root_writable [Boolean] +false+ keeps +project_root+ read-only;
      #   writes then land only under +writable+.
      # @param private [Boolean] these roots may hold sensitive data; see
      #   {#private?}.
      # @param trusted [Boolean] every byte under these roots is user-authored;
      #   see {#trusted?}.
      # @raise [Errno::ENOENT] if any of +project_root+/+readable+/+writable+
      #   doesn't exist.
      # @raise [Error] if +project_root+ is denied (system root or +/home/*+).
      # @raise [ArgumentError] if +trusted: true+ and a +readable+/+writable+
      #   root lies outside +project_root+.
      def initialize(project_root:, readable: [], writable: [], root_writable: true, private: false,
                     trusted: false)
        @project_root = Pathname.new(project_root).realpath
        validate_project_root!(@project_root)

        @private = private
        @trusted = trusted

        @writable = ((root_writable ? [@project_root] : []) + writable.map { |p| Pathname.new(p).realpath }).uniq
        @readable = ([@project_root] + @writable + readable.map { |p| Pathname.new(p).realpath }).uniq
        validate_trusted_roots! if trusted
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
      # always +false+ here; a whole-host subclass with a credential denylist
      # overrides it, symlink-resolving +path+ first so a +decoy → ~/.ssh+
      # link inside the workspace is caught.
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

      def validate_trusted_roots!
        stray = @readable.reject { |r| r.ascend.include?(@project_root) }
        return if stray.empty?

        raise ArgumentError,
              "trusted: true vouches for every byte the tools can reach, but #{stray.map(&:to_s).join(', ')} " \
              "lies outside project_root '#{@project_root}'; scope the workspace to one root, or drop trusted:"
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

        # Component-wise, not a string-prefix test against +root + "/"+: that
        # one turns a +/+ root into +"//"+ and matches nothing beneath it.
        unless roots.any? { |r| base.ascend.include?(r) }
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
    end
  end
end
