# frozen_string_literal: true

require 'url_cache'

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

    # On-disk cache used by {.search} to memoize answered queries.
    # Defined as a method so specs can swap it for an isolated cache
    # or {UrlCache::NULL} without touching the shared instance.
    #
    # @return [UrlCache, #fetch]
    CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_search")
    def self.cache
      CACHE
    end

    # Run +query+ through the configured providers in random order, falling
    # back to the next one each time a provider raises {Unavailable}. The
    # shuffle spreads load so a single provider isn't always hit first
    # (and exhausted first); revisit if it stops being the right default.
    #
    # The query is whitespace-trimmed and runs of whitespace collapsed
    # to a single space before the cascade runs. Results are cached on
    # disk via {.cache}, keyed by the cleaned query, so a cache hit
    # short-circuits the cascade entirely (and benefits whichever
    # provider would have answered next time too — once a query is
    # cached, the cooldown state of the original answering provider no
    # longer matters). +max_results+ is not part of the cache key, so
    # callers passing a non-default value may get a result rendered
    # with the previously-cached size.
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
    # @raise [ArgumentError] if the query is empty after normalization
    def self.search(query, max_results:)
      cleaned = query.to_s.strip.gsub(/\s+/, ' ')
      raise ArgumentError, 'query is empty' if cleaned.empty?

      cache.fetch(cleaned) do
        failures = []
        result = nil
        providers.shuffle.each do |provider|
          result = provider.search(cleaned, max_results: max_results)
          break
        rescue Unavailable => e
          failures << "#{provider.name.split('::').last} (#{e.message})"
        end
        # Raise so {UrlCache#fetch} does NOT persist the all-unavailable
        # message — otherwise that string would block every future search
        # for this query until the TTL expires. The outer +rescue+ turns
        # the raise back into the calculator-style "Error: …" string.
        result or raise Unavailable, "all search providers temporarily unavailable: #{failures.join('; ')}"
      end
    rescue Unavailable => e
      "Error: #{e.message}"
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
