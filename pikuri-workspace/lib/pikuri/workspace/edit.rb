# frozen_string_literal: true

module Pikuri
  module Workspace
    # The +edit+ tool — exact-string replacement on an existing file.
    # +Edit.new(workspace: ws)+ produces a tool wired like any bundled tool's.
    # In its default (promptless) form it takes the lone +workspace:+ like
    # {Read}; an optional +confirmer:+ turns on diff-confirmation.
    #
    # == Confirmer is optional (and self-describing)
    #
    # With no +confirmer:+ (default), Edit runs without a prompt because two
    # guards bound its blast radius. First, the read-before-edit gate: +.edit+
    # refuses a path the {Workspace}'s read record doesn't show read this
    # conversation. Second, +old_string+ is itself an implicit read-check — the
    # model can't supply correct bytes it hasn't seen — so even within a read
    # file the change is pinned to content the model has. ({Write} *always*
    # takes a confirmer because a hallucinated +content+ could clobber unread
    # bytes.)
    #
    # Handing Edit a +confirmer:+ opts it into the confirm-all-writes posture
    # (the OS-helper wiring): every writable edit confirms with a diff via
    # {WriteGate}, an unwritable target short-circuits to "ask the user to
    # sudo". So the confirmer's presence *is* the posture — no separate flag.
    #
    # == Matching is strict (no fuzz cascade)
    #
    # +old_string+ must match byte-for-byte. v1 ships *no* fallback replacer
    # (no whitespace-normalized, block-anchor, etc.): predictability beats fuzz
    # — a failed Edit means re-read and retry, a clear failure mode with no
    # compounding-heuristic risk. (opencode runs a 9-replacer cascade despite
    # saying "must match exactly"; pi stays strict, and so do we.)
    #
    # == Line endings get normalized
    #
    # The one exception to "strict bytes": CRLF files are matched in LF space
    # and the original ending restored on write. {Read} renders via +each_line+
    # + +chomp+ (stripping +\r\n+ to +\n+), so a pure byte-match would never
    # succeed on CRLF since the model can only supply LF. Algorithm: detect
    # +\r\n+ anywhere (treat as CRLF) → normalize content/+old_string+/
    # +new_string+ to LF → match+replace in LF space → convert +\n+ → +\r\n+ back
    # if CRLF. Caveat: a mixed-ending file is treated as CRLF, so bare-LF lines
    # get converted — rare, acceptable for v1.
    #
    # == Refusals (all as +"Error: ..."+)
    #
    # Empty +old_string+ ("use the write tool") · +old_string+ == +new_string+
    # (no-op) · not found ("must match exactly") · multiple matches without
    # +replace_all+ · missing / directory / binary file · not read this
    # conversation (the gate, after the binary refusal) · workspace boundary /
    # EACCES.
    class Edit < Pikuri::Tool
      # Description shown to the LLM (opencode-shape). Per-parameter constraints
      # live in the parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Edit a file by exact-string replacement.

        Usage:
        - You must Read the file in this conversation before editing, or the call will fail.
        - Use for partial changes to an existing file.
        - `old_string` must match the file byte-for-byte (whitespace and indentation count). Strip the Read line prefix (line number + tab) before matching.
        - `old_string` and `new_string` must differ.
        - If `old_string` matches multiple times the call fails — add surrounding context to make the match unique, or set `replace_all: true`.
        - Cannot create files (rejects empty `old_string` and missing files).
        - Binary files are refused.
        - CRLF files are matched in LF space; the original line endings are preserved on write.
      DESC

      # @param workspace [Workspace] captured for path resolution and the
      #   read-before-edit gate; edits route through +resolve_for_write+ (Edit
      #   modifies, so the write-set) and the gate consults +read?+.
      # @param read_only [ReadOnly, nil] when set and {ReadOnly#active?}, every
      #   edit is refused *before* any filesystem touch — the hard half of the
      #   read-only posture. +nil+ (default) disables the gate.
      # @param confirmer [Confirmer, nil] non-nil opts Edit into the
      #   confirm-all-writes posture (every writable edit confirms with a diff,
      #   unwritable targets short-circuit). +nil+ (default) keeps Edit
      #   promptless (see "Confirmer is optional").
      # @return [Edit]
      def initialize(workspace:, read_only: nil, confirmer: nil)
        super(
          name: 'edit',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :path,
                              'Path to the file to edit. Relative paths ' \
                              'resolve against the workspace root, e.g. ' \
                              '"lib/foo.rb".'
            p.required_string :old_string,
                              'Exact text to find in the file. Must match ' \
                              'byte-for-byte (whitespace counts); must be ' \
                              'unique unless replace_all is true. Example: ' \
                              '"def foo\n  bar\nend".'
            p.required_string :new_string,
                              'Replacement text. Must differ from ' \
                              'old_string. Example: "def foo\n  baz\nend".'
            p.optional_boolean :replace_all,
                               'Replace every occurrence of old_string ' \
                               'instead of failing on multiple matches. ' \
                               'Defaults to false, e.g. true.'
          },
          execute: ->(path:, old_string:, new_string:, replace_all: false) {
            Edit.edit(workspace: workspace, read_only: read_only, confirmer: confirmer,
                      path: path, old_string: old_string, new_string: new_string,
                      replace_all: replace_all)
          }
        )
      end

      # Resolve +path+, run the precondition checks (non-empty / non-identical /
      # exists / not directory / not binary / read this conversation), match
      # +old_string+ in LF-normalized form, and write back preserving the file's
      # original line endings.
      #
      # @param workspace [Workspace]
      # @param path [String] raw path from the LLM
      # @param old_string [String] text to find
      # @param new_string [String] text to substitute
      # @param replace_all [Boolean] true replaces every occurrence; false
      #   (default) errors on multiple matches
      # @param read_only [ReadOnly, nil] read-only gate; see {#initialize}
      #   (default +nil+ for direct callers/specs).
      # @param confirmer [Confirmer, nil] see {#initialize} (default +nil+).
      # @return [String] tool observation
      def self.edit(workspace:, path:, old_string:, new_string:, replace_all:,
                    read_only: nil, confirmer: nil)
        return "Error: cannot edit #{path} — #{read_only.message}" if read_only&.active?

        return 'Error: old_string is empty; use the write tool to create or overwrite a file.' if old_string.empty?
        return 'Error: old_string and new_string are identical — this edit is a no-op.' if old_string == new_string

        resolved = workspace.resolve_for_write(path)
        return "Error: file not found: #{path}" unless resolved.exist?
        return "Error: #{path} is a directory" if resolved.directory?

        return "Error: cannot edit binary file: #{path}" if Pikuri::FileType.binary?(resolved)

        unless workspace.read?(resolved)
          return "Error: #{path} has not been read this conversation; use the read tool " \
                 'first so the edit applies to the current bytes.'
        end

        raw = resolved.binread

        crlf    = raw.include?("\r\n")
        content = crlf ? raw.gsub("\r\n", "\n") : raw
        needle  = normalize_lf(old_string)
        patch   = normalize_lf(new_string)

        occurrences = content.scan(needle).size
        if occurrences.zero?
          return "Error: old_string not found in #{path}. It must match the file " \
                 'exactly, including whitespace and indentation; re-read with the ' \
                 'read tool if uncertain.'
        end
        if occurrences > 1 && !replace_all
          return "Error: old_string matches #{occurrences} times in #{path}. " \
                 'Provide more surrounding context to make the match unique, ' \
                 'or set replace_all=true to replace all occurrences.'
        end

        replaced = replace_all ? occurrences : 1
        new_content =
          if replace_all
            # Block form bypasses gsub's \1 / \& interpolation on the
            # replacement String — we want literal substitution.
            content.gsub(needle) { patch }
          else
            idx = content.index(needle)
            content.byteslice(0, idx) + patch + content.byteslice(idx + needle.bytesize, content.bytesize - idx - needle.bytesize)
          end

        final = crlf ? new_content.gsub("\n", "\r\n") : new_content

        if confirmer
          gate = WriteGate.check(
            confirmer: confirmer, path: path, resolved: resolved,
            question: "OK to edit #{path} (#{replaced} occurrence#{replaced == 1 ? '' : 's'})?",
            change: Confirmer::Change.new(path: path, old: raw, new: final)
          )
          return gate if gate
        end

        resolved.write(final)

        # Keep the path marked read: the editor knows the resulting bytes, so a
        # follow-up edit needn't re-read. Idempotent — the read? gate passed.
        workspace.mark_read(resolved)

        "Edited #{path}: replaced #{replaced} occurrence#{replaced == 1 ? '' : 's'}."
      rescue Filesystem::Error => e
        "Error: #{e.message}"
      rescue Errno::EACCES => e
        "Error: cannot edit #{path}: #{e.message}"
      end

      # Force a String to BINARY and collapse +\r\n+ → +\n+ so matching/
      # replacement happens in LF space with byte-stable comparisons. Applied to
      # content, +old_string+, and +new_string+ alike (symmetric).
      #
      # @param str [String]
      # @return [String] BINARY-encoded, CRLF-collapsed copy
      def self.normalize_lf(str)
        str.b.gsub("\r\n", "\n")
      end
      private_class_method :normalize_lf
    end
  end
end
