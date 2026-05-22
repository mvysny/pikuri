# frozen_string_literal: true

module Pikuri
  class Tool
    # The +edit+ tool — exact-string replacement on an existing file.
    # Instantiating +Tool::Edit.new(workspace: ws)+ produces a tool whose
    # {Tool#to_ruby_llm_tool} wiring is identical to any bundled tool's.
    # Same shape as {Tool::Read} (workspace captured by +execute+; no
    # confirmer needed).
    #
    # == Why no confirmer
    #
    # The +old_string+ argument is itself an implicit read-check: the
    # model can't write a correct +old_string+ without having seen the
    # file (via {Tool::Read} or out-of-band), so the blast radius of any
    # Edit is bounded by the model's actual knowledge of file state.
    # That makes Edit safe to execute without prompting — by contrast,
    # {Tool::Write} requires a confirmer because a hallucinated 500-line
    # +content+ could clobber unread bytes.
    #
    # == Matching is strict (no fuzz cascade)
    #
    # +old_string+ must match the file byte-for-byte. v1 ships *no*
    # fallback replacer (no whitespace-normalized, line-trimmed, block-
    # anchor, etc.). Predictability beats fuzz: when an Edit fails, the
    # model re-reads with {Tool::Read} and retries — clear failure mode,
    # no compounding-heuristic risk. opencode runs a 9-replacer cascade
    # under the hood despite its own description saying "must match
    # exactly"; pi stays strict. We match pi.
    #
    # == Line endings get normalized
    #
    # The one structural exception to "strict bytes": files with CRLF
    # line endings get matched in LF space, and the original line ending
    # is restored on write. Reason: {Tool::Read} renders content via
    # +each_line+ + +chomp+, which strips +\r\n+ to +\n+ in what the
    # model sees. A pure strict byte-match would then never succeed on
    # CRLF files because the model can only ever supply LF. opencode and
    # pi both do this normalization for the same reason.
    #
    # Algorithm:
    #
    # 1. Detect whether the file contains +\r\n+ anywhere (treat as CRLF).
    # 2. Normalize content, +old_string+, and +new_string+ to LF.
    # 3. Match + replace in LF space.
    # 4. If the file was CRLF, convert +\n+ → +\r\n+ on the way back out.
    #
    # Caveat: a mixed-line-ending file is treated as CRLF, which means
    # any pre-existing bare-LF lines get converted on write. Rare in
    # practice; acceptable for v1.
    #
    # == Refusals
    #
    # All returned as +"Error: ..."+ observations the LLM can react to:
    #
    # * Empty +old_string+ → "use the write tool" (keeps Edit/Write roles
    #   non-overlapping).
    # * +old_string+ == +new_string+ → no-op error.
    # * +old_string+ not found in file → "must match exactly" error
    #   pointing at the read tool.
    # * +old_string+ found multiple times without +replace_all+ →
    #   multi-match error suggesting more context or +replace_all+.
    # * File missing / is a directory / is binary → respective error.
    # * Workspace boundary violation / EACCES → standard rescue path.
    class Edit < Tool
      # Description shown to the LLM. Follows the opencode-shape (summary
      # + +Usage:+ bullets) prescribed by the project's tool-description
      # convention. Per-parameter constraints live in the parameter
      # descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Edit a file by exact-string replacement.

        Usage:
        - Use for partial changes to an existing file; for full rewrites or new files use `write` instead.
        - `old_string` must match the file byte-for-byte (whitespace and indentation count); re-read the file with `read` if uncertain.
        - `old_string` and `new_string` must differ.
        - If `old_string` matches multiple times the call fails — add surrounding context to make the match unique, or set `replace_all: true`.
        - Cannot create files (rejects empty `old_string` and missing files).
        - Binary files are refused.
        - CRLF files are matched in LF space; the original line endings are preserved on write.
      DESC

      # @param workspace [Tool::Workspace] captured for path resolution;
      #   all reads/writes route through +workspace.resolve_for_write+
      #   (Edit modifies, so it uses the write-set even though it doesn't
      #   create files).
      # @return [Edit]
      def initialize(workspace:)
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
            Edit.edit(workspace: workspace, path: path,
                      old_string: old_string, new_string: new_string,
                      replace_all: replace_all)
          }
        )
      end

      # Resolve +path+ against +workspace+, run the precondition checks
      # (non-empty / non-identical / file exists / not directory / not
      # binary), match +old_string+ in line-ending-normalized form, and
      # write the result back preserving the file's original line endings.
      #
      # @param workspace [Tool::Workspace]
      # @param path [String] raw path as supplied by the LLM
      # @param old_string [String] text to find
      # @param new_string [String] text to substitute in
      # @param replace_all [Boolean] when true, every occurrence is
      #   replaced; when false (default) multiple matches are an error
      # @return [String] tool observation
      def self.edit(workspace:, path:, old_string:, new_string:, replace_all:)
        return 'Error: old_string is empty; use the write tool to create or overwrite a file.' if old_string.empty?
        return 'Error: old_string and new_string are identical — this edit is a no-op.' if old_string == new_string

        resolved = workspace.resolve_for_write(path)
        return "Error: file not found: #{path}" unless resolved.exist?
        return "Error: #{path} is a directory" if resolved.directory?

        raw = resolved.binread
        sample = raw.byteslice(0, Tool::Read::BINARY_SAMPLE_BYTES)
        return "Error: cannot edit binary file: #{path}" if Tool::Read.binary?(sample)

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
        resolved.write(final)

        "Edited #{path}: replaced #{replaced} occurrence#{replaced == 1 ? '' : 's'}."
      rescue Tool::Workspace::Error => e
        "Error: #{e.message}"
      rescue Errno::EACCES => e
        "Error: cannot edit #{path}: #{e.message}"
      end

      # Force a String to BINARY encoding and collapse +\r\n+ → +\n+ so
      # all matching/replacement happens in LF space with byte-stable
      # comparisons. Applied to the file content, +old_string+, and
      # +new_string+ alike — symmetric normalization keeps the byte-match
      # semantics consistent across all three inputs.
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
