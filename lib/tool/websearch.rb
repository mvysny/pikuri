# frozen_string_literal: true

require 'tool/search/duckduckgo'
require 'tool/search/brave'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order, and exposing it as +Tool::WEB_SEARCH+ requires +Tool+
# already be a class.
class Tool
  module Search
    # Pick the search provider based on which API tokens are present in
    # the environment. Higher-quality (paid) providers win over the free
    # DDG scrape; without any token configured the result is {DuckDuckGo}.
    #
    # The selection is deterministic for a given ENV but recomputed on
    # every call, so a process can pick up a newly-set token without a
    # restart (mostly useful for tests that toggle ENV).
    #
    # @return [Module] one of the +Tool::Search::*+ provider modules,
    #   each exposing +.search(query, max_results:)+ → Markdown
    def self.provider
      if ENV[Brave::ENV_KEY].to_s.strip.empty?
        DuckDuckGo
      else
        Brave
      end
    end
  end

  # Web-search tool exposed to the agent loop in OpenAI tool-call shape.
  # The actual provider is chosen at call time by {Tool::Search.provider}
  # based on which API keys are configured. All providers render their
  # output in the same smolagents-style Markdown shape, so the LLM sees
  # a stable format regardless of which one ran.
  #
  # @return [Tool]
  WEB_SEARCH = new(
    name: 'web_search',
    description: 'Searches the web for a query and returns the top results ' \
                 'as a Markdown list of titles, links, and short snippets. ' \
                 'The snippets are typically a sentence or two — not the ' \
                 'page contents — so they are rarely enough to answer a ' \
                 'question on their own. After running this tool, pick the ' \
                 'most promising URL(s) from the results and call ' \
                 '`web_fetch` on each to read the actual content.',
    parameters: Parameters.build { |p|
      p.required_string :query, 'The search query to perform.'
      p.optional_integer :max_results,
                         'Maximum number of result entries to return. ' \
                         'Defaults to 10; most providers cap this at 20.'
    },
    execute: ->(query:, max_results: 10) { Search.provider.search(query, max_results: max_results) }
  )
end
