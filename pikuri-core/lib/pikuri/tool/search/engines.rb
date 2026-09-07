# frozen_string_literal: true

module Pikuri
  class Tool
    # Namespace for the web-search stack behind {Tool::WebSearch}: per-provider
    # modules ({DuckDuckGo}, {Brave}, {Exa}), the {Result} they return, the
    # {Engines} cascade with its on-disk cache, and the shared {RateLimiter}.
    module Search
      # Search-orchestration object: the cascade across selected providers, the
      # result cache, and the {Unavailable} marker the cascade falls back on.
      # {Tool::WebSearch.build} constructs one and wires its {#search} into a
      # {Tool}. Each provider raises {Unavailable} to hand off to the next.
      #
      #   Engines.new(engines: [:brave], brave_key: 'BSA...')  # Brave alone
      #   Engines.new(brave_key: 'BSA...')                     # DuckDuckGo + Brave
      #   Engines.new                                          # DuckDuckGo alone
      #
      # {.resolve} owns which engines that yields and which selections are
      # refused; {.config_from_h} maps a config file's +search:+ block onto
      # these keywords.
      #
      # == Provider keys are constructor config, not environment
      #
      # Brave and Exa are paid and need a key; DuckDuckGo needs none. An
      # {Engines} is built with the keys it should use (+brave_key:+ /
      # +exa_key:+, both optional) — pikuri reads no key from the environment,
      # so a host supplies them. See CLAUDE.md "Environment is not a secret
      # store".
      class Engines
        # Subsystem logger; level via +PIKURI_LOG_ENGINES+ or +PIKURI_LOG+.
        #
        # @return [Logger]
        LOGGER = Pikuri.logger_for('Engines')

        # Every engine name accepted in an +engines:+ selection, in the order
        # {#providers} reports them. Presentation only — {#search} shuffles.
        #
        # @return [Array<Symbol>]
        ENGINE_NAMES = %i[duckduckgo brave exa].freeze

        # Engine name → the constructor keyword carrying its API key. Naming
        # one of these without its key is a refusal ({.resolve}); DuckDuckGo is
        # absent because it needs none.
        #
        # @return [Hash{Symbol => Symbol}]
        KEYED_ENGINES = { brave: :brave_key, exa: :exa_key }.freeze

        # The fields {.config_from_h} accepts from a config file's +search:+
        # block, matching this class's keywords.
        #
        # @return [Array<Symbol>]
        CONFIG_FIELDS = %i[engines brave_key exa_key].freeze

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

        # Resolve an +engines:+ selection into the engine names to build,
        # refusing a selection that cannot work:
        #
        #   resolve(engines: nil, brave_key: 'B')          # => [:duckduckgo, :brave]
        #   resolve(engines: nil)                          # => [:duckduckgo]
        #   resolve(engines: %w[brave], brave_key: 'B')    # => [:brave]
        #   resolve(engines: [:exa], brave_key: 'B')       # raises — exa has no key
        #
        # +nil+ means "whatever the keys say": DuckDuckGo plus every engine
        # whose key is present, which is what a host that never heard of
        # +engines:+ gets. An explicit list is a **set** — it is normalized to
        # {ENGINE_NAMES} order and {#search} shuffles it per call anyway, so
        # +[brave, duckduckgo]+ expresses no preference for Brave. Names are
        # matched case-insensitively.
        #
        # Supplying a key without listing its engine is fine — parking a key
        # you are not using today is not a mistake.
        #
        # @param engines [Array<String, Symbol>, nil] engine names, or +nil+ to
        #   derive the set from the keys.
        # @param brave_key [String, nil] Brave token; blank counts as absent.
        # @param exa_key [String, nil] Exa key; blank counts as absent.
        # @return [Array<Symbol>] names drawn from {ENGINE_NAMES}, in that order.
        # @raise [ArgumentError] if +engines+ is not an Array, is empty, holds
        #   an unknown or repeated name, or names a {KEYED_ENGINES} engine
        #   whose key is blank.
        def self.resolve(engines:, brave_key: nil, exa_key: nil)
          keys = { brave: brave_key, exa: exa_key }
          keyless = ->(name) { KEYED_ENGINES.key?(name) && keys[name].to_s.strip.empty? }
          return ENGINE_NAMES.reject(&keyless) if engines.nil?

          unless engines.is_a?(Array) && !engines.empty?
            # A list of engine names is safe to echo; anything else might be a
            # key the writer put in the wrong field, so show only its class.
            got = engines.is_a?(Array) ? engines.inspect : engines.class
            raise ArgumentError, 'search engines: expected a non-empty list of engine names ' \
                                 "(known: #{ENGINE_NAMES.join(', ')}), got #{got}"
          end

          names = engines.map { |name| name.to_s.strip.downcase.to_sym }
          refuse_unknown(names)
          refuse_repeats(names)
          refuse_keyless(names.select(&keyless))
          ENGINE_NAMES & names
        end

        # @param names [Array<Symbol>] the requested engine names.
        # @return [void]
        # @raise [ArgumentError] if any name is not in {ENGINE_NAMES}.
        def self.refuse_unknown(names)
          unknown = names - ENGINE_NAMES
          return if unknown.empty?

          raise ArgumentError, "search engines: unknown engine(s) #{unknown.join(', ')} — " \
                               "known engines are #{ENGINE_NAMES.join(', ')}"
        end

        # @param names [Array<Symbol>] the requested engine names.
        # @return [void]
        # @raise [ArgumentError] if any name appears twice (which would put one
        #   provider into the cascade twice, weighting the shuffle).
        def self.refuse_repeats(names)
          repeated = names.tally.select { |_, count| count > 1 }.keys
          return if repeated.empty?

          raise ArgumentError, "search engines: #{repeated.join(', ')} listed more than once"
        end

        # @param keyless [Array<Symbol>] requested engines with no usable key.
        # @return [void]
        # @raise [ArgumentError] unless +keyless+ is empty.
        def self.refuse_keyless(keyless)
          return if keyless.empty?

          needed = keyless.map { |name| "#{name} needs #{KEYED_ENGINES[name]}" }.join(', ')
          raise ArgumentError, "search engines: #{needed} — supply the key or drop the engine from the list"
        end

        # Map a config file's +search:+ block onto this class's keywords, so a
        # host hands over what it read:
        #
        #   # ~/.pikuri-examples-config.yaml
        #   search:
        #     brave_key: BSA...
        #     exa_key: xyz
        #     engines: [brave, duckduckgo]
        #
        #   Tool::WebSearch.from_h(YAML.safe_load_file(path)['search'])
        #
        # Nothing here knows what YAML is; a host reading TOML, JSON or its own
        # settings object uses the same method. Every field is validated rather
        # than coerced, because the person writing a config file cannot
        # type-check it — and a mistyped engine name that silently meant "no
        # Brave" would show up only as worse search results.
        #
        # @param config [Hash{String, Symbol => Object}, nil] the +search:+
        #   block, with String or Symbol keys. +nil+ — what a host reading an
        #   absent config key gets — yields an empty Hash, so no caller needs a
        #   +|| {}+.
        # @return [Hash{Symbol => Object}] +engines:+ / +brave_key:+ /
        #   +exa_key:+ keywords for {#initialize} or {Tool::WebSearch.build}.
        # @raise [ArgumentError] on a non-Hash, an unknown field, or a key field
        #   that is not a String.
        def self.config_from_h(config)
          return {} if config.nil?

          unless config.is_a?(Hash)
            raise ArgumentError, 'search config: expected a Hash of ' \
                                 "#{CONFIG_FIELDS.join(', ')}, got #{config.class}"
          end

          fields = config.transform_keys(&:to_sym)
          unknown = fields.keys - CONFIG_FIELDS
          unless unknown.empty?
            raise ArgumentError, "search config: unknown field(s) #{unknown.join(', ')} — " \
                                 "known fields are #{CONFIG_FIELDS.join(', ')}"
          end
          KEYED_ENGINES.each_value do |field|
            value = fields[field]
            next if value.nil? || value.is_a?(String)

            # The class, never the value: an error message about a key field is
            # one paste away from a bug report.
            raise ArgumentError, "search config: #{field} must be a String, got #{value.class}"
          end
          fields
        end

        # Builds the provider cascade once, from the engines {.resolve} selects.
        # From here each provider is just an object answering
        # +#search+/+#label+.
        #
        # @param engines [Array<String, Symbol>, nil] engine names; +nil+
        #   derives the set from the keys. See {.resolve}.
        # @param brave_key [String, nil] Brave token.
        # @param exa_key [String, nil] Exa key.
        # @param cache [UrlCache, #fetch] result store; defaults to {.cache}.
        # @return [Engines]
        # @raise [ArgumentError] as {.resolve}.
        def initialize(engines: nil, brave_key: nil, exa_key: nil, cache: self.class.cache)
          @providers = self.class.resolve(engines: engines, brave_key: brave_key, exa_key: exa_key).map do |name|
            case name
            when :duckduckgo then DuckDuckGo.new
            when :brave then Brave.new(api_key: brave_key)
            when :exa then Exa.new(api_key: exa_key)
            end
          end
          @cache = cache
          @last_logged_providers = nil
        end

        # @return [Array<#search, #label>] the selected provider instances, in
        #   {ENGINE_NAMES} order (the cascade shuffles them per call).
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
        # @param cancellable [Pikuri::Agent::Control::Cancellable, nil] handed
        #   to each provider so its {RateLimiter} pacing wait is interruptible.
        #   A cache hit never reaches a provider, so it never waits at all.
        # @return [String] Markdown result list, or +"Error: ..."+ when all
        #   providers are exhausted
        # @raise [ArgumentError] if the query is empty after normalization
        # @raise [Pikuri::Agent::Control::Cancellable::Cancelled] if
        #   +cancellable+ trips while a provider is pacing. It is *not* caught
        #   as a provider failure — the cascade stops rather than trying the
        #   next one, and nothing is cached.
        def search(query, max_results:, cancellable: Pikuri::Agent::Control::Cancellable::NEVER)
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
              results = provider.search(cleaned, max_results: max_results, cancellable: cancellable)
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
          Tool::Result.new(
            content: result,
            summary: "Returned #{Pikuri::Tool.pluralize(count_rendered(result), 'search result')}"
          )
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

        # How many rows a rendering holds, counted back off the Markdown rather
        # than off the {Result} structs: a cache hit has only the Markdown, and
        # a display line that appeared on a miss and vanished on a hit would be
        # worse than one a hostile snippet can inflate by opening with a link of
        # its own.
        #
        # @param markdown [String] what {#render} produced
        # @return [Integer]
        def count_rendered(markdown)
          markdown.lines.count { |line| line.match?(%r{\A\[[^\]]*\]\(\S+\)}) }
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
