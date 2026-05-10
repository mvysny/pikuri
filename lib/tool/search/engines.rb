# frozen_string_literal: true

class Tool
  module Search
    # Search-orchestration entry point: the cascade across configured
    # providers, the result cache, and the {Unavailable} protocol marker
    # the cascade uses to fall back. The LLM-facing tool itself
    # ({Tool::WEB_SEARCH}) lives in +lib/tool/web_search.rb+ and calls
    # into {.search} below. Each {Tool::Search} provider module
    # ({DuckDuckGo}, {Brave}) raises {Unavailable} when it wants the
    # cascade to try the next one.
    module Engines
      # Raised by a provider when it is temporarily unavailable (rate-limited,
      # bot-blocked, quota-exhausted, or otherwise saying "try again later"
      # rather than "your request is wrong"). The cascade in {Engines.search}
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
  end
end
