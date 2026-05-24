# frozen_string_literal: true

require 'pdf-reader'

module Pikuri
  module Workspace
    # The +read+ tool, expressed as a {Pikuri::Tool} subclass: instantiating
    # +Read.new(workspace: ws)+ produces a tool whose
    # {Pikuri::Tool#to_ruby_llm_tool} wiring is identical to any bundled
    # tool's, so ruby_llm sees nothing special about it. Same shape as
    # {Pikuri::Tool::SubAgent} — workspace is captured by the +execute+
    # closure at construction.
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
    # Two independent limits, whichever fires first wins:
    #
    # * *Line limit* — {DEFAULT_LIMIT} lines (overridable via +limit+).
    # * *Byte cap* — {MAX_BYTES} bytes of input content; not exposed as a
    #   parameter. Bypassable in practice by paging via +offset+.
    #
    # Additionally, individual lines longer than {MAX_LINE_LENGTH} chars
    # are truncated with {LINE_TRUNCATION_MARKER} appended; the model is
    # told to reach for +grep+ to find content inside such files.
    #
    # == PDF extraction
    #
    # PDFs are detected by their +%PDF-+ magic prefix in the sample bytes
    # and routed to {.format_pdf} instead of the binary-refusal path. The
    # extractor walks pages lazily via +pdf-reader+, emitting one synthetic
    # +"--- Page N ---"+ header line per page followed by that page's text.
    # The offset / limit / MAX_BYTES contract is identical to the text
    # path — extraction stops as soon as the line or byte cap is hit, so
    # reading the first window of a 500-page PDF only parses the few pages
    # needed. Line numbers in PDF output are for citation back to the user
    # only; PDFs are not editable through {Edit}.
    #
    # PDFs with no extractable text (scanned images, empty documents) come
    # back with an LLM-actionable hint string rather than an empty
    # observation. Encrypted / malformed / XFA-form PDFs surface as
    # +"Error: cannot extract PDF text: ..."+ — same convention as other
    # tool errors the model can react to. No OCR.
    #
    # == Refusals
    #
    # * Path outside the workspace → caught from
    #   {Filesystem::Error}, returned as +"Error: ..."+.
    # * File not found, EACCES → +"Error: ..."+.
    # * Path is a directory → +"Error: ... use the glob tool"+, keeping
    #   directory listing as the glob tool's responsibility (Step 9).
    # * Binary content → sniffed from the first {BINARY_SAMPLE_BYTES} of
    #   the file: any +NUL+ byte, or more than {BINARY_NONPRINTABLE_THRESHOLD}
    #   non-printable bytes (control chars outside +\t \n \v \f \r+),
    #   triggers refusal. Catches images, archives, and compiled artifacts
    #   without an extension list to maintain. PDFs are intercepted by the
    #   magic-byte check before the binary sniff and routed to text
    #   extraction instead — see "PDF extraction" above.
    # * Offset past EOF → +"Error: offset N is beyond end of file (M lines total)"+.
    class Read < Pikuri::Tool
      # @return [Integer] default value of the +limit+ parameter (number
      #   of lines to read per call).
      DEFAULT_LIMIT = 2000

      # @return [Integer] per-line character cap; longer lines are
      #   truncated with {LINE_TRUNCATION_MARKER}.
      MAX_LINE_LENGTH = 2000

      # @return [String] suffix appended to lines truncated by
      #   {MAX_LINE_LENGTH}.
      LINE_TRUNCATION_MARKER = "... (line truncated to #{MAX_LINE_LENGTH} chars)"

      # @return [Integer] hard byte cap on input content collected per
      #   call. Counted on the line bytes (plus one for the joining
      #   newline); the rendered output is slightly larger due to the
      #   per-line +"%6d\t"+ prefix.
      MAX_BYTES = 50 * 1024

      # @return [String] human-readable form of {MAX_BYTES} for the
      #   continuation marker.
      MAX_BYTES_LABEL = "#{MAX_BYTES / 1024} KB"

      # @return [Integer] number of bytes sampled from the start of the
      #   file for binary-content detection.
      BINARY_SAMPLE_BYTES = 4096

      # @return [Float] fraction of the sample that may be non-printable
      #   before the file is classified as binary. Matches opencode's
      #   30%.
      BINARY_NONPRINTABLE_THRESHOLD = 0.30

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
        - Binary files other than PDF (images, archives, compiled artifacts) are refused; this tool reads text only.
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

      # Resolve +path+ against +workspace+, refuse directories / binaries /
      # missing files, and return either the cat-n-formatted slice or an
      # +"Error: ..."+ observation.
      #
      # @param workspace [Filesystem]
      # @param path [String] raw path as supplied by the LLM
      # @param offset [Integer] 1-indexed line number to start at
      # @param limit [Integer] maximum lines to return
      # @return [String] tool observation
      def self.read(workspace:, path:, offset:, limit:)
        return "Error: offset must be >= 1, got #{offset}" if offset < 1
        return "Error: limit must be >= 1, got #{limit}"   if limit < 1

        resolved = workspace.resolve_for_read(path)
        return "Error: file not found: #{path}" unless resolved.exist?
        return "Error: #{path} is a directory; use the glob tool to list files." if resolved.directory?

        sample = read_sample(resolved)
        return format_pdf(path: path, resolved: resolved, offset: offset, limit: limit) if pdf?(sample)
        return "Error: cannot read binary file: #{path}" if binary?(sample)

        format_slice(path: path, resolved: resolved, offset: offset, limit: limit)
      rescue Filesystem::Error => e
        "Error: #{e.message}"
      rescue Errno::EACCES => e
        "Error: cannot read #{path}: #{e.message}"
      end

      # Read up to {BINARY_SAMPLE_BYTES} of the file in binary mode for
      # the {.binary?} sniff. Returns an empty String for an empty file
      # (which {.binary?} treats as not-binary).
      #
      # @param resolved [Pathname]
      # @return [String] raw bytes (ASCII-8BIT encoding)
      def self.read_sample(resolved)
        resolved.open('rb') { |io| io.read(BINARY_SAMPLE_BYTES) || +'' }
      end
      private_class_method :read_sample

      # Magic-byte sniff for PDF — every conformant PDF starts with the
      # five-byte ASCII prefix +%PDF-+ per ISO 32000-1 §7.5.2. Cheap and
      # specific enough that we never need an extension list: a +.pdf+
      # rename or a header-less PDF blob both produce the right answer.
      # Used by {.read} to route to {.format_pdf} before the binary sniff
      # would otherwise refuse the file.
      #
      # @param bytes [String] sample bytes from {.read_sample}
      # @return [Boolean]
      def self.pdf?(bytes)
        bytes.start_with?("%PDF-")
      end

      # Heuristic binary classifier matching opencode's: any NUL byte
      # forces +true+; otherwise count bytes outside the printable +\t \n
      # \v \f \r+ + ASCII-32..126 range and ratio against the sample
      # size. UTF-8 continuation bytes (0x80-0xBF) are >127 so they sit
      # outside the non-printable ranges and pass through unflagged,
      # letting UTF-8 text read fine.
      #
      # Public because {Edit} reuses it to refuse binary targets —
      # if Edit accepted a binary file the model has no way to have read,
      # it could corrupt bytes the model never inspected. Same sniff, same
      # threshold, one definition.
      #
      # @param bytes [String] sample bytes
      # @return [Boolean]
      def self.binary?(bytes)
        return false if bytes.empty?

        non_printable = 0
        bytes.each_byte do |b|
          return true if b.zero?

          non_printable += 1 if b < 9 || (b > 13 && b < 32)
        end
        non_printable.to_f / bytes.bytesize > BINARY_NONPRINTABLE_THRESHOLD
      end

      # Stream the file line-by-line, collect at most +limit+ lines
      # starting at +offset+, and stop early if {MAX_BYTES} is reached.
      # We keep counting lines past the collection window so the trailer
      # can report total line count when the line limit (not the byte
      # cap) was the stopping criterion — same trick opencode uses.
      #
      # @return [String]
      def self.format_slice(path:, resolved:, offset:, limit:)
        start_index   = offset - 1
        collected     = []
        total_lines   = 0
        bytes         = 0
        byte_cap_hit  = false
        has_more      = false

        resolved.each_line do |raw|
          total_lines += 1
          next if total_lines <= start_index

          if collected.length >= limit
            has_more = true
            next
          end

          line = raw.chomp
          if line.length > MAX_LINE_LENGTH
            line = line[0, MAX_LINE_LENGTH] + LINE_TRUNCATION_MARKER
          end

          size = line.bytesize + 1 # +1 for the joining newline
          if bytes + size > MAX_BYTES
            byte_cap_hit = true
            has_more = true
            break
          end

          collected << line
          bytes += size
        end

        return '(Empty file)' if total_lines.zero?

        if start_index >= total_lines
          return "Error: offset #{offset} is beyond end of file (#{total_lines} lines total)"
        end

        last_line = offset + collected.length - 1
        body = collected.each_with_index.map { |line, i| format("%6d\t%s", i + offset, line) }.join("\n")

        trailer =
          if byte_cap_hit
            "(Output capped at #{MAX_BYTES_LABEL}. Showing lines #{offset}-#{last_line}. " \
              "Use offset=#{last_line + 1} to continue.)"
          elsif has_more
            "(Showing lines #{offset}-#{last_line} of #{total_lines}. " \
              "Use offset=#{last_line + 1} to continue.)"
          else
            "(End of file - total #{total_lines} lines)"
          end

        "#{body}\n\n#{trailer}"
      end
      private_class_method :format_slice

      # PDF counterpart to {.format_slice}: walk +pdf-reader+'s lazy page
      # iterator, emit a +"--- Page N ---"+ header followed by each line
      # of the page's extracted text, and apply the same offset / limit /
      # MAX_BYTES contract. Stops parsing as soon as the cap is hit so a
      # 500-page PDF only touches the few pages needed for the requested
      # window — the file handle stays open inside the +throw :done+
      # block, which short-circuits both the inner line loop and the
      # outer page loop in one move.
      #
      # The +has_more+ trailer here cannot quote a total line count the
      # way text files do — we'd have to parse every page just to count.
      # Instead we drop the "of N lines" claim and stick to the
      # next-offset hint, which is all the model needs to page.
      #
      # @return [String]
      def self.format_pdf(path:, resolved:, offset:, limit:)
        start_index   = offset - 1
        collected     = []
        total_lines   = 0
        bytes         = 0
        byte_cap_hit  = false
        has_more      = false

        catch(:done) do
          resolved.open('rb') do |io|
            reader = ::PDF::Reader.new(io)
            reader.pages.each_with_index do |page, idx|
              text = page.text.strip
              next if text.empty?

              page_lines = ["--- Page #{idx + 1} ---", *text.split("\n")]
              page_lines.each do |raw|
                total_lines += 1
                next if total_lines <= start_index

                if collected.length >= limit
                  has_more = true
                  throw :done
                end

                line = raw
                if line.length > MAX_LINE_LENGTH
                  line = line[0, MAX_LINE_LENGTH] + LINE_TRUNCATION_MARKER
                end

                size = line.bytesize + 1
                if bytes + size > MAX_BYTES
                  byte_cap_hit = true
                  has_more = true
                  throw :done
                end

                collected << line
                bytes += size
              end
            end
          end
        end

        return '(PDF has no extractable text; likely scanned image content)' if total_lines.zero?

        if start_index >= total_lines
          return "Error: offset #{offset} is beyond end of file (#{total_lines} lines total)"
        end

        last_line = offset + collected.length - 1
        body = collected.each_with_index.map { |line, i| format("%6d\t%s", i + offset, line) }.join("\n")

        trailer =
          if byte_cap_hit
            "(Output capped at #{MAX_BYTES_LABEL}. Showing PDF lines #{offset}-#{last_line}. " \
              "Use offset=#{last_line + 1} to continue.)"
          elsif has_more
            "(Showing PDF lines #{offset}-#{last_line}. " \
              "Use offset=#{last_line + 1} to continue.)"
          else
            "(End of PDF - total #{total_lines} lines)"
          end

        "#{body}\n\n#{trailer}"
      rescue ::PDF::Reader::MalformedPDFError,
             ::PDF::Reader::InvalidPageError,
             ::PDF::Reader::UnsupportedFeatureError => e
        "Error: cannot extract PDF text from #{path}: #{e.class.name.split('::').last}: #{e.message}"
      end
      private_class_method :format_pdf
    end
  end
end
