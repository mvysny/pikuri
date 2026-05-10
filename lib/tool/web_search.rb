# frozen_string_literal: true

class Tool
  # Namespace marker matching the file path. The actual search
  # orchestration lives in {Tool::Search}; this file owns only the
  # LLM-facing {Tool::WEB_SEARCH} constant below.
  module WebSearch; end

  # Web-search tool exposed to the agent loop in OpenAI tool-call shape.
  # Calls {Tool::Search.search}, which cascades through whichever providers
  # are configured (DuckDuckGo always, Brave when its API key is present)
  # in random order, falling back on temporary-unavailability errors. All
  # providers render their output in the same smolagents-style Markdown
  # shape, so the LLM sees a stable format regardless of which one ran.
  #
  # @return [Tool]
  WEB_SEARCH = new(
    name: 'web_search',
    description: 'Searches the web for a query and returns the top results ' \
                 'as a Markdown list of titles, links, and short snippets. ' \
                 'This tool is often ' \
                 'rate-limited/bot-blocked.',
    parameters: Parameters.build { |p|
      p.required_string :query, 'The search query to perform.'
      p.optional_integer :max_results,
                         'Maximum number of result entries to return. ' \
                         'Defaults to 10; most providers cap this at 20.'
    },
    execute: ->(query:, max_results: 10) { Search.search(query, max_results: max_results) }
  )
end
