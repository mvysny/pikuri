# frozen_string_literal: true

module Pikuri
  class Tool
    # Namespace for the web-search stack used by {Tool::WebSearch}: per-
    # provider modules ({DuckDuckGo}, {Brave}, {Exa}), the {Result} value
    # object they all return, the cross-provider {Engines} cascade with
    # its on-disk cache, and the shared {RateLimiter} a provider can wire
    # in to back off when a quota header says so.
    module Search
      # Search-orchestration object: the cascade across configured
      # providers, the result cache, and the {Unavailable} protocol marker
      # the cascade uses to fall back. The LLM-facing tool itself is built
      # by {Tool::WebSearch.build}, which constructs one of these and wires
      # its {#search} into a {Tool}. Each {Tool::Search} provider module
      # ({DuckDuckGo}, {Brave}, {Exa}) raises {Unavailable} when it wants
      # the cascade to try the next one.
      #
      # == Provider keys are constructor config, not environment
      #
      # Brave and Exa are paid and need an API key; DuckDuckGo needs none.
      # An {Engines} is constructed with the keys it should use
      # (+brave_key:+ / +exa_key:+, both optional) — pikuri reads no key
      # from the environment, so the only providers in the cascade are
      # DuckDuckGo plus whichever keyed providers the host actually
      # configured. The host sources those keys however it likes (the
      # bundled +bin/+ examples load a JSON config file by convention); see
      # CLAUDE.md "Environment is not a secret store".
      class Engines
        # Subsystem logger; set its level with +PIKURI_LOG_ENGINES+
        # (e.g. +PIKURI_LOG_ENGINES=debug+) or the global +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Engines')

        # Raised by a provider when it is temporarily unavailable (rate-limited,
        # bot-blocked, quota-exhausted, or otherwise saying "try again later"
        # rather than "your request is wrong"). The cascade in {#search}
        # catches this and tries the next provider; any other exception bubbles
        # up unchanged so genuine bugs and config errors stay visible.
        class Unavailable < StandardError; end

        # Process-shared on-disk cache backing {#search}'s default. Kept at
        # class level (not per-instance) so every engine dedupes answered
        # queries into one directory; the constructor's +cache:+ parameter
        # injects a different store for tests. Exposed as a method so specs
        # can swap it for {UrlCache::NULL} without touching the instance.
        #
        # @return [UrlCache, #fetch]
        CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_search")
        # Accessor for {CACHE}, used as the constructor's +cache:+ default;
        # specs override this to swap in {UrlCache::NULL}.
        #
        # @return [UrlCache, #fetch]
        def self.cache
          CACHE
        end

        # Builds the provider cascade once: {DuckDuckGo} always (no key
        # needed), plus {Brave} / {Exa} when their key was supplied
        # (non-blank). Each keyed provider is constructed with its key, so
        # from here on every provider is just an object answering +#search+
        # / +#label+ — the cascade in {#search} treats them uniformly.
        #
        # @param brave_key [String, nil] Brave Search subscription token;
        #   non-blank ⇒ Brave joins the cascade. +nil+/blank ⇒ not configured.
        # @param exa_key [String, nil] Exa API key; non-blank ⇒ Exa joins the
        #   cascade. +nil+/blank ⇒ not configured.
        # @param cache [UrlCache, #fetch] result store memoizing answered
        #   queries; defaults to the process-shared {.cache}.
        # @return [Engines]
        def initialize(brave_key: nil, exa_key: nil, cache: self.class.cache)
          @providers = [DuckDuckGo.new]
          @providers << Brave.new(api_key: brave_key) unless brave_key.to_s.strip.empty?
          @providers << Exa.new(api_key: exa_key) unless exa_key.to_s.strip.empty?
          @cache = cache
          @last_logged_providers = nil
        end

        # The provider instances this engine cascades across, in
        # declaration order (the cascade itself shuffles them per call).
        #
        # @return [Array<#search, #label>] configured provider instances
        attr_reader :providers

        # Run +query+ through the configured providers in random order, falling
        # back to the next one each time a provider raises {Unavailable}. The
        # shuffle spreads load so a single provider isn't always hit first
        # (and exhausted first); revisit if it stops being the right default.
        #
        # The query is whitespace-trimmed and runs of whitespace collapsed
        # to a single space before the cascade runs. The winning provider's
        # +Array<Result>+ is rendered into smolagents-style Markdown here
        # (+"## Search Results"+ header, then +[title](url)\nbody+ entries
        # joined by blank lines; an empty array becomes +"No results found."+),
        # and the rendered Markdown is cached on disk via {#initialize}'s
        # +cache:+, keyed by the cleaned query. A cache hit short-circuits the
        # cascade entirely (and benefits whichever provider would have
        # answered next time too — once a query is cached, the cooldown state
        # of the original answering provider no longer matters). +max_results+
        # is not part of the cache key, so callers passing a non-default value
        # may get a result rendered with the previously-cached size.
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
            # message — otherwise that string would block every future search
            # for this query until the TTL expires. The outer +rescue+ turns
            # the raise back into the calculator-style "Error: …" string.
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

        # Render an +Array<Result>+ into the smolagents-style Markdown the
        # LLM consumes: +"## Search Results"+ header, then +[title](url)\nbody+
        # entries joined by blank lines. An empty array becomes the
        # +"No results found."+ stub so the agent still gets a real
        # observation to act on.
        #
        # @param results [Array<Result>] hits from the winning provider
        # @return [String] Markdown-formatted result list
        def render(results)
          return "## Search Results\n\nNo results found." if results.empty?

          "## Search Results\n\n" + results.map { |r| "[#{r.title}](#{r.url})\n#{r.body}" }.join("\n\n")
        end

        # Emit an INFO log line listing the currently-available providers,
        # but only when the set differs from the last one this engine
        # logged. The memo keeps the log to one line per distinct
        # configuration rather than one per search.
        #
        # @param current [Array<#label>] providers returned by {#providers}
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
