# frozen_string_literal: true

require 'json'

module Pikuri
  module Web
    # Namespace for the web-search stack behind {Web::Search}: per-provider
    # modules ({DuckDuckGo}, {Brave}, {Exa}), the {Result} they return, the
    # {Engines} cascade with its result caches, and the shared {RateLimiter}.
    module Search
      # Search-orchestration object: the cascade across selected providers, the
      # result cache, and the {Unavailable} marker the cascade falls back on.
      # {Web::Search.build} constructs one and wires its {#search} into a
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
      # so a host supplies them. See AGENTS.md "Environment is not a secret
      # store".
      #
      # == Page text
      #
      # Built with +page_text: true+, Brave and Exa also bring back each page's
      # text from their own index, in the same request. {#search} stores it in
      # a {PageStore} and prints the row's handle before its title, for
      # +web_read_cached+ to read:
      #
      #   [a3f9c21e] [Ruby Data](https://docs.ruby-lang.org/en/3.4/Data.html)
      #   Data objects are immutable.
      #
      # A row gets a handle only when *this* search returned its text — never a
      # DuckDuckGo row — even if the store holds that URL from another search.
      # So an +engines: nil+ selection leaves DuckDuckGo out in this mode: in a
      # shuffled cascade it would win about every other search and leave the
      # model nothing to read. A host that lists it explicitly keeps it. The
      # two modes cache apart ({DISK_TEXT_CACHE}, {MEMORY_TEXT_CACHE}): they
      # return different rows.
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

        # Engines that can bring back page text; +page_text: true+ needs one.
        #
        # @return [Array<Symbol>]
        PAGE_TEXT_ENGINES = %i[brave exa].freeze

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

        # On-disk result cache for providers whose +disk_cacheable?+ is true, at
        # class level so every engine dedupes into one directory. An entry is
        # the rows as JSON, never rendered Markdown: handles are looked up at
        # render time.
        #
        # @return [UrlCache::OnDisk]
        DISK_CACHE = UrlCache::OnDisk.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_search")

        # In-memory result cache for the rest (Brave, Exa: their terms forbid
        # storing results), shared by every engine in the process.
        #
        # @return [UrlCache::InMemory]
        MEMORY_CACHE = UrlCache::InMemory.new(ttl: UrlCache::DEFAULT_TTL, max_entries: 100)

        # {DISK_CACHE}'s twin for +page_text: true+ engines.
        #
        # @return [UrlCache::OnDisk]
        DISK_TEXT_CACHE = UrlCache::OnDisk.new(ttl: UrlCache::DEFAULT_TTL,
                                               dir: "#{UrlCache::ROOT_DIR}/web_search_text")

        # {MEMORY_CACHE}'s twin for +page_text: true+ engines.
        #
        # @return [UrlCache::InMemory]
        MEMORY_TEXT_CACHE = UrlCache::InMemory.new(ttl: UrlCache::DEFAULT_TTL, max_entries: 100)

        # The constructor's +disk_cache:+ default; specs swap in {UrlCache::NULL}.
        #
        # @param page_text [Boolean] which mode's cache
        # @return [UrlCache::OnDisk, #read, #write]
        def self.disk_cache(page_text: false)
          page_text ? DISK_TEXT_CACHE : DISK_CACHE
        end

        # The constructor's +memory_cache:+ default; specs swap in
        # {UrlCache::NULL}.
        #
        # @param page_text [Boolean] which mode's cache
        # @return [UrlCache::InMemory, #read, #write]
        def self.memory_cache(page_text: false)
          page_text ? MEMORY_TEXT_CACHE : MEMORY_CACHE
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
        #   Web::Search.from_h(YAML.safe_load_file(path)['search'])
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
        #   +exa_key:+ keywords for {#initialize} or {Web::Search.build}.
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
        # +#search+/+#label+/+#disk_cacheable?+.
        #
        # @param engines [Array<String, Symbol>, nil] engine names; +nil+
        #   derives the set from the keys (see {.resolve}), minus DuckDuckGo
        #   under +page_text+.
        # @param brave_key [String, nil] Brave token.
        # @param exa_key [String, nil] Exa key.
        # @param page_text [Boolean] bring back page text and print handles;
        #   see the class doc's +== Page text+
        # @param disk_cache [UrlCache::OnDisk, #read, #write] store for a
        #   +disk_cacheable?+ winner's rows; defaults to {.disk_cache}.
        # @param memory_cache [UrlCache::InMemory, #read, #write] store for
        #   every other winner's; defaults to {.memory_cache}.
        # @param page_store [PageStore] where page text goes; defaults to
        #   {PageStore.default}
        # @return [Engines]
        # @raise [ArgumentError] as {.resolve}, or when +page_text+ is set but
        #   no selected engine can bring back page text
        def initialize(engines: nil, brave_key: nil, exa_key: nil, page_text: false,
                       disk_cache: self.class.disk_cache(page_text: page_text),
                       memory_cache: self.class.memory_cache(page_text: page_text),
                       page_store: PageStore.default)
          names = self.class.resolve(engines: engines, brave_key: brave_key, exa_key: exa_key)
          if page_text
            if (names & PAGE_TEXT_ENGINES).empty?
              raise ArgumentError, "search engines: page_text needs #{PAGE_TEXT_ENGINES.join(' or ')}, " \
                                   "got #{names.join(', ')}"
            end
            names &= PAGE_TEXT_ENGINES if engines.nil?
          end

          @providers = names.map do |name|
            case name
            when :duckduckgo then DuckDuckGo.new
            when :brave then Brave.new(api_key: brave_key, page_text: page_text)
            when :exa then Exa.new(api_key: exa_key, page_text: page_text)
            end
          end
          @page_text = page_text
          @disk_cache = disk_cache
          @memory_cache = memory_cache
          @page_store = page_store
          @last_logged_providers = nil
        end

        # @return [Array<#search, #label, #disk_cacheable?>] the selected
        #   provider instances, in {ENGINE_NAMES} order (the cascade shuffles
        #   them per call).
        attr_reader :providers

        # Run +query+ through the providers in random order, falling back on each
        # {Unavailable}. The shuffle spreads load so one provider isn't always
        # hit (and exhausted) first. The query is whitespace-normalized first;
        # the winning provider's rows are cached keyed by the cleaned query (a
        # hit short-circuits the cascade) — on disk when the winner is
        # +disk_cacheable?+, else in memory only — and rendered to Markdown.
        # +max_results+ is *not* in the cache key, so a non-default value may
        # return a previously-cached size.
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
        # @return [Tool::Result] the Markdown result list (+"Returned 3 search
        #   results"+), or {Tool::Result.error} when all providers are exhausted
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

          json = @memory_cache.read(cleaned) || @disk_cache.read(cleaned)
          if json
            LOGGER.info { "cache=hit bytes=#{json.bytesize}" }
          else
            json = run_cascade(cleaned, current_providers, max_results: max_results, cancellable: cancellable)
          end
          rows = JSON.parse(json)
          Tool::Result.new(content: render(rows),
                           summary: "Returned #{Pikuri::Tool.pluralize(rows.size, 'search result')}")
        rescue Unavailable => e
          Pikuri::Tool::Result.error(e.message)
        end

        private

        # Ask the providers in random order until one answers, store its page
        # text, then cache its rows where its terms allow.
        #
        # @param cleaned [String] the normalized query
        # @param current_providers [Array<#search, #label, #disk_cacheable?>]
        # @param max_results [Integer]
        # @param cancellable [Pikuri::Agent::Control::Cancellable]
        # @return [String] the rows as JSON, as cached
        # @raise [Unavailable] when every provider is — raised, never stored, so
        #   the all-unavailable message can't block this query for the TTL
        def run_cascade(cleaned, current_providers, max_results:, cancellable:)
          failures = []
          current_providers.shuffle.each do |provider|
            results = provider.search(cleaned, max_results: max_results, cancellable: cancellable)
            disk = provider.disk_cacheable?
            LOGGER.info { "engine=#{provider.label} results=#{results.size} cache=#{disk ? 'disk' : 'memory'}" }
            return (disk ? @disk_cache : @memory_cache).write(cleaned, JSON.generate(rows_of(results)))
          rescue Unavailable => e
            failures << "#{provider.label} (#{e.message})"
          end
          raise Unavailable, "all search providers temporarily unavailable: #{failures.join('; ')}"
        end

        # The cacheable rows of +results+, storing each one's page text first.
        # A row's +has_text+ is what earns it a handle at render time; its text
        # lives only in the {PageStore}, never in a query cache.
        #
        # @param results [Array<Result>]
        # @return [Array<Hash{String => Object}>] +url+, +title+, +snippet+,
        #   +has_text+ per row
        def rows_of(results)
          results.map do |r|
            has_text = @page_text && !r.text.nil?
            @page_store.store(url: r.url, title: r.title, text: r.text, indexed_at: r.indexed_at) if has_text
            { 'url' => r.url, 'title' => r.title, 'snippet' => r.body, 'has_text' => has_text }
          end
        end

        # Render rows into the smolagents-style Markdown the LLM consumes
        # (+"## Search Results"+ header, then +[title](url)\nsnippet+ joined by
        # blank lines), each readable row led by its handle. Empty → the +"No
        # results found."+ stub.
        #
        # @param rows [Array<Hash{String => Object}>] as {#rows_of} made them
        # @return [String] Markdown result list
        def render(rows)
          return "## Search Results\n\nNo results found." if rows.empty?

          "## Search Results\n\n" + rows.map { |row| render_row(row) }.join("\n\n")
        end

        # @param row [Hash{String => Object}]
        # @return [String] one row; a +has_text+ row still in the {PageStore}
        #   gets its handle, one evicted since renders without
        def render_row(row)
          line = "[#{row['title']}](#{row['url']})\n#{row['snippet']}"
          handle = row['has_text'] && @page_store.handle_for(row['url'])
          handle ? "[#{handle}] #{line}" : line
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
