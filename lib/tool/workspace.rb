# frozen_string_literal: true

require 'pathname'

class Tool
  # Defines which paths the agent can see and write to. Subclass and
  # implement {#cwd}, {#resolve_for_read}, and {#resolve_for_write}.
  # Returned Pathnames are absolute, post-symlink-resolution.
  #
  # == Read-set vs. write-set
  #
  # The two resolve methods exist because a future workspace may admit
  # paths for reading that it refuses for writing — e.g. a multi-root
  # workspace where +~/.claude/skills+ is readable but only the project
  # CWD is writable. For v1's {Cwd} the two methods are the same: read-
  # set and write-set are both the CWD subtree.
  #
  # == Existence is not the workspace's concern
  #
  # +resolve_for_read('foo.rb')+ succeeds (returns a +Pathname+) even if
  # +foo.rb+ doesn't exist; the caller ({Tool::Read}) errors with
  # file-not-found when it tries to open it. +resolve_for_write+
  # tolerates entirely non-existent paths (Write can create
  # +lib/new/dir/foo.rb+ even when +lib/new/+ doesn't exist) — the
  # caller is responsible for any +mkdir_p+ before writing. This split
  # keeps the workspace narrowly responsible for *containment*, not for
  # filesystem-state checks.
  #
  # == Future extensions (out of scope for v1)
  #
  # * Multi-root workspace: +~/.claude/skills+ readable, CWD writable.
  # * +Tool::Workspace::ALLOW_ALL+: no restriction, planned for Docker /
  #   dev-container mode.
  class Workspace
    # Raised for any path that resolves outside the workspace. Recoverable
    # at the tool layer — tools rescue this and emit +"Error: ..."+
    # observations so the LLM can self-correct on the next turn.
    class Error < StandardError; end

    # Project anchor: where shells run, where modifications are made.
    # For {Cwd} this is the constructor's +root:+ (after +realpath+);
    # a future +ALLOW_ALL+ would return the user's invocation
    # directory.
    #
    # @return [Pathname]
    # @raise [NotImplementedError] in the abstract base
    def cwd
      raise NotImplementedError, "#{self.class}#cwd must be implemented"
    end

    # Resolve a user-supplied path against the workspace's read-set.
    # Returned Pathname is absolute and may not exist on disk; the
    # caller validates existence separately.
    #
    # @param path [String] user-supplied path, absolute or relative
    # @return [Pathname]
    # @raise [Error] if the resolved path falls outside the read-set
    # @raise [NotImplementedError] in the abstract base
    def resolve_for_read(path)
      raise NotImplementedError, "#{self.class}#resolve_for_read must be implemented"
    end

    # Resolve a user-supplied path against the workspace's write-set.
    # Same shape as {#resolve_for_read}; semantically distinct so a
    # future workspace can permit reading paths it refuses to write.
    #
    # @param path [String]
    # @return [Pathname]
    # @raise [Error] if the resolved path falls outside the write-set
    # @raise [NotImplementedError] in the abstract base
    def resolve_for_write(path)
      raise NotImplementedError, "#{self.class}#resolve_for_write must be implemented"
    end

    # Locks read+write to a single subtree (the +root:+ passed at
    # construction, with symlinks resolved). +cwd+ equals the root.
    #
    # == Containment algorithm
    #
    # +#resolve+ walks up the input path to its deepest existing
    # ancestor, +realpath+'s that ancestor (resolving any symlinks in
    # the existing portion), then verifies the resolved anchor is
    # +@root+ or a descendant. Four cases the algorithm must handle:
    #
    # 1. +lib/foo.rb+ (exists) → +existing+ = full path, +anchor+ in
    #    root → returns the realpath'd file.
    # 2. +lib/new/dir/foo.rb+ (intermediates missing) → walks up to
    #    +@root/lib+, +anchor+ in root → returns the intended new path
    #    (caller +mkdir_p+s the parent before writing).
    # 3. +lib/../../etc/passwd+ (+..+ escape) → +cleanpath+ collapses
    #    +..+ syntactically, walks land outside +@root+ → +Error+.
    # 4. +link/foo.rb+ where +link → /etc+ (symlink escape) → walks to
    #    +link+ (which exists), +realpath+ resolves through the
    #    symlink to +/etc+, outside +@root+ → +Error+.
    #
    # Pure lexical normalization (+cleanpath+ + prefix check) catches
    # cases 1–3 but misses case 4. The walk-up step adds the
    # +realpath+ pass on the existing prefix, closing that gap.
    class Cwd < Workspace
      # @param root [String, Pathname] absolute (or working-directory-
      #   relative) path to anchor the workspace at. +realpath+'d once
      #   so subsequent comparisons happen in canonical form.
      # @raise [Errno::ENOENT] if +root+ does not exist; surfaces
      #   immediately so misconfigured callers fail loudly.
      def initialize(root:)
        @root = Pathname.new(root).realpath
      end

      # @return [Pathname]
      def cwd
        @root
      end

      # @param path [String]
      # @return [Pathname]
      # @raise [Error]
      def resolve_for_read(path)
        resolve(path)
      end

      # @param path [String]
      # @return [Pathname]
      # @raise [Error]
      def resolve_for_write(path)
        resolve(path)
      end

      private

      # See class header for the algorithm rationale.
      def resolve(path)
        pn = Pathname.new(path)
        pn = @root + pn unless pn.absolute?
        cleaned = pn.cleanpath

        existing = cleaned
        existing = existing.parent until existing.exist? || existing.parent == existing
        anchor = existing.realpath

        unless anchor == @root || anchor.to_s.start_with?(@root.to_s + File::SEPARATOR)
          raise Error, "path '#{path}' is outside the workspace '#{@root}'"
        end

        anchor + cleaned.relative_path_from(existing)
      end
    end
  end
end
