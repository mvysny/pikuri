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
    # == Anchor, readable, writable
    #
    # +anchor+ is the project root — where +Bash+ runs commands and where
    # +Glob+/+Grep+ chdir before invoking rg. It is automatically folded
    # into both +readable+ and +writable+; you can read and write the
    # project unconditionally. The extra +readable+ list grants read-only
    # access to additional roots (system toolchains, dependency caches,
    # skill catalogs); the extra +writable+ list grants read+write to
    # additional roots (other project directories the agent should be
    # able to touch).
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
    # portion), then verifies the resolved anchor matches one of the
    # candidate roots. Four cases:
    #
    # 1. +lib/foo.rb+ (exists) → +existing+ = full path, +anchor+ matches a
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
    # == Anchor denylist
    #
    # Anchoring at a system root or a user's home directory is almost
    # always a misconfiguration: it makes the entire system or home tree
    # writable. The constructor rejects {DENIED_ANCHORS} (system tops:
    # +/+, +/etc+, +/var+, …) and any directory whose parent is +/home+
    # (catches +/home/$USER+ and +/home/$OTHER_USER+). This is a sanity
    # guard against fat-fingering, not a security perimeter — the real
    # security is the +readable+/+writable+ lists. Other-OS home roots
    # (+/Users/$USER+ on macOS) are not denied; Linux-first per
    # +CLAUDE.md+.
    class Filesystem
      # Raised for any path that resolves outside the workspace. Recoverable
      # at the tool layer — tools rescue this and emit +"Error: ..."+
      # observations so the LLM can self-correct on the next turn. Also
      # raised at construction time for a denied anchor.
      class Error < StandardError; end

      # System-root anchors the constructor refuses. Exact-match (not
      # prefix) — +/home/user/project+ passes, +/home/user+ is rejected by
      # the parent-is-/home check below. Frozen list; downstream hosts
      # with unusual layouts can subclass if they really need a different
      # policy.
      DENIED_ANCHORS = %w[
        / /etc /var /proc /sys /dev /boot /root
        /usr /opt /lib /lib64 /bin /sbin /tmp
      ].map { |p| Pathname.new(p) }.freeze

      # @return [Pathname] project anchor, post-realpath. Where +Bash+
      #   runs commands. Always in {#readable} and {#writable}.
      attr_reader :cwd

      # @return [Array<Pathname>] read-only roots (in addition to writable
      #   ones, which are also readable). Post-realpath, deduped.
      attr_reader :readable

      # @return [Array<Pathname>] writable roots (read+write). Includes
      #   {#cwd} and, if +temp: true+, {#temp}. Post-realpath, deduped.
      attr_reader :writable

      # @return [Pathname, nil] the ephemeral playground (writable, owned
      #   by this workspace) when constructed with +temp: true+, else
      #   +nil+. Removed via +at_exit+ on process exit.
      attr_reader :temp

      # @param anchor [String, Pathname] absolute (or working-directory-
      #   relative) path to the project anchor. +realpath+'d once; must
      #   exist; must not match {DENIED_ANCHORS} or be a direct child of
      #   +/home+.
      # @param readable [Array<String, Pathname>] additional read-only
      #   roots. +realpath+'d at construction; missing entries raise
      #   loudly via {Pathname#realpath}.
      # @param writable [Array<String, Pathname>] additional read+write
      #   roots. Same treatment as +readable+.
      # @param temp [Boolean] when +true+, mints an ephemeral
      #   {Dir.mktmpdir}, adds it to +writable+, exposes via {#temp},
      #   registers +at_exit+ cleanup.
      # @raise [Errno::ENOENT] if +anchor+ or any +readable+/+writable+
      #   entry does not exist.
      # @raise [Error] if +anchor+ is denied (system root or +/home/*+).
      def initialize(anchor:, readable: [], writable: [], temp: false)
        @cwd = Pathname.new(anchor).realpath
        validate_anchor!(@cwd)

        @temp = temp ? Pathname.new(Dir.mktmpdir('pikuri-temp-')).realpath : nil
        at_exit { FileUtils.remove_entry(@temp.to_s) if @temp && @temp.exist? } if @temp

        @writable = ([@cwd] + writable.map { |p| Pathname.new(p).realpath } + [@temp].compact).uniq
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

      def validate_anchor!(canonical)
        if DENIED_ANCHORS.include?(canonical) || canonical.parent.to_s == '/home'
          raise Error,
                "anchor '#{canonical}' is a system or home root; the workspace anchor " \
                'must be a project subdirectory (a system or home root would expose the entire ' \
                'tree as writable).'
        end
      end

      # See the class header for the algorithm rationale.
      def resolve(path, roots)
        pn = Pathname.new(path)
        pn = @cwd + pn unless pn.absolute?
        cleaned = pn.cleanpath

        existing = cleaned
        existing = existing.parent until existing.exist? || existing.parent == existing
        anchor = existing.realpath

        matched = roots.find { |r| anchor == r || anchor.to_s.start_with?(r.to_s + File::SEPARATOR) }
        unless matched
          raise Error, "path '#{path}' is outside the workspace " \
                       "(roots: #{roots.map(&:to_s).join(', ')})"
        end

        anchor + cleaned.relative_path_from(existing)
      end
    end
  end
end
