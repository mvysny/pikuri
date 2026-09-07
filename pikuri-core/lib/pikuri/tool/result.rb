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
    # +content+ is a +String+ for everything the model reads as *text*. It is a
    # +RubyLLM::Content+ only when the observation **is** the attachment — the
    # image {Pikuri::Workspace::Read} answers for a PNG. The test is not "does
    # this tool touch a file" but "is there anything to read here besides the
    # attached bytes"; a PDF is text (extracted, paged, counted), a PNG is not.
    #
    # An attachment's display line is *derived* rather than authored
    # ({Pikuri::Tool.describe_content} answers +"Returned image/png, 27.1 kB"+),
    # because mime and size are the only structure there is — so pass any
    # +summary+ you like and expect the derived one to win. That falls out of
    # how the value crosses into ruby_llm: {Pikuri::Tool#to_ruby_llm_tool}'s
    # wrapper hands the bare +RubyLLM::Content+ over for an attachment, since
    # ruby_llm's +content_like?+ is an +is_a?+ test that a +Result+ cannot pass,
    # and its +after_tool_result+ callback then sees the same unwrapped value.
    # Text takes the other branch: ruby_llm receives this +Result+, stores
    # {#to_s}, and the listeners get {#summary} verbatim.
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
    Result = Data.define(:content, :summary) do
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

      # @param content [String, RubyLLM::Content] the observation the model
      #   sees; a +RubyLLM::Content+ only for an attachment observation, see
      #   +== Text or an attachment+ above.
      # @param summary [String] the display line; see the two rules above.
      # @raise [ArgumentError] if +content+ is neither, or +summary+ is not a
      #   single-line String — both are programmer errors in tool code, so they
      #   raise rather than degrade.
      def initialize(content:, summary:)
        unless content.is_a?(String) || content.is_a?(RubyLLM::Content)
          raise ArgumentError, "content must be a String or RubyLLM::Content, got #{content.class}"
        end
        raise ArgumentError, "summary must be a String, got #{summary.class}" unless summary.is_a?(String)
        raise ArgumentError, "summary must be one line, got #{summary.inspect}" if summary.include?("\n")

        super
      end

      # Whether {#content} carries attached bytes rather than text — what
      # decides which value crosses into ruby_llm.
      #
      # @return [Boolean]
      def attachment? = content.is_a?(RubyLLM::Content)

      # @return [Boolean] whether this is a recoverable failure, i.e. an
      #   observation the LLM should try to correct rather than build on.
      def error? = content.is_a?(String) && content.start_with?('Error:')

      # @return [String] the observation as text — what ruby_llm stores for a
      #   text tool message, and the attachment's note for an attachment.
      def to_s = attachment? ? content.text.to_s : content
    end
  end
end
