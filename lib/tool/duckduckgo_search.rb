# frozen_string_literal: true

require 'faraday'
require 'nokogiri'
require 'uri'

require 'url_cache'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order, and exposing it as +Tool::WEB_SEARCH+ requires +Tool+
# already be a class.
class Tool
  # Performs a DuckDuckGo search by scraping +html.duckduckgo.com+ and renders
  # the results as smolagents-style Markdown. Split into a thin HTTP fetch
  # (#search) and a pure parser (#parse) so tests can exercise the parser
  # against fixture HTML without hitting the network.
  #
  # DuckDuckGo is Bing in disguise which means Microsoft which means no privacy: don't trust
  # this search for anything private.
  module DuckDuckGoSearch
    # @return [String] HTML search endpoint
    ENDPOINT = 'https://html.duckduckgo.com/html/'
    # @return [String] User-Agent sent with each request; DDG often rejects
    #   requests with no UA or an obvious bot UA
    USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                 '(KHTML, like Gecko) Chrome/120.0 Safari/537.36'
    # @return [Integer] default number of results returned, matching smolagents
    DEFAULT_MAX_RESULTS = 10
    # @return [Float] minimum seconds between consecutive {.search} calls; DDG
    #   bans IPs that hammer the HTML endpoint from a script
    MIN_INTERVAL = 2.0
    # @return [Mutex] serializes {.search} so the {MIN_INTERVAL} throttle and
    #   the HTTP fetch itself remain correct under concurrent agents/threads
    MUTEX = Mutex.new

    # Fetch results for +query+ and render them as smolagents-style Markdown.
    # The query is whitespace-trimmed and runs of whitespace are collapsed to
    # a single space before being sent to DuckDuckGo. Calls are throttled to
    # at most one every {MIN_INTERVAL} seconds; if the previous call was more
    # recent the method blocks until the budget elapses. Concurrent calls are
    # serialized via {MUTEX} so the throttle holds across threads.
    #
    # Results are cached on disk via {UrlCache::DEFAULT}, keyed by the
    # cleaned query string. A cache hit skips both the throttle and the
    # network call. +max_results+ is not part of the cache key — in
    # practice the tool wrapper always uses {DEFAULT_MAX_RESULTS} — so
    # callers passing a non-default value may get a result rendered with
    # the previously-cached size.
    #
    # @param query [String] search query
    # @param max_results [Integer] maximum number of result entries to render
    # @return [String] Markdown-formatted result list
    # @raise [ArgumentError] if the query is empty after normalization
    # @raise [RuntimeError] if the HTTP call to DuckDuckGo fails, or if the
    #   response contains no results (typically an anomaly/CAPTCHA page when
    #   the IP has been soft-blocked)
    def self.search(query, max_results: DEFAULT_MAX_RESULTS)
      cleaned = query.to_s.strip.gsub(/\s+/, ' ')
      raise ArgumentError, 'query is empty' if cleaned.empty?

      UrlCache::DEFAULT.fetch(cleaned) do
        MUTEX.synchronize do
          if @last_query_at
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @last_query_at
            sleep(MIN_INTERVAL - elapsed) if elapsed < MIN_INTERVAL
          end
          @last_query_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

          response = Faraday.get(ENDPOINT, { q: cleaned }, { 'User-Agent' => USER_AGENT })
          raise "DuckDuckGo request failed: #{response.status} #{response.body}" unless response.success?

          parse(response.body, max_results: max_results)
        end
      end
    end

    # Parse a +html.duckduckgo.com+ result page into smolagents-style Markdown:
    # +"## Search Results"+ followed by +[title](href)\nbody+ entries joined by
    # blank lines. +<b>+ highlights inside snippets are stripped.
    #
    # An empty result list is treated as a failure — DDG always returns at
    # least one match for any non-empty query, so zero matches means the
    # page is a CAPTCHA/anomaly challenge or some other non-results page.
    # In that case the method raises with the diagnostic text extracted from
    # the body (anomaly modal if recognized, otherwise visible page text)
    # so the agent loop sees a real error instead of a fake "no results".
    #
    # @param html [String] HTML document body from html.duckduckgo.com
    # @param max_results [Integer] maximum number of result entries to render
    # @return [String] Markdown-formatted result list
    # @raise [RuntimeError] when the page contains no result nodes
    def self.parse(html, max_results: DEFAULT_MAX_RESULTS)
      doc = Nokogiri::HTML(html)
      results = doc.css('div.result.web-result').take(max_results).filter_map do |node|
        title_link = node.at_css('a.result__a')
        next nil if title_link.nil?

        snippet = node.at_css('a.result__snippet')
        {
          title: title_link.text.strip,
          href: extract_url(title_link['href']),
          body: snippet&.text&.strip.to_s
        }
      end

      raise diagnose_empty(doc) if results.empty?

      "## Search Results\n\n" + results.map { |r| "[#{r[:title]}](#{r[:href]})\n#{r[:body]}" }.join("\n\n")
    end

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
      snippet = text.empty? ? '<empty body>' : text[0, 800]
      snippet += '…' if text.length > 800
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

  # DuckDuckGo-backed web-search tool. Thin wrapper over
  # {Tool::DuckDuckGoSearch.search} that exposes it to the agent loop in
  # OpenAI tool-call shape.
  #
  # @return [Tool]
  WEB_SEARCH = new(
    name: 'web_search',
    description: 'Searches the web for a query and returns the top results ' \
                 'as a Markdown list of titles, links, and short snippets. ' \
                 'The snippets are typically a sentence or two — not the ' \
                 'page contents — so they are rarely enough to answer a ' \
                 'question on their own. After running this tool, pick the ' \
                 'most promising URL(s) from the results and call ' \
                 '`visit_webpage` on each to read the actual content.',
    parameters: Parameters.build { |p|
      p.required_string :query, 'The search query to perform.'
    },
    execute: ->(query:) { DuckDuckGoSearch.search(query) }
  )
end
