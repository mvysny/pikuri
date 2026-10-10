# frozen_string_literal: true

module Pikuri
  class Tool
    # What every {Pikuri::Tool} returns: the observation the model reads, plus
    # the one-line status a chrome renders in its place.
    #
    #   hits = cascade.search(query, max_results: max_results)
    #   Tool::Result.new(content: render_markdown(hits),
    #                    summary: "Returned #{hits.size} search results")
    #
    #   #  → WebSearch(rails 8 credentials)
    #   #      Returned 23 search results
    #
    # A recoverable failure is a {.error} — the +"Error: ..."+ observation the
    # LLM reacts to, with the message as its own display line:
    #
    #   return Tool::Result.error("offset must be >= 1, got #{offset}") if offset < 1
    #
    # == Text or an attachment, and the one rule for choosing
    #
    # +content+ is always the text the model reads. +attachments+ is non-empty
    # only when the observation **is** the attached bytes — the image
    # {Pikuri::Workspace::Read} answers for a PNG, with +content+ a short note:
    #
    #   note = "Read image: #{path} (#{size} bytes, #{mime})"
    #   Tool::Result.new(content: note, attachments: [RubyLLM::Attachment.new(resolved.to_s)],
    #                    summary: Pikuri::Tool.one_line(note))
    #
    # The test is not "does this tool touch a file" but "is there anything to
    # read here besides the attached bytes"; a PDF is text (extracted, paged,
    # counted), a PNG is not.
    #
    # An attachment's display line is *derived* rather than authored
    # ({Pikuri::Tool.describe_content} answers +"Returned image/png, 27.1 kB"+),
    # because mime and size are the only structure there is — so pass any
    # +summary+ you like and expect the derived one to win. That falls out of
    # how the value crosses into ruby_llm: {Pikuri::Tool#to_ruby_llm_tool}'s
    # wrapper hands an attachment Result over as a +[content, *attachments]+
    # Array, the one shape ruby_llm sends as a multimodal tool message, and its
    # +after_tool_result+ callback then sees that Array, not this Result. Text
    # takes the other branch: ruby_llm receives this +Result+, stores {#to_s},
    # and the listeners get {#summary} verbatim.
    #
    # == The two rules a summary obeys
    #
    # **Structural, never excerpted** — counts, sizes, exit codes; never the
    # first line of the page that was fetched. The user reads this line as
    # *status*, and those bytes are attacker-authorable.
    #
    # **Summaries are code** — computed by the tool's programmer from what the
    # tool counted, never from model output and never from a substring of
    # +content+. A narrated +Saved successfully+ over a failed write is exactly
    # what a prompt injection aims for.
    #
    # Immutable.
    Result = Data.define(:content, :summary, :attachments) do
      # The observation for a failure the LLM can act on — a bad argument, an
      # HTTP 4xx, a refused path. Bugs in pikuri's own code keep raising.
      #
      #   Tool::Result.error('no such task id: 7').content   # => "Error: no such task id: 7"
      #
      # The message doubles as the display line: an error *is* its own status,
      # which is the one place echoing the content is right. Only its **first
      # line** does, though — a {Parameters::ValidationError} reprints the whole
      # schema for the model to fix, and none of that belongs on a status row.
      #
      # @param message [String] what went wrong, without the +"Error: "+ prefix
      #   (already prefixed is fine — it is not doubled). May be multi-line; the
      #   model gets all of it.
      # @param detail [String, nil] further observation text for the model,
      #   appended after a blank line (the current task list, a failing
      #   command's output).
      # @return [Result]
      def self.error(message, detail: nil)
        text = message.to_s
        text = "Error: #{text}" unless text.start_with?('Error:')
        new(content: detail ? "#{text}\n\n#{detail}" : text,
            summary: Tool.one_line(text.lines.first))
      end

      # @param content [String] the text the model reads; for an attachment
      #   observation, the note beside the bytes.
      # @param summary [String] the display line; see the two rules above.
      # @param attachments [Array<RubyLLM::Attachment>] the bytes the
      #   observation *is*; see +== Text or an attachment+ above.
      # @raise [ArgumentError] if +content+ is not a String, an attachment is
      #   not a +RubyLLM::Attachment+, or +summary+ is not a single-line
      #   String — all programmer errors in tool code, so they raise rather
      #   than degrade.
      def initialize(content:, summary:, attachments: [])
        raise ArgumentError, "content must be a String, got #{content.class}" unless content.is_a?(String)
        unless attachments.all?(RubyLLM::Attachment)
          raise ArgumentError, "attachments must be RubyLLM::Attachments, got #{attachments.map(&:class)}"
        end
        raise ArgumentError, "summary must be a String, got #{summary.class}" unless summary.is_a?(String)
        raise ArgumentError, "summary must be one line, got #{summary.inspect}" if summary.include?("\n")

        super(content: content, summary: summary, attachments: attachments.dup.freeze)
      end

      # Whether the observation carries attached bytes — what decides which
      # value crosses into ruby_llm.
      #
      # @return [Boolean]
      def attachment? = !attachments.empty?

      # @return [Boolean] whether this is a recoverable failure, i.e. an
      #   observation the LLM should try to correct rather than build on.
      def error? = content.start_with?('Error:')

      # @return [String] {#content} — what ruby_llm stores for a text tool
      #   message.
      def to_s = content
    end
  end
end
