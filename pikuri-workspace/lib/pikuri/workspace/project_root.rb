# frozen_string_literal: true

require 'pathname'

module Pikuri
  module Workspace
    # Climb from a working directory toward the project root, looking
    # for a VCS marker (+.git+ / +.hg+ / +.svn+). Used by host binaries
    # to decide what to pass as the {Filesystem} +project_root:+ — the
    # writable containment ceiling and (under the +Bubblewrap+ sandbox)
    # the bind-mount root, so commands like +git+ and +make+ can climb
    # inside the sandbox to find +<repo>/.git+ / +<repo>/Makefile+.
    #
    # == Why VCS-only markers
    #
    # An earlier draft considered build-system fallbacks
    # (+Gemfile+, +Rakefile+, +pyproject.toml+, +package.json+,
    # +Cargo.toml+, +go.mod+, +pom.xml+, +build.gradle+,
    # +build.gradle.kts+). They were rejected because they are not
    # reliable project-root markers in multi-module setups: a Gradle
    # subproject has its own +build.gradle.kts+, a Maven module has
    # its own +pom.xml+, a yarn-workspaces package has its own
    # +package.json+. Climbing for those lands on the nearest subtree
    # root, not the actual project root — and the project_root choice
    # decides what the sandbox bind-mounts. Wrong project_root → +git+ can't
    # see the real +.git+ inside the sandbox. The VCS markers don't
    # have this problem: git/hg/svn put their metadata only at the
    # actual root (or, for git submodules, at the submodule root,
    # which is the user's intended project boundary when they cd'd
    # into the submodule).
    #
    # If no VCS marker is found within the safe-climb bounds (see
    # below), {.find} returns +nil+ and the caller falls back to
    # using the launch +cwd+ as the project_root. The LLM loses visibility to
    # sibling code outside +cwd+ in that case; the workaround is to
    # +git init+ or invoke pikuri from the actual project root.
    #
    # == Safety bounds
    #
    # The climb refuses to enter the user's home directory or any
    # system root ({DENIED_CLIMB_ROOTS}). Reaching either is treated as
    # "I've left the project tree" and the climb stops. The starting
    # +cwd+ is always considered, even if it happens to be a banned
    # directory — the user explicitly invoked there. Only ancestors
    # are gated.
    #
    # == Priority
    #
    # All +markers+ are checked at each ancestor before climbing to
    # the next, so the *nearest* VCS marker wins regardless of type.
    # In practice +.git+/+.hg+/+.svn+ never appear at different levels
    # of the same tree (hg-git users have them at the same level), so
    # this matches user intuition: "the closest project root, however
    # it's marked."
    module ProjectRoot
      # Climb-up boundary. Overlaps with {Filesystem::DENIED_PROJECT_ROOTS}
      # but kept separate: the two have different semantics
      # (climb-up boundary vs. project_root rejection) and may drift
      # apart.
      DENIED_CLIMB_ROOTS = %w[
        / /etc /var /proc /sys /dev /boot /root
        /usr /opt /lib /lib64 /bin /sbin /tmp
      ].map { |p| Pathname.new(p) }.freeze

      # VCS metadata directories/files. +.git+ is by far the common
      # case; +.hg+ and +.svn+ are included for the rare users on
      # those systems. +File.exist?+ matches both directories
      # (+.git+ in a normal checkout) and regular files (+.git+ in a
      # git worktree / submodule), so both work without special
      # handling.
      VCS_MARKERS = %w[.git .hg .svn].freeze

      # Find the nearest ancestor of +cwd+ containing any of the
      # given VCS +markers+. See the class header for the safety
      # bounds and the priority rule.
      #
      # @param cwd [String, Pathname] starting directory; +realpath+'d
      #   before climbing so symlinked checkouts don't bounce out of
      #   the project tree.
      # @param markers [Array<String>] VCS marker names to look for.
      #   Defaults to {VCS_MARKERS}.
      # @return [Pathname, nil] the matching ancestor, or +nil+ if no
      #   marker was found within the safe-climb bounds — caller
      #   should fall back to its own default (typically the launch
      #   +cwd+).
      def self.find(cwd:, markers: VCS_MARKERS)
        current = Pathname.new(cwd).realpath
        home = Pathname.new(Dir.home).realpath
        loop do
          return current if markers.any? { |m| current.join(m).exist? }

          parent = current.parent
          return nil if parent == current     # at the filesystem root
          return nil if parent == home        # crossing into $HOME
          return nil if DENIED_CLIMB_ROOTS.include?(parent)

          current = parent
        end
      end
    end
  end
end
