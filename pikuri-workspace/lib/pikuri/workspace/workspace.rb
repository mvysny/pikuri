# frozen_string_literal: true

require 'forwardable'
require 'pathname'
require 'set'

module Pikuri
  module Workspace
    # The composite the file tools operate against: a {Filesystem}
    # (path resolution, containment, sandboxing) paired with this
    # session's read record (which files the agent has read — the
    # runtime half of the +read+ tool's read-before-edit contract). The
    # name is the +com.pikuri.workspace.Workspace+ shape — nested under
    # the existing +Pikuri::Workspace+ module rather than promoting that
    # module to a class, so the rest of the gem needs no +module+ →
    # +class+ churn.
    #
    # == Why a composite, not read-state on Filesystem
    #
    # A filesystem resolves paths; it does not track who read what — the
    # ext4-vs-inotify split. Hanging the read record off {Filesystem}
    # would make it a hidden passenger on a type whose whole value is
    # being an immutable description of path policy. Keeping the two
    # separate and composing them here means {Filesystem} stays pure and
    # the read-state is something a reader can *see* in the type. The
    # record itself is just a +Set+ of relative path strings held inline
    # — no separate ledger class, since nothing outside this composite
    # touches it.
    #
    # == Facade over Filesystem
    #
    # The five file tools only ever ask the workspace to
    # +resolve_for_read+ / +resolve_for_write+ a path and (for
    # Grep/Glob's chdir) read +project_root+. Those three are delegated
    # straight to the wrapped {Filesystem}, so a tool that took a
    # +Filesystem+ before works unchanged against the composite — the
    # only new surface is {#mark_read} / {#read?}. (Bash keeps taking
    # the raw {Filesystem}: it isn't a read/edit/write tool and has no
    # business in the read record.)
    #
    # == Read-record keys are workspace-relative
    #
    # {#mark_read} / {#read?} take an absolute, resolved {Pathname} (what
    # +resolve_for_*+ returns) and relativize it against
    # +filesystem.project_root+ before recording or querying. Relative
    # keys keep the record scoped and self-consistent to this one
    # workspace. A path under a readable root *outside* the project (a
    # system toolchain dir, say) relativizes to a +../..+ form — still a
    # deterministic, unique key. Each workspace owns its own record, so a
    # read in one (e.g. a sub-agent's temp clone) never satisfies an edit
    # in another.
    class Workspace
      extend Forwardable

      # @return [Filesystem] the wrapped path-resolution / sandboxing object.
      attr_reader :filesystem

      # The Filesystem surface the file tools use, forwarded verbatim so
      # the composite is a drop-in for a bare {Filesystem} at those call
      # sites.
      def_delegators :@filesystem, :resolve_for_read, :resolve_for_write, :project_root

      # @param filesystem [Filesystem] path resolution / sandboxing.
      def initialize(filesystem:)
        @filesystem = filesystem
        @read       = Set.new
      end

      # Record that +resolved+ has been read this session.
      #
      # @param resolved [Pathname] absolute, workspace-resolved path
      #   (as returned by +resolve_for_read+ / +resolve_for_write+).
      # @return [void]
      def mark_read(resolved)
        @read.add(relativize(resolved))
        nil
      end

      # @param resolved [Pathname] absolute, workspace-resolved path.
      # @return [Boolean] whether +resolved+ has been read this session.
      def read?(resolved)
        @read.include?(relativize(resolved))
      end

      private

      # Absolute resolved path → workspace-relative key. Both operands
      # are post-realpath absolute paths, so +relative_path_from+ always
      # succeeds on POSIX (it yields a +../..+ form for paths outside the
      # root rather than raising).
      #
      # @param resolved [Pathname, String]
      # @return [String]
      def relativize(resolved)
        Pathname.new(resolved).relative_path_from(@filesystem.project_root).to_s
      end
    end
  end
end
