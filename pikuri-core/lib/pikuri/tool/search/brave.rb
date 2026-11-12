# frozen_string_literal: true

require 'faraday'
require 'json'
require 'nokogiri'

module Pikuri
  class Tool
    module Search
      # Performs a Brave Search via the official Web Search API, returning hits
      # as {Result} rows. Split into a thin HTTP fetch (#search) and a pure
      # parser (.parse) so tests exercise the parser against fixture JSON.
      # {Engines#search} owns the final Markdown rendering.
      #
      # Constructed with its API key (+Brave.new(api_key:)+); {Engines} builds
      # one only when a Brave key was configured. pikuri reads no key from the
      # environment (AGENTS.md "Environment is not a secret store"). Key at
      # https://api-dashboard.search.brave.com — the free "Data for Search" tier
      # allows 1 query/sec, ~2k/month.
      #
      # == Privacy posture
      #
      # Brave's Search API privacy notice (updated 3 Nov 2026, covers the whole
      # API, no per-endpoint terms —
      # https://api-dashboard.search.brave.com/privacy-policy) keeps Search
      # Query Logs at most 90 days for billing, troubleshooting and abuse
      # prevention, and logs the caller's IP address and API token for the same
      # purposes. It collects no identifier linking a query to an *end user* of
      # the customer's app — but under pikuri the account holder *is* the end
      # user, so that log is tied to your key. Zero Data Retention exists only
      # on a custom Enterprise plan. The notice is silent on training; the
      # pricing page (https://brave.com/search/api/) promises "Queries never
      # shared or trained on". Bottom line: the cleanest API-level posture of
      # pikuri's three providers (no training, capped retention), but a 90-day
      # log tied to your key, so no ZDR substitute for genuinely sensitive
      # queries.
      class Brave
        # @return [String] Web Search endpoint
        ENDPOINT = 'https://api.search.brave.com/res/v1/web/search'
        # @return [Integer] default number of results returned.
        DEFAULT_MAX_RESULTS = 10
        # @return [RateLimiter] free-tier Brave caps at 1 req/sec; the 5-minute
        #   cooldown protects the monthly quota from doomed retries on a 429.
        LIMITER = RateLimiter.new(min_interval: 1.0, cooldown: 300.0)

        # @param api_key [String] Brave Search subscription token. Required
        #   and non-blank: pikuri reads no key from the environment — the
        #   host supplies it ({Engines} only constructs a Brave when a key
        #   was configured).
        # @raise [ArgumentError] if +api_key+ is blank
        def initialize(api_key:)
          raise ArgumentError, 'Brave Search API key is blank' if api_key.to_s.strip.empty?

          @api_key = api_key
        end

        # @return [String] short provider label for {Engines}.
        def label
          'Brave'
        end

        # Whether {Engines} may keep this provider's results in its on-disk
        # cache. No: the Search API terms (§3(b)(i),
        # https://api-dashboard.search.brave.com/terms-of-service) forbid to
        # "store, cache, or create a database of Search Results … other than
        # transient storage required for operation", so they stay in memory
        # ({UrlCache::InMemory}).
        #
        # @return [Boolean] +false+
        def disk_cacheable?
          false
        end

        # Fetch results for +query+ as an +Array<Result>+. Throttled to 1/sec and
        # circuit-broken 5 min on rate-limit/quota (see {LIMITER}). The caller
        # ({Engines#search}) normalizes the query and wraps this in a cache.
        #
        # @param query [String] search query (already normalized)
        # @param max_results [Integer] max entries; Brave's +count+ (1..20)
        # @param cancellable [Pikuri::Agent::Control::Cancellable] makes
        #   {LIMITER}'s pacing wait interruptible; see {RateLimiter#call}.
        # @return [Array<Result>] hits, possibly empty when Brave matched nothing
        # @raise [Engines::Unavailable] on HTTP 429 or 5xx (the cascade falls
        #   back), or if {LIMITER} is in cooldown. Other non-2xx (401/403 bad
        #   key) bubble up as +RuntimeError+.
        # @raise [RuntimeError] for non-rate-limit HTTP failures, or a
        #   zero-result response that isn't a recognized empty-results payload.
        def search(query, max_results: DEFAULT_MAX_RESULTS,
                   cancellable: Pikuri::Agent::Control::Cancellable::NEVER)
          LIMITER.call(cancellable: cancellable) do
            response = Faraday.get(
              ENDPOINT,
              { q: query, count: max_results },
              { 'X-Subscription-Token' => @api_key, 'Accept' => 'application/json' }
            )
            unless response.success?
              if response.status == 429 || response.status >= 500
                raise Engines::Unavailable, "HTTP #{response.status}"
              end

              raise "Brave Search request failed: #{response.status} #{response.body}"
            end

            self.class.parse(response.body, max_results: max_results)
          end
        end

        # Parse a Brave JSON response into {Result} rows (+<strong>+ highlights
        # stripped). A genuine "no results" payload (recognized search shape,
        # empty +mixed.main/top/side+) returns +[]+ so {Engines.search} renders
        # its stub; any other zero-result shape raises.
        #
        # @param json [String] response body from {ENDPOINT}
        # @param max_results [Integer] max entries
        # @return [Array<Result>] hits, possibly empty on a recognized
        #   empty-results payload
        # @raise [RuntimeError] on an unrecognized zero-result response
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

        # Strip HTML markup (notably the +<strong>+ highlights Brave wraps around
        # query terms) and collapse whitespace.
        #
        # @param html [String, nil]
        # @return [String] plain text; empty string for nil
        def self.strip_html(html)
          return '' if html.nil?

          Nokogiri::HTML.fragment(html).text.gsub(/\s+/, ' ').strip
        end
        private_class_method :strip_html

        # True when a zero-+web.results+ response is Brave's own "ran, matched
        # nothing" payload, not an error. Markers: the +type: "search"+ envelope
        # and an empty +mixed+ block (Brave fills +mixed.main/top/side+ with
        # matched verticals, so all three empty = succeeded-but-found-nothing).
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

        # Build an error message for a zero-result response: quote Brave's
        # +error.detail+ if present, else a truncated raw body.
        #
        # @param data [Hash, Object] parsed response
        # @param raw [String] raw response body
        # @return [String] diagnostic to feed to +raise+
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
end
