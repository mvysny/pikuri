# frozen_string_literal: true

module Pikuri
  class Tool
    # Namespace for the web-search stack behind {Tool::WebSearch}: per-provider
    # modules ({DuckDuckGo}, {Brave}, {Exa}), the {Result} they return, the
    # {Engines} cascade with its on-disk cache, and the shared {RateLimiter}.
    module Search
      # Search-orchestration object: the cascade across configured providers,
      # the result cache, and the {Unavailable} marker the cascade falls back
      # on. {Tool::WebSearch.build} constructs one and wires its {#search} into
      # a {Tool}. Each provider raises {Unavailable} to hand off to the next.
      #
      # == Provider keys are constructor config, not environment
      #
      # Brave and Exa are paid and need a key; DuckDuckGo needs none. An
      # {Engines} is built with the keys it should use (+brave_key:+ /
      # +exa_key:+, both optional) — pikuri reads no key from the environment,
      # so the cascade is DuckDuckGo plus whichever keyed providers the host
      # configured. See CLAUDE.md "Environment is not a secret store".
      class Engines
        # Subsystem logger; level via +PIKURI_LOG_ENGINES+ or +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Engines')

        # Raised by a provider that is temporarily unavailable (rate-limited,
        # bot-blocked, quota-exhausted — "try again later", not "your request is
        # wrong"). The {#search} cascade catches it and tries the next provider;
        # anything else bubbles up so genuine bugs stay visible.
        class Unavailable < StandardError; end

        # Process-shared on-disk cache backing {#search}, at class level so every
        # engine dedupes into one directory; the constructor's +cache:+ injects a
        # different store for tests.
        #
        # @return [UrlCache, #fetch]
        CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_search")
        # Accessor for {CACHE}, the constructor's +cache:+ default; specs swap in
        # {UrlCache::NULL}.
        #
        # @return [UrlCache, #fetch]
        def self.cache
          CACHE
        end

        # Build the provider cascade once: {DuckDuckGo} always, plus {Brave} /
        # {Exa} when their key is non-blank. From here each provider is just an
        # object answering +#search+/+#label+.
        #
        # @param brave_key [String, nil] Brave token; non-blank ⇒ Brave joins.
        # @param exa_key [String, nil] Exa key; non-blank ⇒ Exa joins.
        # @param cache [UrlCache, #fetch] result store; defaults to {.cache}.
        # @return [Engines]
        def initialize(brave_key: nil, exa_key: nil, cache: self.class.cache)
          @providers = [DuckDuckGo.new]
          @providers << Brave.new(api_key: brave_key) unless brave_key.to_s.strip.empty?
          @providers << Exa.new(api_key: exa_key) unless exa_key.to_s.strip.empty?
          @cache = cache
          @last_logged_providers = nil
        end

        # @return [Array<#search, #label>] configured provider instances, in
        #   declaration order (the cascade shuffles them per call).
        attr_reader :providers

        # Run +query+ through the providers in random order, falling back on each
        # {Unavailable}. The shuffle spreads load so one provider isn't always
        # hit (and exhausted) first. The query is whitespace-normalized first;
        # the winning provider's +Array<Result>+ is rendered to Markdown and
        # cached on disk keyed by the cleaned query (a hit short-circuits the
        # cascade). +max_results+ is *not* in the cache key, so a non-default
        # value may return a previously-cached size.
        #
        # If every provider is unavailable, returns an +"Error: ..."+ string
        # (the tool convention) rather than raising. Any non-{Unavailable}
        # exception (network, parser, bad key) bubbles up.
        #
        # @param query [String] search query
        # @param max_results [Integer] maximum result entries
        # @return [String] Markdown result list, or +"Error: ..."+ when all
        #   providers are exhausted
        # @raise [ArgumentError] if the query is empty after normalization
        def search(query, max_results:)
          cleaned = query.to_s.strip.gsub(/\s+/, ' ')
          raise ArgumentError, 'query is empty' if cleaned.empty?

          current_providers = providers
          log_providers(current_providers)

          hit = true
          result = @cache.fetch(cleaned) do
            hit = false
            failures = []
            results = nil
            chosen = nil
            current_providers.shuffle.each do |provider|
              results = provider.search(cleaned, max_results: max_results)
              chosen = provider
              break
            rescue Unavailable => e
              failures << "#{provider.label} (#{e.message})"
            end
            # Raise so {UrlCache#fetch} does NOT persist the all-unavailable
            # message — else it would block every future search for this query
            # until the TTL expires. The outer rescue turns it into "Error: …".
            chosen or raise Unavailable, "all search providers temporarily unavailable: #{failures.join('; ')}"

            LOGGER.info do
              "engine=#{chosen.label} query=#{cleaned.inspect} results=#{results.size}"
            end
            render(results)
          end
          LOGGER.info { "cache=hit query=#{cleaned.inspect} bytes=#{result.bytesize}" } if hit
          result
        rescue Unavailable => e
          "Error: #{e.message}"
        end

        private

        # Render an +Array<Result>+ into the smolagents-style Markdown the LLM
        # consumes (+"## Search Results"+ header, then +[title](url)\nbody+
        # joined by blank lines). Empty → the +"No results found."+ stub.
        #
        # @param results [Array<Result>] hits from the winning provider
        # @return [String] Markdown result list
        def render(results)
          return "## Search Results\n\nNo results found." if results.empty?

          "## Search Results\n\n" + results.map { |r| "[#{r.title}](#{r.url})\n#{r.body}" }.join("\n\n")
        end

        # INFO-log the currently-available providers, but only when the set
        # differs from the last logged — one line per distinct configuration,
        # not per search.
        #
        # @param current [Array<#label>] providers from {#providers}
        # @return [void]
        def log_providers(current)
          return if @last_logged_providers == current

          @last_logged_providers = current
          names = current.map(&:label).join(', ')
          LOGGER.info("engines available: #{names}")
        end
      end
    end
  end
end
