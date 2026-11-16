# frozen_string_literal: true

module Pikuri
  module Workspace
    # The +edit+ tool — exact-string replacement on an existing file:
    #
    #   Edit.new(workspace: ws, confirmer: c)                            # every edit asks, with a diff
    #   Edit.new(workspace: ws, confirmer: c, confirm_all_writes: false) # no prompt
    #
    # == Confirm every edit, or opt out
    #
    # By default every writable edit confirms with a diff via {WriteGate}, and
    # an unwritable target short-circuits to "ask the user to sudo". Opting
    # out is safe because two guards bound the blast radius. First, the
    # read-before-edit gate: +.edit+ refuses a path the {Workspace}'s read
    # record doesn't show read this conversation. Second, +old_string+ is
    # itself an implicit read-check — the model can't supply correct bytes it
    # hasn't seen — so the change is pinned to content the model has. ({Write}
    # lacks the second guard, so it confirms an overwrite either way; see
    # +pikuri-workspace/design/architecture.md+.)
    #
    # == Matching is strict (no fuzz cascade)
    #
    # +old_string+ must match byte-for-byte. v1 ships *no* fallback replacer
    # (no whitespace-normalized, block-anchor, etc.): predictability beats fuzz
    # — a failed Edit means re-read and retry, a clear failure mode with no
    # compounding-heuristic risk. (opencode runs a 9-replacer cascade despite
    # saying "must match exactly"; pi stays strict, and so do we.)
    #
    # +occurrence:+ is what keeps that strictness affordable. Uniqueness, not
    # exactness, is the expensive half: in a repetitive file the model must
    # paste a large window just to disambiguate, and the window is pure token
    # cost. +occurrence: 2+ picks the second match by position instead. It
    # cannot silently hit the wrong text — +old_string+ still has to match
    # byte-for-byte, so a stale index fails the call rather than editing
    # elsewhere.
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
    # +replace_all+ or +occurrence+ · +occurrence+ combined with +replace_all+ ·
    # +occurrence+ below 1 or past the match count · missing / directory /
    # binary file · not read this conversation (the gate, after the binary
    # refusal) · workspace boundary / EACCES.
    #
    # Sharing: +P_one_agent+ — the "not read this conversation" refusal reads
    # one {Workspace}'s record, so sharing an instance widens *whose* read
    # counts.
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
        - `old_string` and `new_string` must differ.
        - If `old_string` matches multiple times the call fails — set `occurrence` to pick one by position, set `replace_all: true`, or add surrounding context to make the match unique.
        - Cannot create files (rejects empty `old_string` and missing files).
        - Binary files are refused.
        - CRLF files are matched in LF space; the original line endings are preserved on write.
      DESC

      # @param workspace [Workspace] captured for path resolution and the
      #   read-before-edit gate; edits route through +resolve_for_write+ (Edit
      #   modifies, so the write-set) and the gate consults +read?+.
      # @param confirmer [Confirmer] asked before each edit, unless
      #   +confirm_all_writes+ is +false+.
      # @param confirm_all_writes [Boolean] +false+ makes Edit promptless (see
      #   "Confirm every edit, or opt out").
      # @return [Edit]
      def initialize(workspace:, confirmer:, confirm_all_writes: true)
        gate = confirm_all_writes ? confirmer : nil
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
                              'byte-for-byte (whitespace counts); strip the ' \
                              'Read line prefix (line number + tab) before ' \
                              'matching; must be unique unless replace_all is ' \
                              'true. Example: "def foo\n  bar\nend".'
            p.required_string :new_string,
                              'Replacement text. Example: "def foo\n  baz\nend".'
            p.optional_boolean :replace_all,
                               'Replace every occurrence of old_string ' \
                               'instead of failing on multiple matches. ' \
                               'Defaults to false, e.g. true.'
            p.optional_integer :occurrence,
                               'Replace only the Nth match (1-based, counted ' \
                               'top to bottom) and leave the rest alone. Use ' \
                               'this instead of padding old_string with ' \
                               'context when the file repeats the same ' \
                               'snippet. Cannot be combined with replace_all.'
          },
          wants_context: true,
          execute: ->(path:, old_string:, new_string:, context:, replace_all: false, occurrence: nil) {
            Edit.edit(workspace: workspace, confirmer: gate,
                      path: path, old_string: old_string, new_string: new_string,
                      replace_all: replace_all, occurrence: occurrence,
                      cancellable: context.cancellable)
          },
          # No legs, for the same reason as {Write}: the observation reports the
          # outcome, never the file's bytes, so nothing enters the model's
          # context here. The read-before-edit gate makes that concrete — the
          # bytes arrived through {Read}, which is where the leg is tagged.
          trifecta_legs: Tool::TrifectaLegs::NONE
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
      #   (default) errors on multiple matches unless +occurrence+ picks one
      # @param occurrence [Integer, nil] 1-based index of the single match to
      #   replace, lifting the uniqueness requirement; +nil+ (default) keeps
      #   it. Mutually exclusive with +replace_all+.
      # @param confirmer [Confirmer, nil] asked before the write; +nil+ writes
      #   with no prompt (the opted-out posture).
      # @param cancellable [Pikuri::Agent::Control::Cancellable] the calling
      #   turn's token, for the confirmation.
      # @return [Tool::Result] +"Added 2 lines, removed 3 lines"+ once the edit
      #   lands; {Pikuri::Tool::Result.error} for a refusal or the confirmer's
      #   decline. The counts are exact without a differ: the replaced text and
      #   its substitute are both arguments.
      def self.edit(workspace:, path:, old_string:, new_string:, replace_all:,
                    cancellable:, confirmer:, occurrence: nil)
        if old_string.empty?
          return Tool::Result.error('old_string is empty; use the write tool to create or overwrite a file.')
        end
        if old_string == new_string
          return Tool::Result.error('old_string and new_string are identical — this edit is a no-op.')
        end

        if occurrence && replace_all
          return Tool::Result.error('occurrence and replace_all are mutually exclusive; ' \
                                    'drop one — occurrence picks a single match, replace_all takes them all.')
        end
        return Tool::Result.error("occurrence must be 1 or greater, got #{occurrence}.") if occurrence && occurrence < 1

        resolved = workspace.resolve_for_write(path)
        return Tool::Result.error(workspace.not_found(path)) unless resolved.exist?
        return Tool::Result.error("#{path} is a directory") if resolved.directory?

        return Tool::Result.error("cannot edit binary file: #{path}") if Pikuri::FileType.binary?(resolved)

        unless workspace.read?(resolved)
          return Tool::Result.error("#{path} has not been read this conversation; use the read tool " \
                                    'first so the edit applies to the current bytes.')
        end

        raw = resolved.binread

        crlf    = raw.include?("\r\n")
        content = crlf ? raw.gsub("\r\n", "\n") : raw
        needle  = normalize_lf(old_string)
        patch   = normalize_lf(new_string)

        occurrences = content.scan(needle).size
        if occurrences.zero?
          return Tool::Result.error("old_string not found in #{path}. It must match the file " \
                                    'exactly, including whitespace and indentation; re-read with the ' \
                                    'read tool if uncertain.')
        end
        if occurrence && occurrence > occurrences
          return Tool::Result.error("old_string matches #{occurrences} time#{occurrences == 1 ? '' : 's'} " \
                                    "in #{path}, so occurrence #{occurrence} does not exist.")
        end
        if occurrences > 1 && !replace_all && !occurrence
          return Tool::Result.error("old_string matches #{occurrences} times in #{path}. " \
                                    'Set occurrence=N to replace just the Nth, set replace_all=true ' \
                                    'to replace all of them, or provide more surrounding context to ' \
                                    'make the match unique.')
        end

        new_content =
          if replace_all
            # Block form bypasses gsub's \1 / \& interpolation on the
            # replacement String — we want literal substitution.
            content.gsub(needle) { patch }
          else
            idx = nth_index(content, needle, occurrence || 1)
            content.byteslice(0, idx) + patch + content.byteslice(idx + needle.bytesize, content.bytesize - idx - needle.bytesize)
          end

        final = crlf ? new_content.gsub("\n", "\r\n") : new_content

        replaced = replace_all ? occurrences : 1
        detail =
          if occurrence
            "occurrence #{occurrence} of #{occurrences}"
          else
            "#{replaced} occurrence#{replaced == 1 ? '' : 's'}"
          end

        if confirmer
          gate = WriteGate.check(
            confirmer: confirmer, path: path, resolved: resolved,
            question: "OK to edit #{path} (#{detail})?",
            change: Confirmer::Change.new(path: path, old: raw, new: final),
            cancellable: cancellable
          )
          return gate if gate
        end

        resolved.write(final)

        # Keep the path marked read: the editor knows the resulting bytes, so a
        # follow-up edit needn't re-read. Idempotent — the read? gate passed.
        workspace.mark_read(resolved)

        Tool::Result.new(
          content: "Edited #{path}: replaced #{detail}.",
          summary: "Added #{Pikuri::Tool.pluralize(patch.lines.size * replaced, 'line')}, " \
                   "removed #{Pikuri::Tool.pluralize(needle.lines.size * replaced, 'line')}"
        )
      rescue Filesystem::Error => e
        Tool::Result.error(e.message)
      rescue Errno::EACCES => e
        Tool::Result.error("cannot edit #{path}: #{e.message}")
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

      # Byte offset of the +nth+ (1-based) non-overlapping match of +needle+.
      #
      #   nth_index("foofoofoo", "foo", 2)   # => 3
      #
      # Non-overlapping to agree with the +String#scan+ count the caller
      # bounds +nth+ against — so the two can never disagree.
      #
      # @param haystack [String] BINARY-encoded content
      # @param needle [String] BINARY-encoded search string
      # @param nth [Integer] 1-based match index, already known to exist
      # @return [Integer] byte offset of the match
      def self.nth_index(haystack, needle, nth)
        idx = haystack.index(needle)
        (nth - 1).times { idx = haystack.index(needle, idx + needle.bytesize) }
        idx
      end
      private_class_method :nth_index
    end
  end
end
