# frozen_string_literal: true

module Pikuri
  class Tool
    # Namespace marker matching the file path. The actual search
    # orchestration lives in {Tool::Search::Engines}; this file owns only
    # the LLM-facing {Tool::WEB_SEARCH} constant below.
    module WebSearch; end

    # Web-search tool exposed to the agent loop in OpenAI tool-call shape.
    # Calls {Tool::Search::Engines.search}, which cascades through whichever
    # providers are configured (DuckDuckGo always, Brave when its API key is
    # present) in random order, falling back on temporary-unavailability
    # errors. Providers return structured {Tool::Search::Result} rows;
    # +Engines.search+ renders the winning provider's rows into the
    # smolagents-style Markdown shape the LLM sees, so the format stays
    # stable regardless of which provider ran.
    #
    # @return [Tool]
    WEB_SEARCH = new(
      name: 'web_search',
      description: <<~DESC,
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - Use this to find candidate URLs, then call web_scrape on the most promising one(s) for full content. Snippets alone rarely answer a question.
      DESC
      parameters: Parameters.build { |p|
        p.required_string :query,
                          'The search query, e.g. "BigDecimal precision Ruby".'
        p.optional_integer :max_results,
                           'Maximum number of result entries to return. ' \
                           'Defaults to 10; most providers cap this at 20.'
      },
      execute: ->(query:, max_results: 10) { Search::Engines.search(query, max_results: max_results) }
    )
  end
end
