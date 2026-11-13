# frozen_string_literal: true

require 'forwardable'
require 'pathname'
require 'set'

module Pikuri
  module Workspace
    # The composite the file tools operate against: a {Filesystem} (path
    # resolution, containment, sandboxing) paired with this session's read
    # record (which files the agent has read — the runtime half of the +read+
    # tool's read-before-edit contract). Nested under +Pikuri::Workspace+ rather
    # than promoting that module to a class.
    #
    # == Why a composite, not read-state on Filesystem
    #
    # A filesystem resolves paths; it doesn't track who read what. Hanging the
    # read record off {Filesystem} would make it a hidden passenger on a type
    # whose value is being an immutable path-policy description. Composing them
    # here keeps {Filesystem} pure and makes the read-state visible in the type.
    # The record is just a +Set+ of relative path strings held inline.
    #
    # == Facade over Filesystem
    #
    # The file tools only +resolve_for_read+/+resolve_for_write+ a path and
    # (for Grep/Glob's chdir) read +project_root+ — all delegated straight to
    # the wrapped {Filesystem}, so a tool that took a +Filesystem+ works
    # unchanged; the only new surface is {#mark_read}/{#read?}. (Bash keeps
    # taking the raw {Filesystem} — it's not a read/edit/write tool.)
    #
    # == Read-record keys are workspace-relative
    #
    # {#mark_read}/{#read?} take an absolute resolved {Pathname} and relativize
    # it against +project_root+ before recording/querying. Relative keys keep the
    # record scoped to this one workspace (a path under a readable root outside
    # the project relativizes to a +../..+ form — still unique). Each workspace
    # owns its own record, so a read in one (a sub-agent's temp clone) never
    # satisfies an edit in another.
    #
    # Sharing: +P_one_agent+ — the read record is one conversation's, and
    # {#clear_reads} is tied to that conversation's reset. Two agents on one
    # composite would satisfy each other's read-before-edit gate: agent B could
    # {Edit} a file only agent A had read, which is the gate failing open.
    # {Filesystem} underneath is immutable policy and shares freely; give each
    # agent its own +Workspace+ over the same +Filesystem+.
    class Workspace
      extend Forwardable

      # @return [Filesystem] the wrapped path-resolution / sandboxing object.
      attr_reader :filesystem

      # The Filesystem surface the file tools use, forwarded so the composite is
      # a drop-in for a bare {Filesystem} at those call sites.
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

      # Forget every path read so far, returning the read-before-edit gate to
      # empty. Called by {Extension#on_conversation_reset}: a cleared
      # conversation has seen nothing, so the next {Edit}/overwrite-{Write} needs
      # a fresh {Read}, like a brand-new agent.
      #
      # @return [void]
      def clear_reads
        @read.clear
        nil
      end

      # The error text for a path that doesn't exist, naming the root that
      # relative paths resolve against. A model holding a path from another
      # tool — a corpus citation relative to some other folder, say — can't
      # otherwise tell why it missed, and this shows it what to prepend:
      #
      #   workspace.not_found('xyz/spec.txt')
      #   # => "file not found: xyz/spec.txt (relative paths resolve against /home/alice/Notes)"
      #
      # @param path [String] the path as the model gave it.
      # @return [String]
      def not_found(path)
        "file not found: #{path} (relative paths resolve against #{project_root})"
      end

      private

      # Absolute resolved path → workspace-relative key. Both are post-realpath
      # absolute, so +relative_path_from+ always succeeds on POSIX (a +../..+
      # form for paths outside the root, no raise).
      #
      # @param resolved [Pathname, String]
      # @return [String]
      def relativize(resolved)
        Pathname.new(resolved).relative_path_from(@filesystem.project_root).to_s
      end
    end
  end
end
