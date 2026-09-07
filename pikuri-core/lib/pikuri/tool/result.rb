# frozen_string_literal: true

module Pikuri
  class Tool
    # An observation plus the one-line status a chrome renders in its place —
    # what an +execute+ returns when the display line is derived from structure
    # the flattened content no longer holds:
    #
    #   hits = cascade.search(query, max_results: max_results)
    #   Tool::Result.new(content: render_markdown(hits),
    #                    summary: "Returned #{hits.size} search results")
    #
    #   #  → WebSearch(rails 8 credentials)
    #   #      Returned 23 search results
    #
    # The model still sees +content+ and nothing else: ruby_llm stores a
    # non-+Content+ tool payload via +to_s+, which here answers {#content},
    # while the summary rides {Pikuri::Agent::Event::ToolResult} to the
    # listeners. A tool with
    # nothing structural to add returns a bare String and gets
    # {Pikuri::Tool.describe_content}'s generic line; one whose summary really
    # is a function of its content (+calculator+: the value) overrides
    # {Pikuri::Tool#describe_result} instead.
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
      # @param content [String] the observation the model sees. A +String+ only
      #   — a tool answering +RubyLLM::Content+ (the PNG {Workspace::Read}
      #   returns) keeps returning it bare, so that nothing here has to reach
      #   into ruby_llm's +content_like?+; see +DECISIONS.md+
      #   +D_tool_summary_lines+.
      # @param summary [String] the display line; see the two rules above.
      # @raise [ArgumentError] if +content+ is not a String, or +summary+ is not
      #   a single-line String — both are programmer errors in tool code, so
      #   they raise rather than degrade.
      def initialize(content:, summary:)
        raise ArgumentError, "content must be a String, got #{content.class}" unless content.is_a?(String)
        raise ArgumentError, "summary must be a String, got #{summary.class}" unless summary.is_a?(String)
        raise ArgumentError, "summary must be one line, got #{summary.inspect}" if summary.include?("\n")

        super
      end

      # @return [String] {#content} — what ruby_llm stores as the tool message.
      def to_s = content
    end
  end
end
