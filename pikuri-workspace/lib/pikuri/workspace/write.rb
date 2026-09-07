# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Workspace
    # The +write+ tool as a {Pikuri::Tool} subclass:
    # +Write.new(workspace: ws, confirmer: c)+ produces a tool wired like any
    # bundled tool's. Workspace and confirmer are captured by the +execute+
    # closure.
    #
    # == Policy
    #
    # Three branches on +path+'s on-disk state:
    #
    # 1. *New file* — write, no prompt.
    # 2. *Existing, identical content* — return an +"Error: ..."+ no-op
    #    *before* the confirmer (don't ask to approve a no-change write).
    #    Comparison is byte-strict, BINARY (trailing-newline diffs still confirm).
    # 3. *Existing, differs* — confirm +"OK to overwrite <path>: <old> → <new>
    #    bytes?"+ via {WriteGate}; on yes write, on no (or unwritable target)
    #    return the matching +"Error: ..."+.
    #
    # An overwrite *always* routes through {WriteGate} (no separate
    # promptless-confirm path), so it gets the diff payload, decline-reason
    # steering, and unwritable-target short-circuit in every posture.
    #
    # == Confirm-all-writes (opt-in)
    #
    # +confirm_all_writes+ scopes *which* writes are gated, not *how* (overwrites
    # use {WriteGate} regardless). +true+ (the OS-helper posture) also confirms
    # the *new-file* branch via {WriteGate} — every writable write confirms, an
    # unwritable target short-circuits without prompting. +false+ (default) writes
    # new files silently; only overwrites confirm. See book/os-assistant.md.
    #
    # == Why ask-on-overwrite (Edit doesn't)
    #
    # Write confirms an overwrite where {Edit} stays promptless — the two-guard
    # asymmetry (the shared read-before-edit gate plus Edit's +old_string+
    # content-check, which Write lacks so a hallucinated +content+ could clobber
    # the file) is in +pikuri-workspace/DESIGN.md+.
    #
    # == Side effects
    #
    # Parent dirs are created (+FileUtils.mkdir_p+) before the write (the
    # +git add lib/new/dir/foo.rb+ mental model). If +mkdir_p+ succeeds but the
    # write fails, an empty dir is left — accepted for v1 (users have git). No
    # atomic temp+rename; plain +File.write+ — crash safety is "the user has git".
    #
    # Sharing: +P_one_agent+ — it consults one {Workspace}'s read record. The
    # {Confirmer} is the sharper limit, though: {Confirmer::Terminal} cannot
    # serve two agents at once (see its own +== Sharing+), and a shared
    # {ReadOnly} makes read-only a VM-wide posture rather than this agent's.
    class Write < Pikuri::Tool
      # Description shown to the LLM (opencode-shape). Per-parameter constraints
      # live in the parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Write a file to the workspace, creating parent directories as needed.

        Usage:
        - Use for new files or full-file rewrites; for partial changes use `edit` instead.
        - Overwriting an existing file requires that you have read it this conversation, and then user confirmation; identical content is rejected as a no-op error — if you see that error, re-read the file rather than trying again.
        - Parent directories are created automatically (mkdir -p).
        - Writes the exact bytes supplied: no trailing-newline normalization, no encoding conversion.
        - Paths outside the workspace are refused.
      DESC

      # @param workspace [Workspace] captured for path resolution, the
      #   read-before-overwrite gate, and read-ledger marking
      #   (+resolve_for_write+).
      # @param confirmer [Confirmer] consulted (via {WriteGate}) before an
      #   overwrite with non-identical content, and — under +confirm_all_writes+
      #   — before new-file writes too.
      # @param read_only [ReadOnly, nil] when set and {ReadOnly#active?}, every
      #   write is refused *before* any filesystem touch — the hard half of the
      #   read-only posture. +nil+ (default) disables the gate.
      # @param confirm_all_writes [Boolean] scopes which writes are gated
      #   (overwrites always confirm regardless). +true+ (OS-helper posture)
      #   also confirms the new-file branch and short-circuits an unwritable
      #   target without prompting; +false+ (default) writes new files silently.
      # @return [Write]
      def initialize(workspace:, confirmer:, read_only: nil, confirm_all_writes: false)
        super(
          name: 'write',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :path,
                              'Path to the file to write. Relative paths ' \
                              'resolve against the workspace root, e.g. ' \
                              '"lib/foo.rb".'
            p.required_string :content,
                              'Full contents to write to the file, e.g. ' \
                              '"class Foo\nend\n".'
          },
          execute: ->(path:, content:) {
            Write.write(workspace: workspace, confirmer: confirmer,
                        read_only: read_only, confirm_all_writes: confirm_all_writes,
                        path: path, content: content)
          },
          # No legs: no file bytes enter the model's context (the observation is
          # an outcome), and a local write is not an external sink.
          #
          # Don't add an egress leg here for synced workspaces. Personal sync
          # keeps one owner, so it is no leg at all; an off-owner root (team
          # Drive, public link) is real egress, unknowable to the framework, and
          # the host that knows declares it via Extension#trifecta_contribution
          # (`D_write_custody_axis`).
          trifecta_legs: Tool::TrifectaLegs::NONE
        )
      end

      # Resolve +path+ against +workspace+, apply the three-branch policy, and
      # return a success or +"Error: ..."+ observation.
      #
      # @param workspace [Workspace]
      # @param confirmer [Confirmer]
      # @param path [String] raw path from the LLM
      # @param content [String] bytes to write
      # @param read_only [ReadOnly, nil] read-only gate; see {#initialize}
      #   (default +nil+ for direct callers/specs).
      # @param confirm_all_writes [Boolean] see {#initialize} (default +false+).
      # @return [Tool::Result] +"Created, 88 lines"+ / +"Updated, 88 lines (was
      #   90)"+ on a write; {Pikuri::Tool::Result.error} for a refusal or the
      #   confirmer's decline. The line counts rather than a diff: pikuri has no
      #   in-process differ (a diff-capable chrome renders the
      #   {Confirmer::Change} itself).
      def self.write(workspace:, confirmer:, path:, content:, read_only: nil, confirm_all_writes: false)
        return Tool::Result.error("cannot write #{path} — #{read_only.message}") if read_only&.active?

        resolved = workspace.resolve_for_write(path)

        if resolved.exist?
          return Tool::Result.error("#{path} is a directory") if resolved.directory?

          unless workspace.read?(resolved)
            return Tool::Result.error("#{path} exists but has not been read this conversation; " \
                                      'use the read tool first so you do not clobber unread changes.')
          end

          existing = read_for_compare(resolved, path)

          if existing == content.b
            return Tool::Result.error("#{path} already contains exactly this content — " \
                                      'no write needed. If you intended a change, re-read the ' \
                                      'file and try again.')
          end

          gate = WriteGate.check(
            confirmer: confirmer, path: path, resolved: resolved,
            question: "OK to overwrite #{path}: #{existing.bytesize} → #{content.bytesize} bytes?",
            change: Confirmer::Change.new(path: path, old: existing, new: content.b)
          )
          return Tool::Result.error(gate) if gate

          write_bytes(resolved, content)
          workspace.mark_read(resolved)
          Tool::Result.new(
            content: "Updated #{path} (#{existing.bytesize} → #{content.bytesize} bytes)",
            summary: "Updated, #{Pikuri::Tool.pluralize(content.lines.size, 'line')} " \
                     "(was #{existing.lines.size})"
          )
        else
          if confirm_all_writes
            gate = WriteGate.check(
              confirmer: confirmer, path: path, resolved: resolved,
              question: "OK to create #{path} (#{content.bytesize} bytes)?",
              change: Confirmer::Change.new(path: path, old: nil, new: content.b)
            )
            return Tool::Result.error(gate) if gate
          end

          write_bytes(resolved, content)
          # A just-authored file counts as read: the model supplied its
          # full bytes, so a follow-up edit needn't re-read it.
          workspace.mark_read(resolved)
          Tool::Result.new(content: "Created #{path} (#{content.bytesize} bytes)",
                           summary: "Created, #{Pikuri::Tool.pluralize(content.lines.size, 'line')}")
        end
      rescue Filesystem::Error, Error => e
        Tool::Result.error(e.message)
      rescue Errno::EACCES => e
        Tool::Result.error("cannot write #{path}: #{e.message}")
      end

      # Internal-only signal for an LLM-actionable precondition Write detects
      # before any mutation (today: "existing file unreadable, so the
      # identical-content check can't run"). Caught by {.write}'s outer rescue,
      # rendered as +"Error: ..."+; +private_constant+ so it doesn't leak as a
      # public exception.
      class Error < StandardError; end
      private_constant :Error

      # Read the existing file in BINARY so the equality check is byte-wise.
      # Raises {Error} on +Errno::EACCES+ so {.write}'s outer rescue renders a
      # "cannot read for overwrite check" message — else the bottom
      # +Errno::EACCES+ rescue would mislabel a read problem as "cannot write".
      #
      # @param resolved [Pathname]
      # @param path [String] original path for the error message
      # @return [String]
      # @raise [Error] when the file exists but isn't readable
      def self.read_for_compare(resolved, path)
        resolved.binread
      rescue Errno::EACCES => e
        raise Error, "cannot read #{path} for overwrite check: #{e.message}"
      end
      private_class_method :read_for_compare

      # +mkdir_p+ the parent, then write. Shared by both branches.
      #
      # @param resolved [Pathname]
      # @param content [String]
      # @return [void]
      def self.write_bytes(resolved, content)
        FileUtils.mkdir_p(resolved.dirname)
        resolved.write(content)
      end
      private_class_method :write_bytes
    end
  end
end
