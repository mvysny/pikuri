# frozen_string_literal: true

require 'faraday'
require 'nokogiri'
require 'uri'

module Pikuri
  class Tool
    module Search
      # Performs a DuckDuckGo search by scraping +html.duckduckgo.com+, returning
      # hits as {Result} rows. Split into a thin HTTP fetch (#search) and a pure
      # parser (.parse) so tests exercise the parser against fixture HTML.
      # {Engines#search} owns the final Markdown rendering. Constructed with no
      # arguments, sharing the uniform +#search+/+#label+ provider shape with the
      # keyed {Brave} / {Exa}.
      #
      # == Privacy posture
      #
      # DDG doesn't save your IP or tie a per-user profile to queries, and
      # proxies requests so downstream providers can't build a search history —
      # real, but DDG relays web results over Bing, so *query content* still
      # reaches Microsoft (who has no no-training pledge). Better than Exa for
      # sensitive queries, worse than Brave; for anything genuinely embarrassing,
      # don't search the web at all.
      class DuckDuckGo
        # @return [String] HTML search endpoint
        ENDPOINT = 'https://html.duckduckgo.com/html/'
        # @return [String] User-Agent sent with each request; DDG often rejects
        #   a missing or obviously-bot UA.
        USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                     '(KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        # @return [Integer] default number of results returned.
        DEFAULT_MAX_RESULTS = 10
        # @return [RateLimiter] paces calls (DDG bans IPs that hammer the HTML
        #   endpoint) and circuit-breaks 5 min on {Engines::Unavailable}.
        LIMITER = RateLimiter.new(min_interval: 2.0, cooldown: 300.0)

        # @return [String] short provider label for {Engines}.
        def label
          'DuckDuckGo'
        end

        # Fetch results for +query+ as an +Array<Result>+. Throttled to one every
        # 2s and circuit-broken 5 min after a soft-block (see {LIMITER}). The
        # caller ({Engines#search}) normalizes the query and wraps this in a cache.
        #
        # @param query [String] search query (already normalized)
        # @param max_results [Integer] max result entries
        # @param cancellable [Pikuri::Agent::Control::Cancellable] makes
        #   {LIMITER}'s pacing wait interruptible; see {RateLimiter#call}.
        # @return [Array<Result>] hits, possibly empty when DDG matched nothing
        # @raise [Engines::Unavailable] on a soft-block (anomaly/CAPTCHA page) or
        #   HTTP 429/5xx (the cascade falls back), or if {LIMITER} is in cooldown.
        # @raise [RuntimeError] on other HTTP failures or an unrecognized
        #   empty-results layout. A genuine empty-results page is not an error;
        #   see {.parse}.
        def search(query, max_results: DEFAULT_MAX_RESULTS,
                   cancellable: Pikuri::Agent::Control::Cancellable::NEVER)
          LIMITER.call(cancellable: cancellable) do
            response = Faraday.get(ENDPOINT, { q: query }, { 'User-Agent' => USER_AGENT })
            unless response.success?
              if response.status == 429 || response.status >= 500
                raise Engines::Unavailable, "HTTP #{response.status}"
              end

              raise "DuckDuckGo request failed: #{response.status} #{response.body}"
            end

            self.class.parse(response.body, max_results: max_results)
          end
        end

        # Parse a +html.duckduckgo.com+ result page into {Result} rows (+<b>+
        # highlights stripped). On zero result nodes: a genuine "no results" page
        # returns +[]+ (so {Engines.search} renders its stub); the anomaly/CAPTCHA
        # modal raises {Engines::Unavailable}; anything else raises {RuntimeError}
        # (likely a layout change) — so an IP soft-block surfaces rather than
        # masquerading as an empty search.
        #
        # @param html [String] HTML from html.duckduckgo.com
        # @param max_results [Integer] max result entries
        # @return [Array<Result>] hits, possibly empty on a genuine no-results page
        # @raise [Engines::Unavailable] on the anomaly/CAPTCHA modal (IP soft-block)
        # @raise [RuntimeError] on zero results with an unrecognized layout
        def self.parse(html, max_results: DEFAULT_MAX_RESULTS)
          doc = Nokogiri::HTML(html)
          results = doc.css('div.result.web-result').take(max_results).filter_map do |node|
            title_link = node.at_css('a.result__a')
            next nil if title_link.nil?

            snippet = node.at_css('a.result__snippet')
            Result.new(
              url: extract_url(title_link['href']),
              title: title_link.text.strip,
              body: snippet&.text&.strip.to_s
            )
          end

          if results.empty?
            return [] if genuine_no_results?(doc)

            message = diagnose_empty(doc)
            raise(anomaly_modal?(doc) ? Engines::Unavailable : RuntimeError, message)
          end

          results
        end

        # True when the page is DDG's anomaly/CAPTCHA modal (IP soft-blocked).
        # {.parse} uses it to pick {Engines::Unavailable} (recoverable) over
        # {RuntimeError} (unknown layout).
        #
        # @param doc [Nokogiri::HTML::Document]
        # @return [Boolean]
        def self.anomaly_modal?(doc)
          !!(doc.at_css('.anomaly-modal__title') || doc.at_css('.anomaly-modal__description'))
        end
        private_class_method :anomaly_modal?

        # True when a zero-node page is DDG's own "no results found" page, not an
        # anomaly/CAPTCHA. Anomaly wins: if the modal divs are present it's never
        # a genuine empty result, even if the text mentions "No results".
        #
        # @param doc [Nokogiri::HTML::Document]
        # @return [Boolean]
        def self.genuine_no_results?(doc)
          return false if doc.at_css('.anomaly-modal__title') || doc.at_css('.anomaly-modal__description')
          return true if doc.at_css('div.no-results')

          doc.text.include?('No results found')
        end
        private_class_method :genuine_no_results?

        # Build an error message for a zero-match page: quote the DDG anomaly
        # modal's title/description if present, else a truncated copy of the
        # body's visible text (+<script>/<style>/<noscript>+ stripped).
        #
        # @param doc [Nokogiri::HTML::Document]
        # @return [String] diagnostic to feed to +raise+
        def self.diagnose_empty(doc)
          title = doc.at_css('.anomaly-modal__title')&.text&.strip
          desc  = doc.at_css('.anomaly-modal__description')&.text&.strip
          if title || desc
            return "DuckDuckGo anomaly check (likely IP soft-block): #{[title, desc].compact.reject(&:empty?).join(' — ')}"
          end

          doc.css('script, style, noscript').remove
          text = doc.text.gsub(/\s+/, ' ').strip
          snippet = text.empty? ? '<empty body>' : text[0, 1500]
          snippet += '…' if text.length > 1500
          "DuckDuckGo returned no results. Page text: #{snippet}"
        end
        private_class_method :diagnose_empty

        # Decode DDG's +//duckduckgo.com/l/?uddg=<encoded>+ redirect wrapper to
        # the real target URL.
        #
        # @param href [String, nil] href from the result page
        # @return [String] the decoded target, or +href+ unchanged when not a
        #   recognized DDG redirect or unparseable
        def self.extract_url(href)
          return href if href.nil? || href.empty?

          uri = URI.parse(href.start_with?('//') ? "https:#{href}" : href)
          return href unless uri.host&.end_with?('duckduckgo.com') && uri.path == '/l/'

          params = URI.decode_www_form(uri.query.to_s).to_h
          params['uddg'] || href
        rescue URI::InvalidURIError
          href
        end
      end
    end
  end
end
