# frozen_string_literal: true

require 'faraday'
require 'json'

module Pikuri
  class Tool
    module Search
      # Performs an Exa search via the official +/search+ endpoint, returning
      # hits as {Result} rows. Split into a thin HTTP fetch (#search) and a pure
      # parser (.parse) so tests exercise the parser against fixture JSON.
      # {Engines#search} owns the final Markdown rendering.
      #
      # Constructed with its API key (+Exa.new(api_key:)+); {Engines} builds one
      # only when an Exa key was configured, so users who never registered don't
      # spend money, then drives it through the same +#search+/+#label+
      # interface as every provider. pikuri reads no key from the environment
      # (CLAUDE.md "Environment is not a secret store"). Paid; key at
      # https://exa.ai.
      #
      # Requests +type: "auto"+ (Exa picks neural vs keyword) and +contents: {
      # highlights: true }+ so each result carries a neural-ranked snippet
      # populating {Result#body} — the analog to Brave's +description+.
      #
      # == Privacy posture
      #
      # Exa's Privacy Policy uses Query Data to train/fine-tune its models, and
      # ToS §1.2(c) grants a +perpetual and irrevocable+, sub-licensable license
      # over User Input. Business customers under an MSA/DPA get carve-outs; the
      # default pay-as-you-go key pikuri uses does not. Bottom line: Exa mines
      # queries to train competing models. If a query would be sensitive in a
      # training set, don't configure an Exa key — {Engines#providers} leaves
      # Exa out of the cascade unless its key was supplied.
      class Exa
        # @return [String] Search endpoint (POST, JSON body)
        ENDPOINT = 'https://api.exa.ai/search'
        # @return [Integer] default number of results returned, matching
        #   {DuckDuckGo::DEFAULT_MAX_RESULTS}
        DEFAULT_MAX_RESULTS = 10
        # @return [RateLimiter] Exa is paid and doesn't aggressively throttle,
        #   so no minimum interval; the 5-minute cooldown still applies on
        #   {Engines::Unavailable} so the budget isn't burned on doomed retries.
        LIMITER = RateLimiter.new(min_interval: 0.0, cooldown: 300.0)

        # @param api_key [String] Exa API key. Required and non-blank:
        #   pikuri reads no key from the environment — the host supplies it
        #   ({Engines} only constructs an Exa when a key was configured).
        # @raise [ArgumentError] if +api_key+ is blank
        def initialize(api_key:)
          raise ArgumentError, 'Exa Search API key is blank' if api_key.to_s.strip.empty?

          @api_key = api_key
        end

        # @return [String] short provider label for {Engines} logging /
        #   fallback messages.
        def label
          'Exa'
        end

        # Fetch results for +query+ as an +Array<Result>+. Circuit-broken for
        # 5 minutes on rate-limit/unavailable (see {LIMITER}). The caller
        # ({Engines#search}) normalizes the query and wraps this in a cache.
        #
        # @param query [String] search query (already normalized)
        # @param max_results [Integer] max entries; Exa's +numResults+
        # @return [Array<Result>] hits, possibly empty when Exa matched nothing
        # @raise [Engines::Unavailable] on HTTP 429 or 5xx (the cascade falls
        #   back from these), or immediately if {LIMITER} is in cooldown. Other
        #   non-2xx (401/403 bad key) bubble up as +RuntimeError+.
        # @raise [RuntimeError] for non-rate-limit HTTP failures, or an
        #   unrecognized empty-results shape.
        def search(query, max_results: DEFAULT_MAX_RESULTS)
          LIMITER.call do
            response = Faraday.post(ENDPOINT) do |req|
              req.headers['x-api-key'] = @api_key
              req.headers['Content-Type'] = 'application/json'
              req.headers['Accept'] = 'application/json'
              req.body = JSON.dump(
                query: query,
                type: 'auto',
                numResults: max_results,
                contents: { highlights: true }
              )
            end
            unless response.success?
              if response.status == 429 || response.status >= 500
                raise Engines::Unavailable, "HTTP #{response.status}"
              end

              raise "Exa Search request failed: #{response.status} #{response.body}"
            end

            self.class.parse(response.body, max_results: max_results)
          end
        end

        # Parse an Exa JSON response into {Result} rows, +body+ the first
        # non-empty +highlights+ snippet. A genuine "no results" payload
        # (+requestId+ present, empty +results+) returns +[]+ so {Engines.search}
        # renders its no-results stub; any other zero-result shape raises.
        #
        # @param json [String] response body from {ENDPOINT}
        # @param max_results [Integer] max entries
        # @return [Array<Result>] hits, possibly empty on a recognized
        #   empty-results payload
        # @raise [RuntimeError] on an unrecognized zero-result response
        def self.parse(json, max_results: DEFAULT_MAX_RESULTS)
          data = JSON.parse(json)
          results = Array(data['results']).take(max_results).filter_map do |r|
            href = r['url'].to_s
            next nil if href.empty?

            Result.new(
              url: href,
              title: clean(r['title']) || href,
              body: first_highlight(r['highlights'])
            )
          end

          if results.empty?
            return [] if genuine_no_results?(data)

            raise diagnose_empty(data, json)
          end

          results
        end

        # Collapse whitespace and strip; +nil+ for nil/empty input so the caller
        # can fall back (e.g. to the URL when a result has no title).
        #
        # @param text [String, nil]
        # @return [String, nil] cleaned text, or +nil+ if blank
        def self.clean(text)
          return nil if text.nil?

          cleaned = text.to_s.gsub(/\s+/, ' ').strip
          cleaned.empty? ? nil : cleaned
        end
        private_class_method :clean

        # First non-empty +highlights+ entry, cleaned. Exa sorts highlights by
        # relevance; the top one populates +body+.
        #
        # @param highlights [Array<String>, nil] +highlights+ field
        # @return [String] cleaned snippet, or empty string if none usable
        def self.first_highlight(highlights)
          return '' unless highlights.is_a?(Array)

          highlights.each do |h|
            cleaned = clean(h)
            return cleaned if cleaned
          end
          ''
        end
        private_class_method :first_highlight

        # True when a zero-+results+ response looks like Exa's own "ran, matched
        # nothing" payload rather than an error — marked by +requestId+, which
        # Exa always sets on success.
        #
        # @param data [Hash, Object] parsed response
        # @return [Boolean]
        def self.genuine_no_results?(data)
          return false unless data.is_a?(Hash)
          return false unless data.key?('requestId')

          Array(data['results']).empty?
        end
        private_class_method :genuine_no_results?

        # Build an error message for a zero-result response: quote Exa's
        # +error+/+message+/+detail+ if present, else a truncated raw body.
        #
        # @param data [Hash, Object] parsed response
        # @param raw [String] raw response body
        # @return [String] diagnostic to feed to +raise+
        def self.diagnose_empty(data, raw)
          if data.is_a?(Hash) && (msg = data['error'] || data['message'] || data['detail'])
            return "Exa Search returned an error: #{msg}"
          end

          snippet = raw.to_s[0, 800]
          snippet += '…' if raw.to_s.length > 800
          "Exa Search returned no results. Body: #{snippet}"
        end
        private_class_method :diagnose_empty
      end
    end
  end
end
