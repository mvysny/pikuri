# frozen_string_literal: true

module Pikuri
  class Tool
    # Builder for the LLM-facing web-search tool. Orchestration lives in
    # {Tool::Search::Engines}; this owns only the {.build} factory wiring a
    # configured {Search::Engines} into a {Tool}.
    #
    # Unlike the stateless bundled tools (shared value constants), web_search is
    # *host-configured*: the paid providers (Brave/Exa) join the cascade only
    # when the host passes their key, so it's built per-wiring (like
    # {Code::Bash}), not a shared constant. pikuri reads no key from the
    # environment — the host supplies them (CLAUDE.md "Environment is not a
    # secret store").
    module WebSearch
      # Description shown to the LLM, opencode-shape (summary + +Usage:+).
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - Use this to find candidate URLs, then call web_scrape on the most promising one(s) for full content. Snippets alone rarely answer a question.
      DESC

      # Build the +web_search+ tool. Calls {Search::Engines#search}, which
      # cascades DuckDuckGo (always) plus configured keyed providers in random
      # order, falling back on unavailability and rendering the winner's rows to
      # a stable Markdown shape.
      #
      # @param brave_key [String, nil] Brave key; non-blank ⇒ Brave joins
      #   (https://api-dashboard.search.brave.com).
      # @param exa_key [String, nil] Exa key; non-blank ⇒ Exa joins (https://exa.ai).
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      def self.build(brave_key: nil, exa_key: nil)
        engines = Search::Engines.new(brave_key: brave_key, exa_key: exa_key)
        Tool.new(
          name: 'web_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'The search query, e.g. "BigDecimal precision Ruby".'
            p.optional_integer :max_results,
                               'Maximum number of result entries to return. ' \
                               'Defaults to 10; most providers cap this at 20.'
          },
          execute: ->(query:, max_results: 10) { engines.search(query, max_results: max_results) }
        )
      end
    end
  end
end
