# frozen_string_literal: true

require 'fileutils'

module Pikuri
  module Workspace
    # The +write+ tool, expressed as a {Pikuri::Tool} subclass:
    # instantiating +Write.new(workspace: ws, confirmer: c)+ produces a
    # tool whose {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to
    # any bundled tool's, so ruby_llm sees nothing special about it.
    # Same shape as {Read} — workspace and confirmer are captured by
    # the +execute+ closure at construction.
    #
    # == Policy
    #
    # Three branches based on the on-disk state of +path+:
    #
    # 1. *New file* — write, no prompt.
    # 2. *Existing file, identical content* — return an +"Error: ..."+
    #    no-op observation *before* invoking the confirmer; don't ask the
    #    user to approve a write that wouldn't change the file. Comparison
    #    is byte-strict, in BINARY encoding (trailing-newline-only
    #    differences trigger the confirm path; encoding tags can't make
    #    equal bytes compare unequal).
    # 3. *Existing file, content differs* — confirm with
    #    +"OK to overwrite <path>: <old> → <new> bytes?"+ via {Confirmer};
    #    on yes, write. On no, return a decline-Error observation.
    #
    # == Why ask-on-overwrite (Edit doesn't)
    #
    # Both tools share the read-before-edit gate (an overwrite of an
    # existing file is refused unless the {Workspace}'s read record shows
    # a read this conversation). But Edit has a *second*, content-level guard
    # the gate can't give Write: its +old_string+ must match the current
    # bytes, so even a read file can only be changed where the model
    # demonstrably knows the content. Write has no such per-change check
    # — a hallucinated 500-line +content+ would clobber the whole file —
    # so on top of the shared gate it asks for confirmation, covering the
    # gap Edit's argument shape covers for free. New-file writes hit
    # neither (nothing to read, nothing to clobber).
    #
    # == Side effects
    #
    # Parent directories are created (+FileUtils.mkdir_p+) before the
    # write — matches the +git add lib/new/dir/foo.rb+ mental model and
    # mirrors opencode's and pi's behavior. Edge case: +mkdir_p+ succeeds
    # but the write fails; an empty directory is left behind. Accepted
    # for v1 — users have version control.
    #
    # No atomic temp-file+rename. Plain +File.write+, same as opencode and
    # pi. The crash-safety story is "the user has git".
    class Write < Pikuri::Tool
      # Description shown to the LLM. Follows the opencode-shape (summary
      # + +Usage:+ bullets) prescribed by the project's tool-description
      # convention. Per-parameter constraints live in the parameter
      # descriptions; the +Usage:+ bullets are for "when do I pick this?
      # how does it chain with other tools?".
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
      #   read-before-overwrite gate, and read-ledger marking; writes
      #   route through +workspace.resolve_for_write+.
      # @param confirmer [Confirmer] consulted before any overwrite
      #   of an existing file with non-identical content.
      # @return [Write]
      def initialize(workspace:, confirmer:)
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
            Write.write(workspace: workspace, confirmer: confirmer, path: path, content: content)
          }
        )
      end

      # Resolve +path+ against +workspace+, apply the three-branch policy
      # (new / identical / differs), and return either a success
      # observation or an +"Error: ..."+ observation.
      #
      # @param workspace [Workspace]
      # @param confirmer [Confirmer]
      # @param path [String] raw path as supplied by the LLM
      # @param content [String] bytes to write
      # @return [String] tool observation
      def self.write(workspace:, confirmer:, path:, content:)
        resolved = workspace.resolve_for_write(path)

        if resolved.exist?
          return "Error: #{path} is a directory" if resolved.directory?

          unless workspace.read?(resolved)
            return "Error: #{path} exists but has not been read this conversation; " \
                   'use the read tool first so you do not clobber unread changes.'
          end

          existing = read_for_compare(resolved, path)

          if existing == content.b
            return "Error: #{path} already contains exactly this content — " \
                   'no write needed. If you intended a change, re-read the ' \
                   'file and try again.'
          end

          request = Confirmer::Request.new(
            question: "OK to overwrite #{path}: #{existing.bytesize} → #{content.bytesize} bytes?"
          )
          return "Error: user declined the write to #{path}." unless confirmer.confirm?(request: request)

          write_bytes(resolved, content)
          workspace.mark_read(resolved)
          "Updated #{path} (#{existing.bytesize} → #{content.bytesize} bytes)"
        else
          write_bytes(resolved, content)
          # A just-authored file counts as read: the model supplied its
          # full bytes, so a follow-up edit needn't re-read it.
          workspace.mark_read(resolved)
          "Created #{path} (#{content.bytesize} bytes)"
        end
      rescue Filesystem::Error, Error => e
        "Error: #{e.message}"
      rescue Errno::EACCES => e
        "Error: cannot write #{path}: #{e.message}"
      end

      # Internal-only signal for LLM-actionable preconditions that Write
      # detects before any filesystem mutation — today, "existing file is
      # unreadable so the identical-content check can't run". Mirrors
      # {Filesystem::Error} in shape: caught by {.write}'s outer
      # rescue and rendered as a +"Error: ..."+ observation. The class
      # is +private_constant+ to keep it from leaking out as a public
      # exception type; callers should never +rescue+ this directly.
      class Error < StandardError; end
      private_constant :Error

      # Read the existing file in BINARY mode so the equality check is
      # purely byte-wise. Raises {Error} on +Errno::EACCES+ so {.write}'s
      # outer rescue can render a specific "cannot read for overwrite
      # check" message — without this conversion the bottom +Errno::EACCES+
      # rescue would mislabel the read-side problem as "cannot write".
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

      # +mkdir_p+ the parent, then write. Split out so both the create-
      # and overwrite-branches can reuse it without duplicating the
      # +mkdir_p+ call.
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
