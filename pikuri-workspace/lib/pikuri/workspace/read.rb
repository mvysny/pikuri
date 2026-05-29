# frozen_string_literal: true

require 'ruby_llm'

module Pikuri
  module Workspace
    # The +read+ tool, expressed as a {Pikuri::Tool} subclass: instantiating
    # +Read.new(workspace: ws)+ produces a tool whose
    # {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to any bundled
    # tool's, so ruby_llm sees nothing special about it. Same shape as
    # the +agent+ tool from +pikuri-subagents+ — workspace is captured by
    # the +execute+ closure at construction.
    #
    # == Output format
    #
    # cat-n: each line is rendered as +"%6d\t%s"+ (six-column right-
    # padded line number, tab, content). Chosen for breadth of training-
    # data exposure: +cat -n+ output shows up across virtually every Unix
    # tutorial and Stack Overflow answer, so even small local models
    # recognize the shape. opencode's shorter +"<n>: <content>"+ format
    # saves a few thousand tokens per 2K-line file but trades model
    # familiarity; pi omits line numbers entirely (cheapest tokens, but
    # the model loses the ability to cite ranges or pick {Edit}
    # boundaries precisely).
    #
    # == Truncation rules
    #
    # The line/byte windowing is delegated to
    # {Pikuri::FileType.read_as_text_paged}, which returns a
    # {Pikuri::FileType::Page} this tool renders; the same windower
    # backs +VectorDb::Read+. Two independent limits, whichever fires
    # first wins:
    #
    # * *Line limit* — {DEFAULT_LIMIT} lines (overridable via +limit+).
    # * *Byte cap* — {MAX_BYTES} bytes of input content; not exposed as a
    #   parameter. Bypassable in practice by paging via +offset+.
    #
    # Additionally, individual lines longer than {MAX_LINE_LENGTH} chars
    # are truncated with {LINE_TRUNCATION_MARKER} appended; the model is
    # told to reach for +grep+ to find content inside such files. (These
    # constants alias the +PAGE_*+ ones on {Pikuri::FileType} — one
    # source of truth, shared with +VectorDb::Read+.)
    #
    # == PDF extraction
    #
    # PDFs are detected by their +%PDF-+ magic prefix in the sample bytes
    # and routed through {Pikuri::FileType.read_as_text_paged} instead of
    # the binary-refusal path. The extractor walks pages lazily via
    # +pdf-reader+, emitting one synthetic +"--- Page N ---"+ header line
    # per page followed by that page's text. The offset / limit /
    # MAX_BYTES contract is identical to the text path — extraction stops
    # as soon as the line or byte cap is hit, so reading the first window
    # of a 500-page PDF only parses the few pages needed. Line numbers in
    # PDF output are for citation back to the user only; PDFs are not
    # editable through {Edit}.
    #
    # PDFs with no extractable text (scanned images, empty documents) come
    # back with an LLM-actionable hint string rather than an empty
    # observation. Encrypted / malformed / XFA-form PDFs surface as
    # +"Error: cannot extract PDF text: ..."+ — same convention as other
    # tool errors the model can react to. No OCR.
    #
    # == Image attachments
    #
    # PNG / JPEG / GIF / WebP files are detected by magic bytes (see
    # {.image_mime}) and routed to {.format_image} ahead of the binary
    # sniff. Instead of a +String+ observation, the tool returns a
    # +RubyLLM::Content+ carrying a short metadata note ("Read image:
    # path (bytes, mime)") plus the file as an attachment; the
    # per-provider Media formatter turns that into the right image
    # content block inside the +tool_result+. The text half is what the
    # model cites back ("the image at lib/foo.png shows…"); the image
    # half is what the model actually looks at.
    #
    # +offset+ / +limit+ are ignored on the image path — there's no
    # line-paging concept. The hard size cap is {MAX_IMAGE_BYTES}; files
    # above that come back as +"Error: image too large…"+ rather than
    # being silently encoded into a payload the upstream API would
    # reject. No auto-resize: pikuri doesn't pull in an image-processing
    # dep for one tool's ergonomics. See +IDEAS.md+ for the deferred
    # auto-resize discussion.
    #
    # Vision capability of the underlying model is *not* checked here.
    # Sending an image to a non-vision model produces a provider error
    # the LLM can react to on the next turn; coupling Read to model
    # capability metadata (notoriously incomplete for local servers)
    # buys less than the friction it adds.
    #
    # == Refusals
    #
    # * Path outside the workspace → caught from
    #   {Filesystem::Error}, returned as +"Error: ..."+.
    # * File not found, EACCES → +"Error: ..."+.
    # * Path is a directory → +"Error: ... use the glob tool"+, keeping
    #   directory listing as the glob tool's responsibility (Step 9).
    # * Image larger than {MAX_IMAGE_BYTES} → +"Error: image too large…"+,
    #   leaving the model to pick a different file or ask the user to
    #   resize.
    # * Binary content → {Pikuri::FileType.binary?} on the sample; any
    #   +NUL+ byte or a sample dense in control characters triggers
    #   refusal. Catches archives and compiled artifacts without an
    #   extension list to maintain. PDFs and supported images are
    #   intercepted by their respective magic-byte checks via
    #   {Pikuri::FileType.detect_mime} before the binary sniff — see
    #   above.
    # * Offset past EOF → +"Error: offset N is beyond end of file (M lines total)"+.
    class Read < Pikuri::Tool
      # The windowing constants live on {Pikuri::FileType} now (shared
      # with +VectorDb::Read+); these aliases keep the names this tool's
      # description and specs reference pointing at the single source.

      # @return [Integer] default value of the +limit+ parameter (number
      #   of lines to read per call).
      DEFAULT_LIMIT = Pikuri::FileType::PAGE_DEFAULT_LIMIT

      # @return [Integer] per-line character cap; longer lines are
      #   truncated with {LINE_TRUNCATION_MARKER}.
      MAX_LINE_LENGTH = Pikuri::FileType::PAGE_MAX_LINE_LENGTH

      # @return [String] suffix appended to lines truncated by
      #   {MAX_LINE_LENGTH}.
      LINE_TRUNCATION_MARKER = Pikuri::FileType::PAGE_LINE_TRUNCATION_MARKER

      # @return [Integer] hard byte cap on input content collected per
      #   call. Counted on the line bytes (plus one for the joining
      #   newline); the rendered output is slightly larger due to the
      #   per-line +"%6d\t"+ prefix.
      MAX_BYTES = Pikuri::FileType::PAGE_MAX_BYTES

      # @return [String] human-readable form of {MAX_BYTES} for the
      #   continuation marker.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [Integer] hard size cap on inline-attached images. Matches
      #   Anthropic's per-image limit; same order of magnitude on
      #   OpenAI / Gemini. Above this we refuse rather than encode a
      #   payload the provider would reject.
      MAX_IMAGE_BYTES = 5 * 1024 * 1024

      # @return [String] human-readable form of {MAX_IMAGE_BYTES} for
      #   refusal messages.
      MAX_IMAGE_BYTES_LABEL = "#{MAX_IMAGE_BYTES / (1024 * 1024)} MB"

      # Description shown to the LLM. Follows the opencode-shape (summary
      # + +Usage:+ bullets) prescribed by the project's tool-description
      # convention. Per-parameter constraints (defaults, format) live in
      # the parameter descriptions, not here.
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
        - Directories are refused — use the `glob` tool to list files.
        - If unsure of the path, use `glob` first to look up filenames.
        - Avoid tiny repeated slices — if you need more context, read a larger window.
      DESC

      # @param workspace [Filesystem] captured for path resolution;
      #   all reads route through +workspace.resolve_for_read+.
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
          }
        )
      end

      # Produce a new {Read} bound to +workspace+. Used by
      # {Pikuri::SubAgent::SubAgentTool} when a persona supplies a
      # +workspace_factory:+ — the parent's instance is rebuilt for
      # the sub-agent's fresh workspace so paths resolve against the
      # right root.
      #
      # @param workspace [Filesystem]
      # @return [Read]
      def with_workspace(workspace)
        self.class.new(workspace: workspace)
      end

      # Resolve +path+ against +workspace+, refuse directories / binaries /
      # missing files, and return either the cat-n-formatted slice or an
      # +"Error: ..."+ observation.
      #
      # @param workspace [Filesystem]
      # @param path [String] raw path as supplied by the LLM
      # @param offset [Integer] 1-indexed line number to start at
      # @param limit [Integer] maximum lines to return
      # @return [String, RubyLLM::Content] tool observation. Text and PDF
      #   paths return a +String+; supported images return a
      #   +RubyLLM::Content+ with the file attached so the model receives
      #   the image inline. See "Image attachments" above.
      def self.read(workspace:, path:, offset:, limit:)
        return "Error: offset must be >= 1, got #{offset}" if offset < 1
        return "Error: limit must be >= 1, got #{limit}"   if limit < 1

        resolved = workspace.resolve_for_read(path)
        return "Error: file not found: #{path}" unless resolved.exist?
        return "Error: #{path} is a directory; use the glob tool to list files." if resolved.directory?

        mime = Pikuri::FileType.detect_mime(resolved)
        return format_image(path: path, resolved: resolved, mime: mime) if mime&.start_with?('image/')
        # PDFs are binary by the heuristic, so the PDF route (handled
        # inside read_as_text_paged) must win over the binary refusal.
        if mime != 'application/pdf' && Pikuri::FileType.binary?(resolved)
          return "Error: cannot read binary file: #{path}"
        end

        page = Pikuri::FileType.read_as_text_paged(
          resolved, offset: offset, limit: limit,
          max_bytes: MAX_BYTES, max_line_length: MAX_LINE_LENGTH
        )
        render_page(page)
      rescue Filesystem::Error => e
        "Error: #{e.message}"
      rescue Errno::EACCES => e
        "Error: cannot read #{path}: #{e.message}"
      rescue RuntimeError => e
        # Malformed / unsupported PDF surfaced by read_as_text_paged.
        "Error: #{e.message}"
      end

      # Render a {Pikuri::FileType::Page} as the cat-n observation: a
      # six-column line number, a tab, then the (already-truncated)
      # content, followed by a trailer that tells the model whether to
      # page on. PDF pages carry +"--- Page N ---"+ marker lines from
      # the extractor; the +kind+ only changes trailer wording here.
      #
      # @param page [Pikuri::FileType::Page]
      # @return [String]
      def self.render_page(page)
        if page.lines.empty?
          return empty_message(page) if page.total_lines.zero?

          return "Error: offset #{page.start_line} is beyond end of file " \
                 "(#{page.total_lines} lines total)"
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

        "#{body}\n\n#{trailer}"
      end
      private_class_method :render_page

      # The empty-document message, worded by content kind: a scanned /
      # text-free PDF gets an LLM-actionable hint rather than the
      # plain-file "(Empty file)".
      #
      # @param page [Pikuri::FileType::Page]
      # @return [String]
      def self.empty_message(page)
        if page.kind == :pdf
          '(PDF has no extractable text; likely scanned image content)'
        else
          '(Empty file)'
        end
      end
      private_class_method :empty_message

      # Build a multimodal observation: a short metadata note ("Read
      # image: …") plus the file itself attached as a path. The model
      # sees the note as the text half of the +tool_result+ and the
      # image as the image half — both arrive in the same turn.
      #
      # Anthropic's per-image cap is 5 MB on the encoded data, and the
      # other providers we target sit in the same order of magnitude.
      # Above {MAX_IMAGE_BYTES} we refuse rather than encoding a payload
      # the provider will reject; the +"Error: image too large…"+ string
      # is something the model can react to (pick a different file or
      # ask the user to resize). Reading the file size via
      # +Pathname#size+ avoids loading the bytes just to discover they
      # were over-cap; +RubyLLM::Attachment+ does the actual base64
      # encoding lazily, once the message is being formatted for the
      # provider.
      #
      # @param path [String] raw path as supplied by the LLM (kept for
      #   the metadata note)
      # @param resolved [Pathname] workspace-resolved path
      # @param mime [String] MIME type from {.image_mime}
      # @return [String, RubyLLM::Content] +RubyLLM::Content+ on success;
      #   +"Error: ..."+ String on size refusal.
      def self.format_image(path:, resolved:, mime:)
        size = resolved.size
        if size > MAX_IMAGE_BYTES
          return "Error: image too large to inline: #{path} is " \
                 "#{size} bytes; max #{MAX_IMAGE_BYTES_LABEL}."
        end

        note = "Read image: #{path} (#{size} bytes, #{mime})"
        RubyLLM::Content.new(note, [resolved.to_s])
      end
      private_class_method :format_image
    end
  end
end
