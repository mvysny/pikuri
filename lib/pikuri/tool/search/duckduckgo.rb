# frozen_string_literal: true

require 'faraday'
require 'nokogiri'
require 'uri'

module Pikuri
  class Tool
    module Search
      # Performs a DuckDuckGo search by scraping +html.duckduckgo.com+ and
      # returns the hits as a list of {Result} rows. Split into a thin HTTP
      # fetch (#search) and a pure parser (#parse) so tests can exercise
      # the parser against fixture HTML without hitting the network. The
      # cascade in {Engines.search} owns the final Markdown rendering.
      #
      # == Privacy posture
      #
      # DuckDuckGo's privacy policy states +We don't save your IP address
      # or any unique identifiers alongside your searches+ and +We have
      # never sold any personal information+, and they proxy requests on
      # the user's behalf so downstream content providers can't build a
      # per-user search history. That part is real — but DDG is mainly a
      # relay over Bing for web results, so the *query content* still
      # reaches Microsoft for fulfillment even though DDG strips
      # identifying info on the way out.
      #
      # Bottom line: DDG is a genuine privacy improvement over hitting
      # Bing directly (your IP isn't tied to the query, no per-user
      # profile is built on DDG's side), but query content still lands at
      # Microsoft, who has no comparable no-training pledge. Better than
      # Exa for sensitive queries, worse than Brave; for anything
      # genuinely embarrassing, don't search the web at all.
      module DuckDuckGo
        # @return [String] HTML search endpoint
        ENDPOINT = 'https://html.duckduckgo.com/html/'
        # @return [String] User-Agent sent with each request; DDG often rejects
        #   requests with no UA or an obvious bot UA
        USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                     '(KHTML, like Gecko) Chrome/120.0 Safari/537.36'
        # @return [Integer] default number of results returned, matching smolagents
        DEFAULT_MAX_RESULTS = 10
        # @return [RateLimiter] paces calls (DDG bans IPs that hammer the HTML
        #   endpoint) and circuit-breaks on {Engines::Unavailable} so a
        #   soft-block response doesn't get retried for the next 5 minutes
        LIMITER = RateLimiter.new(min_interval: 2.0, cooldown: 300.0)

        # Fetch results for +query+ and return them as an +Array<Result>+.
        # Calls are throttled to one every 2s and circuit-broken for 5 minutes
        # after a soft-block; see {LIMITER}. The caller (typically
        # {Engines.search}) is expected to have already normalized the
        # query and to wrap this in a result cache.
        #
        # @param query [String] search query (already normalized)
        # @param max_results [Integer] maximum number of result entries
        # @return [Array<Result>] hits, possibly empty when DDG ran the
        #   query and matched nothing
        # @raise [Engines::Unavailable] when DDG soft-blocks the IP
        #   (anomaly/CAPTCHA page) or returns HTTP 429/5xx — i.e. "try again
        #   later" responses the cascade in {Engines.search} can fall
        #   back from. Also raised immediately if {LIMITER} is in cooldown.
        # @raise [RuntimeError] if the HTTP call fails for other reasons or
        #   the empty-results page is in an unrecognized layout. A genuine
        #   empty-results page is *not* an error; see {.parse}.
        def self.search(query, max_results: DEFAULT_MAX_RESULTS)
          LIMITER.call do
            response = Faraday.get(ENDPOINT, { q: query }, { 'User-Agent' => USER_AGENT })
            unless response.success?
              if response.status == 429 || response.status >= 500
                raise Engines::Unavailable, "HTTP #{response.status}"
              end

              raise "DuckDuckGo request failed: #{response.status} #{response.body}"
            end

            parse(response.body, max_results: max_results)
          end
        end

        # Parse a +html.duckduckgo.com+ result page into a list of {Result}
        # rows. +<b>+ highlights inside snippets are stripped.
        #
        # When the page has zero result nodes, two cases are distinguished:
        # a genuine "no results" page (narrow query, DDG's own "No results
        # found" indicator) returns an empty array instead of raising, so
        # {Engines.search} can render its standard no-results stub.
        # Anything else (anomaly modal, CAPTCHA, service-unavailable page,
        # unknown layout) raises with the diagnostic text extracted from
        # the body, so an IP soft-block is surfaced rather than silently
        # masquerading as an empty search.
        #
        # @param html [String] HTML document body from html.duckduckgo.com
        # @param max_results [Integer] maximum number of result entries
        # @return [Array<Result>] hits, possibly empty on a genuine
        #   no-results page
        # @raise [Engines::Unavailable] when the page is the DDG
        #   anomaly/CAPTCHA modal (IP soft-block) — a "try again later" the
        #   cascade can fall back from.
        # @raise [RuntimeError] when the page contains no result nodes and is
        #   not recognized as either a genuine no-results page or the
        #   anomaly modal (likely a layout change worth surfacing loudly).
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

        # True when the page contains DDG's anomaly/CAPTCHA modal — i.e. the
        # IP has been soft-blocked. Used by {.parse} to pick between
        # {Engines::Unavailable} (recoverable, fall back to another
        # provider) and {RuntimeError} (unknown layout, surface loudly).
        #
        # @param doc [Nokogiri::HTML::Document] parsed result page
        # @return [Boolean]
        def self.anomaly_modal?(doc)
          !!(doc.at_css('.anomaly-modal__title') || doc.at_css('.anomaly-modal__description'))
        end
        private_class_method :anomaly_modal?

        # True when a results page with zero result nodes looks like DDG's own
        # "no results found" page (narrow query) rather than an anomaly/CAPTCHA
        # or other non-results layout. Anomaly modal wins: if the modal divs
        # are present we never treat the page as a genuine empty result, even
        # if the surrounding text happens to mention "No results".
        #
        # @param doc [Nokogiri::HTML::Document] parsed result page
        # @return [Boolean]
        def self.genuine_no_results?(doc)
          return false if doc.at_css('.anomaly-modal__title') || doc.at_css('.anomaly-modal__description')
          return true if doc.at_css('div.no-results')

          doc.text.include?('No results found')
        end
        private_class_method :genuine_no_results?

        # Build an error message for a results page that yielded zero matches.
        # Recognizes the DDG anomaly modal explicitly and quotes its title and
        # description; otherwise extracts visible text from the body (with
        # +<script>+/+<style>+/+<noscript>+ stripped and whitespace collapsed)
        # and includes a truncated copy so the caller can see what came back.
        #
        # @param doc [Nokogiri::HTML::Document] parsed result page
        # @return [String] human-readable diagnostic to feed to +raise+
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

        # Decode DuckDuckGo's +//duckduckgo.com/l/?uddg=<encoded>+ redirect wrapper
        # back to the real target URL.
        #
        # @param href [String, nil] href as found on the search-result page
        # @return [String] the decoded target URL, or +href+ unchanged when it is
        #   not a recognized DDG redirect or cannot be parsed
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
