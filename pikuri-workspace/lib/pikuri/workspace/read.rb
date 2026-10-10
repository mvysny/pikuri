# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  module Workspace
    # The +read+ tool as a {Pikuri::Tool} subclass: +Read.new(workspace: ws)+
    # produces a tool whose {Pikuri::Tool#to_ruby_llm_tool} wiring is identical
    # to any bundled tool's. Workspace is captured by the +execute+ closure.
    #
    # == Output format
    #
    # cat-n: each line +"%6d\t%s"+ (6-col line number, tab, content). Chosen for
    # training-data familiarity — +cat -n+ is everywhere, so even small local
    # models recognize it; opencode's +"<n>: "+ saves tokens but trades
    # familiarity, pi omits numbers (cheapest, but no range citation or {Edit}
    # boundaries).
    # The numbering and {DESCRIPTION}'s read-a-larger-window nudge were
    # confirmed as a pair by an outside-model review (Grok 4.6, 2026-08) —
    # don't trade either back for tokens.
    #
    # == Truncation rules
    #
    # Line/byte windowing is delegated to {Pikuri::FileType.read_as_text_paged},
    # which returns a {Pikuri::Extractor::Page} this tool renders (same windower
    # backs +VectorDb::Tools::Read+). Two limits, first to fire wins: a line
    # limit ({DEFAULT_LIMIT}, overridable via +limit+) and a byte cap
    # ({MAX_BYTES}, not a parameter, bypassable by paging via +offset+). Lines
    # over {MAX_LINE_LENGTH} are truncated with {LINE_TRUNCATION_MARKER}. (The
    # constants alias the +PAGE_*+ ones on {Pikuri::Extractor}.)
    #
    # == PDF and other extracted formats
    #
    # Which formats read as text is the {Pikuri::Extractor} registry's business:
    # with pikuri-pdf registered, PDFs are claimed by +%PDF-+ ahead of the
    # binary refusal and extracted with one +"--- Page N ---"+ header per page,
    # lazily where the format allows (a 500-page PDF's first window parses only
    # its pages). PDF line numbers are for citation only — PDFs aren't editable.
    # No extractable text (scanned/empty) → an LLM-actionable hint;
    # encrypted/malformed → +"Error: ..."+. No OCR.
    #
    # == Image attachments
    #
    # PNG/JPEG/GIF/WebP (magic-byte detected) route to {.format_image} ahead of
    # the binary sniff, answering the one {Pikuri::Tool::Result} in pikuri with
    # +attachments+: a metadata note ("Read image: …") as +content+ for the
    # model to cite, plus the file as an attachment the model looks at.
    # +offset+/+limit+ are ignored (no line paging). Over
    # {MAX_IMAGE_BYTES} → +"Error: image too large…"+ rather than a payload the
    # provider rejects; no auto-resize (see +design/ideas/coding-agent.md+). Vision
    # capability is not checked — a non-vision model's provider error is
    # something the LLM reacts to, cheaper than tracking model metadata.
    #
    # == Refusals (all as +"Error: ..."+)
    #
    # Path outside the workspace ({Filesystem::Error}), not found, EACCES, a
    # directory (refused, but the refusal carries the directory's own entries —
    # see {.directory_refusal}), image over {MAX_IMAGE_BYTES}, binary content
    # (nothing in the registry claims it — the {Pikuri::FileType.binary?}
    # heuristic catches archives/artifacts with no extension list), offset past
    # EOF.
    #
    # Sharing: +P_one_agent+ — every successful read marks the path on its
    # {Workspace}, which *is* the read-before-edit gate's state, so a shared
    # instance would let one agent's read unlock another's {Edit}. +with_workspace+
    # rebinds a copy when a sub-agent needs a different tree.
    class Read < Pikuri::Tool
      # These alias the +PAGE_*+ constants on {Pikuri::Extractor} (one source of
      # truth, shared with +VectorDb::Tools::Read+).

      # @return [Integer] default value of the +limit+ parameter (lines per call).
      DEFAULT_LIMIT = Pikuri::Extractor::PAGE_DEFAULT_LIMIT

      # @return [Integer] per-line character cap; longer lines are
      #   truncated with {LINE_TRUNCATION_MARKER}.
      MAX_LINE_LENGTH = Pikuri::Extractor::PAGE_MAX_LINE_LENGTH

      # @return [String] suffix appended to lines truncated by
      #   {MAX_LINE_LENGTH}.
      LINE_TRUNCATION_MARKER = Pikuri::Extractor::PAGE_LINE_TRUNCATION_MARKER

      # @return [Integer] hard byte cap on input content per call (line bytes +
      #   the joining newline; rendered output is larger due to the +"%6d\t"+
      #   prefix).
      MAX_BYTES = Pikuri::Extractor::PAGE_MAX_BYTES

      # @return [String] human-readable {MAX_BYTES} for the continuation marker.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [Integer] hard size cap on inline-attached images (Anthropic's
      #   per-image limit; same order on OpenAI/Gemini). Above it we refuse
      #   rather than encode a payload the provider would reject.
      MAX_IMAGE_BYTES = 5 * 1024 * 1024

      # @return [String] human-readable {MAX_IMAGE_BYTES} for refusal messages.
      MAX_IMAGE_BYTES_LABEL = "#{MAX_IMAGE_BYTES / (1024 * 1024)} MB"

      # Description shown to the LLM (opencode-shape). Per-parameter constraints
      # live in the parameter descriptions.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Read a file from the workspace and return its contents with line numbers.

        Usage:
        - Output is line-numbered in `cat -n` style so subsequent edits can reference exact line numbers.
        - Use `offset` and `limit` to page through large files; when the response ends in `Use offset=N to continue`, call again with that offset.
        - Lines longer than #{MAX_LINE_LENGTH} chars are truncated with a marker — use `grep` for content inside such files.
        - PDFs are text-extracted page-by-page with `--- Page N ---` markers in the output. Cite pages back to the user from those markers. PDFs cannot be modified with `edit`.
        - PNG / JPEG / GIF / WebP files are attached as images you can see directly, alongside a short text note with the path and size. Requires a vision-capable model; on a text-only model the provider will reject the call. Images cannot be modified with `edit`.
        - Other binary files (archives, compiled artifacts) are refused; this tool reads text otherwise.
        - If unsure of the path, use `glob` first to look up filenames.
        - Avoid tiny repeated slices — if you need more context, read a larger window.
      DESC

      # @param workspace [Workspace] captured for path resolution and
      #   read-ledger marking (+resolve_for_read+ / +mark_read+).
      # @return [Read]
      def initialize(workspace:)
        super(
          name: 'read',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :path,
                              'Path to the file to read. Relative paths ' \
                              'resolve against the workspace root, e.g. ' \
                              '"lib/foo.rb" or "/abs/path/to/file.txt".'
            p.optional_integer :offset,
                               'Line number to start reading from (1-indexed). ' \
                               "Defaults to 1, e.g. 200."
            p.optional_integer :limit,
                               'Maximum number of lines to read. Defaults to ' \
                               "#{DEFAULT_LIMIT}, e.g. 500."
          },
          execute: ->(path:, offset: 1, limit: DEFAULT_LIMIT) {
            Read.read(workspace: workspace, path: path, offset: offset, limit: limit)
          },
          trifecta_legs: Tool::TrifectaLegs.new(
            private: workspace.filesystem.private?,
            untrusted: workspace.filesystem.trusted? ? :none : :hard,
            egress_payload_review: :no_egress
          )
        )
      end

      # A new {Read} bound to +workspace+. Used by
      # {Pikuri::SubAgent::SubAgentTool} when a persona needs a fresh (temp)
      # workspace, so paths resolve against the right root and reads land in
      # that workspace's ledger.
      #
      # @param workspace [Workspace]
      # @return [Read]
      def with_workspace(workspace)
        self.class.new(workspace: workspace)
      end

      # Resolve +path+ against +workspace+, refuse directories/binaries/missing
      # files, return the cat-n slice.
      #
      # @param workspace [Workspace]
      # @param path [String] raw path from the LLM
      # @param offset [Integer] 1-indexed start line
      # @param limit [Integer] maximum lines
      # @return [Tool::Result] text/PDF → the cat-n slice (+"Read 214 lines"+);
      #   a supported image → a note with the file in
      #   {Tool::Result#attachments} (see "Image attachments"); else
      #   {Pikuri::Tool::Result.error}
      def self.read(workspace:, path:, offset:, limit:)
        return Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
        return Tool::Result.error("limit must be >= 1, got #{limit}")   if limit < 1

        resolved = workspace.resolve_for_read(path)
        return Tool::Result.error("file not found: #{path}") unless resolved.exist?
        if resolved.directory?
          return Tool::Result.error(directory_refusal(workspace: workspace, path: path, resolved: resolved))
        end

        mime = Pikuri::FileType.detect_mime(resolved)
        return format_image(path: path, resolved: resolved, mime: mime) if mime&.start_with?('image/')

        page = Pikuri::FileType.read_as_text_paged(
          resolved, offset: offset, limit: limit,
          max_bytes: MAX_BYTES, max_line_length: MAX_LINE_LENGTH
        )
        # Record the read so a later edit/overwrite clears the read-before-edit
        # gate. Any successful text/PDF read counts (even a partial window) —
        # the exact-bytes guard is Edit's +old_string+ match; the ledger only
        # attests "engaged via read".
        workspace.mark_read(resolved)
        render_page(page)
      rescue Filesystem::Error => e
        Tool::Result.error(e.message)
      rescue Errno::EACCES => e
        Tool::Result.error("cannot read #{path}: #{e.message}")
      rescue ArgumentError
        # Nothing in the Extractor registry claimed the content —
        # read_as_text_paged's binary refusal (directories and images
        # were already handled above).
        Tool::Result.error("cannot read binary file: #{path}")
      rescue RuntimeError => e
        # Extraction failure (malformed / unsupported PDF, ...)
        # surfaced by read_as_text_paged.
        Tool::Result.error(e.message)
      end

      # Refuses, but hands back the directory's entries so the model recovers
      # with no extra round-trip — the {Search::Utils.oversized_root_refusal}
      # move:
      #
      #   Error: lib is a directory, not a file. It contains (directories end with `/`):
      #   pikuri/  [3 dirs, 1 file]
      #   version.rb  48B
      #
      # **Keep this out of {DESCRIPTION}.** It is error recovery, not a
      # documented capability: teaching +read+ as a second way to list hands
      # the model a two-tools-no-criterion coin flip (+D_directory_listing+).
      #
      # Never marks the read ledger — a directory can't be edited, so counting
      # it would clear the read-before-edit gate for a path nobody read.
      #
      # @param workspace [Workspace]
      # @param path [String] raw path from the LLM (for the message)
      # @param resolved [Pathname] workspace-resolved path
      # @return [String] the refusal message, carrying the depth-1 listing —
      #   text for {Tool::Result.error} to wrap, not an observation itself
      def self.directory_refusal(workspace:, path:, resolved:)
        base = "Error: #{path} is a directory, not a file."
        listing = Listing.render(resolved, filesystem: workspace.filesystem)
        return "#{base} It is empty." if listing.empty?

        "#{base} It contains (directories end with `/`):\n#{listing}"
      rescue SystemCallError => e
        "#{base} It cannot be listed: #{e.message}"
      end
      private_class_method :directory_refusal

      # Render a {Pikuri::Extractor::Page} as the cat-n observation (6-col line
      # number, tab, truncated content) plus a trailer telling the model whether
      # to page on. PDF pages carry +"--- Page N ---"+ markers from the
      # extractor; +kind+ only changes trailer wording.
      #
      # @param page [Pikuri::Extractor::Page]
      # @return [Tool::Result] the observation, carrying +"Read N lines"+ where
      #   a page was rendered; the empty-file note or
      #   {Pikuri::Tool::Result.error} otherwise.
      def self.render_page(page)
        if page.lines.empty?
          if page.total_lines.zero?
            note = empty_message(page)
            return Tool::Result.new(content: note, summary: Pikuri::Tool.one_line(note))
          end

          return Tool::Result.error("offset #{page.start_line} is beyond end of file " \
                                    "(#{page.total_lines} lines total)")
        end

        noun = page.kind == :pdf ? 'PDF ' : ''
        last = page.start_line + page.lines.length - 1
        body = page.lines.each_with_index.map { |line, i| format("%6d\t%s", i + page.start_line, line) }.join("\n")

        trailer =
          if page.byte_capped
            "(Output capped at #{MAX_BYTES_LABEL}. Showing #{noun}lines #{page.start_line}-#{last}. " \
              "Use offset=#{last + 1} to continue.)"
          elsif page.more
            total = page.total_lines ? " of #{page.total_lines}" : ''
            "(Showing #{noun}lines #{page.start_line}-#{last}#{total}. " \
              "Use offset=#{last + 1} to continue.)"
          else
            "(End of #{page.kind == :pdf ? 'PDF' : 'file'} - total #{page.total_lines} lines)"
          end

        Tool::Result.new(content: "#{body}\n\n#{trailer}",
                         summary: "Read #{page.lines.length} #{noun}lines")
      end
      private_class_method :render_page

      # Empty-document message by kind: a scanned/text-free PDF gets an
      # LLM-actionable hint rather than the plain "(Empty file)".
      #
      # @param page [Pikuri::Extractor::Page]
      # @return [String]
      def self.empty_message(page)
        if page.kind == :pdf
          '(PDF has no extractable text; likely scanned image content)'
        else
          '(Empty file)'
        end
      end
      private_class_method :empty_message

      # Build a multimodal observation: a metadata note ("Read image: …") plus
      # the file attached, both arriving in the same +tool_result+ turn. Over
      # {MAX_IMAGE_BYTES} we refuse (an +"Error: ..."+ the model reacts to)
      # rather than encoding a payload the provider rejects; +Pathname#size+
      # avoids loading bytes just to over-cap them, and +RubyLLM::Attachment+
      # base64-encodes lazily at format time.
      #
      # The one place a {Tool::Result} carries +attachments+: the attached
      # bytes *are* the observation, so the display
      # line is derived from mime and size rather than authored here (see
      # {Pikuri::Tool::Result}'s +== Text or an attachment+).
      #
      # @param path [String] raw path from the LLM (for the note)
      # @param resolved [Pathname] workspace-resolved path
      # @param mime [String] MIME type
      # @return [Tool::Result] attachment-carrying on success;
      #   {Pikuri::Tool::Result.error} on size refusal
      def self.format_image(path:, resolved:, mime:)
        size = resolved.size
        if size > MAX_IMAGE_BYTES
          return Tool::Result.error("image too large to inline: #{path} is " \
                                    "#{size} bytes; max #{MAX_IMAGE_BYTES_LABEL}.")
        end

        note = "Read image: #{path} (#{size} bytes, #{mime})"
        Tool::Result.new(content: note, attachments: [RubyLLM::Attachment.new(resolved.to_s)],
                         summary: Pikuri::Tool.one_line(note))
      end
      private_class_method :format_image
    end
  end
end
