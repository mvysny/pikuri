# frozen_string_literal: true

require 'faraday'
require 'json'
require 'nokogiri'
class Tool
  module Search
    # Performs a Brave Search via the official Web Search API and returns
    # the hits as a list of {Result} rows. Split into a thin HTTP fetch
    # (#search) and a pure parser (#parse) so tests can exercise the
    # parser against fixture JSON without hitting the network. The
    # cascade in {Engines.search} owns the final Markdown rendering.
    #
    # Requires a Brave Search API key. Get one at
    # https://api-dashboard.search.brave.com — the free "Data for Search"
    # tier allows 1 query/sec and ~2k queries/month.
    #
    # == Privacy posture
    #
    # Brave's API Privacy Notice retains Search Query Logs for 90 days
    # (billing / troubleshooting) and states +Brave does not collect any
    # identifiers that can link a search query to an individual or their
    # devices+. Brave publicly commits that the Search API does not use
    # query data to train its own models, and offers Zero Data Retention
    # — but only on the Enterprise plan, not on the free "Data for
    # Search" tier pikuri defaults to.
    #
    # Bottom line: of pikuri's three providers Brave has the cleanest
    # API-level posture — no training-on-queries, no IP linkage, capped
    # 90-day retention by default, real ZDR if you pay for it. Still a
    # logged 90-day window on the cheap tier, so not a substitute for
    # ZDR for genuinely sensitive queries.
    module Brave
      # @return [String] Web Search endpoint
      ENDPOINT = 'https://api.search.brave.com/res/v1/web/search'
      # @return [Integer] default number of results returned, matching
      #   {DuckDuckGo::DEFAULT_MAX_RESULTS}
      DEFAULT_MAX_RESULTS = 10
      # @return [String] env var holding the API key; +X-Subscription-Token+
      ENV_KEY = 'BRAVE_SEARCH_API_KEY'
      # @return [RateLimiter] free-tier Brave caps at 1 req/sec; the
      #   5-minute cooldown protects the limited monthly quota from
      #   being burned on doomed retries when a 429 hits.
      LIMITER = RateLimiter.new(min_interval: 1.0, cooldown: 300.0)

      # Fetch results for +query+ and return them as an +Array<Result>+.
      # Calls are throttled to one per second and circuit-broken for 5
      # minutes on rate-limit / quota-exhausted responses; see {LIMITER}.
      # The caller (typically {Engines.search}) is expected to have
      # already normalized the query and to wrap this in a result cache.
      #
      # @param query [String] search query (already normalized)
      # @param max_results [Integer] maximum number of result entries;
      #   passed through as Brave's +count+ (1..20)
      # @param api_key [String] Brave Search subscription token; defaults to
      #   the {ENV_KEY} environment variable
      # @return [Array<Result>] hits, possibly empty when Brave ran the
      #   query and matched nothing
      # @raise [ArgumentError] if no API key is available
      # @raise [Engines::Unavailable] when Brave returns HTTP 429
      #   (rate limit / quota exhausted) or 5xx — "try again later"
      #   responses the cascade in {Engines.search} can fall back
      #   from. Also raised immediately if {LIMITER} is in cooldown.
      #   Other non-2xx (e.g. 401/403 from a bad API key) bubble up as
      #   +RuntimeError+ so config problems stay visible.
      # @raise [RuntimeError] for non-rate-limit HTTP failures or when the
      #   response shape contains no results.
      def self.search(query, max_results: DEFAULT_MAX_RESULTS, api_key: ENV.fetch(ENV_KEY, nil))
        raise ArgumentError, "Brave Search API key not set (#{ENV_KEY})" if api_key.to_s.strip.empty?

        LIMITER.call do
          response = Faraday.get(
            ENDPOINT,
            { q: query, count: max_results },
            { 'X-Subscription-Token' => api_key, 'Accept' => 'application/json' }
          )
          unless response.success?
            if response.status == 429 || response.status >= 500
              raise Engines::Unavailable, "HTTP #{response.status}"
            end

            raise "Brave Search request failed: #{response.status} #{response.body}"
          end

          parse(response.body, max_results: max_results)
        end
      end

      # Parse a Brave Web Search JSON response into a list of {Result} rows.
      # HTML highlight tags (+<strong>+) inside +title+ and +description+
      # are stripped via Nokogiri so the output is plain text.
      #
      # When the response yields zero result nodes, two cases are
      # distinguished: a genuine "no results" payload (recognized search
      # shape with empty +mixed.main+/+top+/+side+ — typically a too-narrow
      # query Brave couldn't match) returns an empty array instead of
      # raising, so {Engines.search} can render its standard no-results
      # stub. Anything else (unknown layout, structured error) raises
      # with a diagnostic so the failure surfaces.
      #
      # @param json [String] response body from {ENDPOINT}
      # @param max_results [Integer] maximum number of result entries
      # @return [Array<Result>] hits, possibly empty on a recognized
      #   empty-results payload
      # @raise [RuntimeError] when the response yields no result entries and
      #   is not recognized as a genuine empty-results payload
      def self.parse(json, max_results: DEFAULT_MAX_RESULTS)
        data = JSON.parse(json)
        results = Array(data.dig('web', 'results')).take(max_results).filter_map do |r|
          href = r['url'].to_s
          next nil if href.empty?

          Result.new(
            url: href,
            title: strip_html(r['title']),
            body: strip_html(r['description'])
          )
        end

        if results.empty?
          return [] if genuine_no_results?(data)

          raise diagnose_empty(data, json)
        end

        results
      end

      # Strip HTML markup (notably +<strong>+ highlights Brave wraps around
      # query terms in titles and descriptions) and collapse whitespace.
      #
      # @param html [String, nil] raw text from a Brave result field
      # @return [String] plain text with tags removed; empty string for nil
      def self.strip_html(html)
        return '' if html.nil?

        Nokogiri::HTML.fragment(html).text.gsub(/\s+/, ' ').strip
      end
      private_class_method :strip_html

      # True when a parsed response with zero +web.results+ entries looks
      # like Brave's own "search ran, nothing matched" payload (typically a
      # too-narrow query) rather than a malformed or error response. The
      # markers are the recognized +type: "search"+ envelope and an empty
      # +mixed+ block — Brave populates +mixed.main/top/side+ with whichever
      # verticals matched, so all three being empty arrays is the canonical
      # signal that the search itself succeeded but found nothing.
      #
      # @param data [Hash, Object] parsed response
      # @return [Boolean]
      def self.genuine_no_results?(data)
        return false unless data.is_a?(Hash) && data['type'] == 'search'

        mixed = data['mixed']
        return false unless mixed.is_a?(Hash)

        %w[main top side].all? { |k| Array(mixed[k]).empty? }
      end
      private_class_method :genuine_no_results?

      # Build an error message for a parsed response that yielded zero
      # results. Quotes Brave's +error.detail+ if present, otherwise
      # truncates the raw body so the caller can see the actual payload.
      #
      # @param data [Hash, Object] parsed response
      # @param raw [String] raw response body
      # @return [String] human-readable diagnostic to feed to +raise+
      def self.diagnose_empty(data, raw)
        if data.is_a?(Hash) && data['error'].is_a?(Hash)
          err = data['error']
          return "Brave Search returned an error: #{[err['code'], err['detail'] || err['meta']].compact.join(' — ')}"
        end

        snippet = raw.to_s[0, 800]
        snippet += '…' if raw.to_s.length > 800
        "Brave Search returned no results. Body: #{snippet}"
      end
      private_class_method :diagnose_empty
    end
  end
end
