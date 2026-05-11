# frozen_string_literal: true

require 'faraday'
require 'json'
class Tool
  module Search
    # Performs an Exa search via the official +/search+ endpoint and
    # renders the results as smolagents-style Markdown matching the
    # {DuckDuckGo} and {Brave} providers' output. Split into a thin HTTP
    # fetch (#search) and a pure parser (#parse) so tests can exercise
    # the parser against fixture JSON without hitting the network.
    #
    # Requires an Exa API key. Get one at https://exa.ai — the service is
    # paid, so the cascade in {Engines.providers} only includes Exa when
    # {ENV_KEY} is set in the environment; users who haven't registered
    # never spend money on it.
    #
    # Calls request +type: "auto"+ (Exa picks neural vs keyword per
    # query) and +contents: { highlights: true }+ so each result carries
    # a short neural-ranked snippet — the closest analog to Brave's
    # +description+ field, keeping the rendered Markdown shape stable
    # across providers.
    module Exa
      # @return [String] Search endpoint (POST, JSON body)
      ENDPOINT = 'https://api.exa.ai/search'
      # @return [Integer] default number of results returned, matching
      #   {DuckDuckGo::DEFAULT_MAX_RESULTS}
      DEFAULT_MAX_RESULTS = 10
      # @return [String] env var holding the API key; sent as +x-api-key+
      ENV_KEY = 'EXA_API_KEY'
      # @return [RateLimiter] Exa is paid and doesn't aggressively
      #   throttle, so no minimum interval is enforced. The 5-minute
      #   cooldown still applies on {Engines::Unavailable} so the user's
      #   budget isn't burned on doomed retries while a 429 / 5xx
      #   condition persists.
      LIMITER = RateLimiter.new(min_interval: 0.0, cooldown: 300.0)

      # Fetch results for +query+ and render them as smolagents-style Markdown.
      # Calls are circuit-broken for 5 minutes on rate-limit / unavailable
      # responses; see {LIMITER}. The caller (typically {Engines.search})
      # is expected to have already normalized the query and to wrap this
      # in a result cache.
      #
      # @param query [String] search query (already normalized)
      # @param max_results [Integer] maximum number of result entries to render;
      #   passed through as Exa's +numResults+
      # @param api_key [String] Exa API key; defaults to the {ENV_KEY}
      #   environment variable
      # @return [String] Markdown-formatted result list
      # @raise [ArgumentError] if no API key is available
      # @raise [Engines::Unavailable] when Exa returns HTTP 429
      #   (rate limit / quota exhausted) or 5xx — "try again later"
      #   responses the cascade in {Engines.search} can fall back from.
      #   Also raised immediately if {LIMITER} is in cooldown. Other
      #   non-2xx (e.g. 401/403 from a bad API key) bubble up as
      #   +RuntimeError+ so config problems stay visible.
      # @raise [RuntimeError] for non-rate-limit HTTP failures or when the
      #   response shape contains no results and isn't a recognized
      #   empty-results payload.
      def self.search(query, max_results: DEFAULT_MAX_RESULTS, api_key: ENV.fetch(ENV_KEY, nil))
        raise ArgumentError, "Exa Search API key not set (#{ENV_KEY})" if api_key.to_s.strip.empty?

        LIMITER.call do
          response = Faraday.post(ENDPOINT) do |req|
            req.headers['x-api-key'] = api_key
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

          parse(response.body, max_results: max_results)
        end
      end

      # Parse an Exa Search JSON response into smolagents-style Markdown:
      # +"## Search Results"+ followed by +[title](href)\nbody+ entries
      # joined by blank lines, where +body+ is the first non-empty
      # +highlights+ snippet (empty when Exa returned no highlight for
      # that result — e.g. for navigational results).
      #
      # When the response yields zero result entries, two cases are
      # distinguished: a genuine "no results" payload (response carries
      # a +requestId+ and an empty +results+ array — Exa ran the query
      # but matched nothing) returns a Markdown stub instead of raising,
      # so the agent gets a real observation it can act on. Anything
      # else (unknown shape, structured error) raises with a diagnostic
      # so the failure surfaces.
      #
      # @param json [String] response body from {ENDPOINT}
      # @param max_results [Integer] maximum number of result entries to render
      # @return [String] Markdown-formatted result list
      # @raise [RuntimeError] when the response yields no result entries and
      #   is not recognized as a genuine empty-results payload
      def self.parse(json, max_results: DEFAULT_MAX_RESULTS)
        data = JSON.parse(json)
        results = Array(data['results']).take(max_results).filter_map do |r|
          href = r['url'].to_s
          next nil if href.empty?

          {
            title: clean(r['title']) || href,
            href: href,
            body: first_highlight(r['highlights'])
          }
        end

        if results.empty?
          return "## Search Results\n\nNo results found." if genuine_no_results?(data)

          raise diagnose_empty(data, json)
        end

        "## Search Results\n\n" + results.map { |r| "[#{r[:title]}](#{r[:href]})\n#{r[:body]}" }.join("\n\n")
      end

      # Collapse whitespace and strip; returns +nil+ for nil/empty input
      # so the caller can fall back (typically to the URL when a result
      # has no usable title).
      #
      # @param text [String, nil] raw text from an Exa result field
      # @return [String, nil] cleaned text, or +nil+ if input was blank
      def self.clean(text)
        return nil if text.nil?

        cleaned = text.to_s.gsub(/\s+/, ' ').strip
        cleaned.empty? ? nil : cleaned
      end
      private_class_method :clean

      # First non-empty entry from a +highlights+ array, cleaned. Exa
      # returns highlights as an array sorted by relevance; we surface
      # only the top one to keep the observation compact and match the
      # one-line +body+ convention used by Brave / DuckDuckGo.
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

      # True when a parsed response with zero +results+ entries looks
      # like Exa's own "search ran, nothing matched" payload rather than
      # a malformed or error response. The marker is the +requestId+
      # field, which Exa always sets on a successful request.
      #
      # @param data [Hash, Object] parsed response
      # @return [Boolean]
      def self.genuine_no_results?(data)
        return false unless data.is_a?(Hash)
        return false unless data.key?('requestId')

        Array(data['results']).empty?
      end
      private_class_method :genuine_no_results?

      # Build an error message for a parsed response that yielded zero
      # results. Quotes Exa's +error+ / +message+ / +detail+ field if
      # present, otherwise truncates the raw body so the caller can see
      # the actual payload.
      #
      # @param data [Hash, Object] parsed response
      # @param raw [String] raw response body
      # @return [String] human-readable diagnostic to feed to +raise+
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
