# frozen_string_literal: true

require 'faraday'
require 'json'
require 'nokogiri'

require 'tool/search/rate_limiter'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  module Search
    # Performs a Brave Search via the official Web Search API and renders
    # the results as smolagents-style Markdown matching the {DuckDuckGo}
    # provider's output. Split into a thin HTTP fetch (#search) and a pure
    # parser (#parse) so tests can exercise the parser against fixture
    # JSON without hitting the network.
    #
    # Requires a Brave Search API key. Get one at
    # https://api-dashboard.search.brave.com — the free "Data for Search"
    # tier allows 1 query/sec and ~2k queries/month.
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

      # Fetch results for +query+ and render them as smolagents-style Markdown.
      # Calls are throttled to one per second and circuit-broken for 5
      # minutes on rate-limit / quota-exhausted responses; see {LIMITER}.
      # The caller (typically {Tool::Search.search}) is expected to have
      # already normalized the query and to wrap this in a result cache.
      #
      # @param query [String] search query (already normalized)
      # @param max_results [Integer] maximum number of result entries to render;
      #   passed through as Brave's +count+ (1..20)
      # @param api_key [String] Brave Search subscription token; defaults to
      #   the {ENV_KEY} environment variable
      # @return [String] Markdown-formatted result list
      # @raise [ArgumentError] if no API key is available
      # @raise [Tool::Search::Unavailable] when Brave returns HTTP 429
      #   (rate limit / quota exhausted) or 5xx — "try again later"
      #   responses the cascade in {Tool::Search.search} can fall back
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
              raise Unavailable, "HTTP #{response.status}"
            end

            raise "Brave Search request failed: #{response.status} #{response.body}"
          end

          parse(response.body, max_results: max_results)
        end
      end

      # Parse a Brave Web Search JSON response into smolagents-style Markdown:
      # +"## Search Results"+ followed by +[title](href)\nbody+ entries joined
      # by blank lines. HTML highlight tags (+<strong>+) inside +title+ and
      # +description+ are stripped via Nokogiri so the output is plain text.
      #
      # An empty result list is treated as a failure: Brave returns at least
      # one match for any non-empty query, so zero matches means an error
      # response shape we don't recognize. The raised message includes a
      # truncated copy of the body so the agent loop sees what came back.
      #
      # @param json [String] response body from {ENDPOINT}
      # @param max_results [Integer] maximum number of result entries to render
      # @return [String] Markdown-formatted result list
      # @raise [RuntimeError] when the response yields no result entries
      def self.parse(json, max_results: DEFAULT_MAX_RESULTS)
        data = JSON.parse(json)
        results = Array(data.dig('web', 'results')).take(max_results).filter_map do |r|
          href = r['url'].to_s
          next nil if href.empty?

          {
            title: strip_html(r['title']),
            href: href,
            body: strip_html(r['description'])
          }
        end

        raise diagnose_empty(data, json) if results.empty?

        "## Search Results\n\n" + results.map { |r| "[#{r[:title]}](#{r[:href]})\n#{r[:body]}" }.join("\n\n")
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
