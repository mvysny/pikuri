# frozen_string_literal: true

require 'tool/search/duckduckgo'
require 'tool/search/brave'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order, and exposing it as +Tool::WEB_SEARCH+ requires +Tool+
# already be a class.
class Tool
  module Search
    # Raised by a provider when it is temporarily unavailable (rate-limited,
    # bot-blocked, quota-exhausted, or otherwise saying "try again later"
    # rather than "your request is wrong"). The cascade in {Search.search}
    # catches this and tries the next provider; any other exception bubbles
    # up unchanged so genuine bugs and config errors stay visible.
    class Unavailable < StandardError; end

    # All providers that are currently configured. {DuckDuckGo} is always
    # available (no API key needed); {Brave} joins the list when its API
    # token is present in the environment. Recomputed on every call so a
    # process picks up a newly-set token without a restart.
    #
    # @return [Array<Module>] +Tool::Search::*+ provider modules, each
    #   exposing +.search(query, max_results:)+ → Markdown
    def self.providers
      list = [DuckDuckGo]
      list << Brave unless ENV[Brave::ENV_KEY].to_s.strip.empty?
      list
    end

    # Run +query+ through the configured providers in random order, falling
    # back to the next one each time a provider raises {Unavailable}. The
    # shuffle spreads load so a single provider isn't always hit first
    # (and exhausted first); revisit if it stops being the right default.
    #
    # If every provider reports temporary unavailability, returns an
    # +"Error: ..."+ string instead of raising — same convention as
    # {Tool::Calculator.calculate}, so the agent loop can feed the failure
    # back to the model as the next observation. Any non-{Unavailable}
    # exception (network error, parser failure, malformed response, bad
    # API key) bubbles up to the caller.
    #
    # @param query [String] search query
    # @param max_results [Integer] maximum number of result entries
    # @return [String] Markdown-formatted result list, or +"Error: ..."+
    #   when all providers are exhausted
    def self.search(query, max_results:)
      failures = []
      providers.shuffle.each do |provider|
        return provider.search(query, max_results: max_results)
      rescue Unavailable => e
        failures << "#{provider.name.split('::').last} (#{e.message})"
      end
      "Error: all search providers temporarily unavailable: #{failures.join('; ')}"
    end
  end

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
                 'Use this only when you need information you don\'t ' \
                 'already know or that may have changed since your ' \
                 'training — current events, today\'s prices, latest ' \
                 'releases, specific obscure facts. For arithmetic, call ' \
                 '`calculator`; for established general knowledge, answer ' \
    'directly without searching. This tool is often rate-limited/bot-blocked. ' \
                 'The snippets are typically a sentence or two — ' \
                 'not the page contents — so they are rarely enough to ' \
                 'answer a question on their own. After running this ' \
                 'tool, pick the most promising URL(s) from the results ' \
                 'and call `web_fetch` on each to read the actual content.',
    parameters: Parameters.build { |p|
      p.required_string :query, 'The search query to perform.'
      p.optional_integer :max_results,
                         'Maximum number of result entries to return. ' \
                         'Defaults to 10; most providers cap this at 20.'
    },
    execute: ->(query:, max_results: 10) { Search.search(query, max_results: max_results) }
  )
end
