# frozen_string_literal: true

require 'faraday'
require 'stringio'
require 'uri'

module Pikuri
  class Tool
    # HTTP side of the web tools ({Tool::WEB_SCRAPE} and {Tool::FETCH}): GET the
    # URL with a real-browser User-Agent, follow redirects, and hand the body to
    # {Pikuri::Extractor.extract} with the response +Content-Type+ as the hint.
    # HTML/XHTML renders via {Extractor::HTML}, other +text/*+ passes through
    # verbatim, plug-in extractors extend the set (with pikuri-pdf,
    # +application/pdf+ extracts — by header or +%PDF-+ magic, so a lying header
    # still works); remaining types raise {FetchError} so the LLM observes the
    # failure rather than an empty rendering.
    #
    # Split into a thin HTTP fetch ({.fetch}) and the extraction wrapper
    # ({.visit}) so tests drive each in isolation and {Tool::Fetch} can reuse the
    # HTTP half. Nothing here knows about the LLM — the wrapping tools own
    # caching, truncation, and turning the result into an observation.
    module Scraper
      # Raised when a URL can't be rendered to Markdown — HTTP non-2xx, network
      # failure, redirect loop, missing +Location+, unsupported content-type, or
      # a parse failure. The web tools rescue this into an +"Error: ..."+
      # observation; anything else bubbles up so genuine bugs stay visible.
      class FetchError < StandardError; end

      # @return [String] User-Agent sent with each request; many sites reject a
      #   missing or obviously-bot UA.
      USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                   '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      # @return [String] +Accept+ header, so content-negotiating servers hand
      #   back something usable: HTML first, then +application/pdf+, then +text/*+.
      ACCEPT = 'text/html,application/xhtml+xml,application/pdf,text/*;q=0.8'
      # @return [Integer] maximum HTTP redirects to follow before giving up.
      MAX_REDIRECTS = 5
      # @return [Integer] connect timeout (s) for the Faraday request.
      OPEN_TIMEOUT = 10
      # @return [Integer] read timeout (s) for the Faraday request.
      READ_TIMEOUT = 20

      # @return [Integer] max chars of an error response body in a {FetchError}
      #   message — enough to show what came back (a Cloudflare/WAF page) without
      #   flooding the observation.
      ERROR_BODY_EXCERPT = 200

      # Result of a successful {Scraper.fetch}: the response body, the
      # normalized content-type (lower-cased, with any +; charset=...+
      # parameters stripped), and the final URL after redirects.
      Fetched = Data.define(:body, :content_type, :url)

      # Fetch +url+ and render its main content as Markdown. No caching — every
      # call hits the network (wrap it to memoize; {Tool::WebScrape.visit}
      # does). The output is +strip+'d (leading/trailing blank lines are common
      # from PDF page-feeds and trailing newlines) but interior whitespace is
      # preserved (paragraph breaks and code indentation are load-bearing).
      #
      # @param url [String] absolute HTTP(S) URL
      # @return [String] Markdown, whitespace-trimmed, otherwise uncapped —
      #   caller size-limits before feeding the LLM
      # @raise [FetchError] on HTTP non-2xx, network failure, redirect loop, a
      #   3xx without +Location+, an unrecognized response, or extraction failure
      def self.visit(url)
        extract(fetch(url)).strip
      end

      # Render a {Fetched} response as Markdown via {Pikuri::Extractor.extract},
      # re-raising both extraction failure modes as {FetchError}. The
      # content-type is passed verbatim (including +""+ for a missing header,
      # which matches no text arm — a body without transport metadata is
      # refused, not sniffed; only a strong magic sniff like +%PDF-+ overrides).
      #
      # @param fetched [Fetched]
      # @return [String] Markdown from the matched extractor
      # @raise [FetchError] when no extractor matches, or extraction fails
      def self.extract(fetched)
        Pikuri::Extractor.extract(StringIO.new(fetched.body), content_type: fetched.content_type)
      rescue Pikuri::Extractor::Unsupported
        raise FetchError, "unsupported content-type #{fetched.content_type.inspect} for #{fetched.url}"
      rescue Pikuri::Extractor::Error => e
        raise FetchError, e.message
      end

      # Download +url+, manually following up to {MAX_REDIRECTS} redirects. All
      # recoverable failures (HTTP 4xx/5xx, +Faraday::Error+, exhausted redirect
      # budget, 3xx without +Location+) surface as {FetchError}. Error bodies
      # are trimmed to {ERROR_BODY_EXCERPT} so a challenge page doesn't dump
      # kilobytes into the observation.
      #
      # @param url [String] absolute HTTP(S) URL
      # @param limit [Integer] redirects remaining; recurses with +limit - 1+ on 3xx
      # @return [Fetched] body, normalized content-type, final URL
      # @raise [FetchError] on non-2xx/3xx, network error, redirect-loop
      #   exhaustion, or 3xx without +Location+
      def self.fetch(url, limit: MAX_REDIRECTS)
        raise FetchError, "too many redirects fetching #{url}" if limit.zero?

        response = begin
          Faraday.new(request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT }).get(url) do |req|
            req.headers['User-Agent'] = USER_AGENT
            req.headers['Accept']     = ACCEPT
          end
        rescue Faraday::Error => e
          raise FetchError, "#{e.class.name.split('::').last} fetching #{url}: #{e.message}"
        end

        case response.status
        when 200..299
          Fetched.new(body: response.body, content_type: normalize_content_type(response.headers['content-type']), url: url)
        when 300..399
          location = response.headers['location']
          raise FetchError, "HTTP #{response.status} from #{url} with no Location header" if location.nil? || location.empty?

          fetch(URI.join(url, location).to_s, limit: limit - 1)
        else
          raise FetchError, "HTTP #{response.status} fetching #{url}: #{excerpt(response.body)}"
        end
      end

      # Display line for a downloaded body — what the model got, plus the full
      # size when the cap cut it:
      #
      #   Scraper.transfer_summary(verb: 'Fetched', full: body, max_chars: 5_000)
      #   # => "Fetched 5.0 kB of 41.2 kB"
      #
      # No content-type in it: both wrappers cache the *body*, so a cache hit
      # has no header to report, and a line that came and went with the cache
      # would be worse than one that never names the type.
      #
      # @param verb [String] +"Fetched"+ or +"Scraped"+
      # @param full [String] the whole body, before truncation
      # @param max_chars [Integer] the cap applied to it
      # @return [String]
      def self.transfer_summary(verb:, full:, max_chars:)
        return "#{verb} #{Pikuri::Tool.format_bytes(full.bytesize)}" if full.length <= max_chars

        "#{verb} #{Pikuri::Tool.format_bytes(full[0, max_chars].bytesize)} " \
          "of #{Pikuri::Tool.format_bytes(full.bytesize)}"
      end

      # Lower-case +raw+ and strip any +; charset=...+ parameters so the
      # extractors can match on a canonical token.
      #
      # @param raw [String, nil] raw +Content-Type+ header value
      # @return [String] normalized content-type, or +""+ when the
      #   header was missing
      def self.normalize_content_type(raw)
        raw.to_s.split(';').first.to_s.strip.downcase
      end
      private_class_method :normalize_content_type

      # Whitespace-collapse +body+ and clip to {ERROR_BODY_EXCERPT}, keeping the
      # {FetchError} message a single readable line.
      #
      # @param body [String, nil]
      # @return [String]
      def self.excerpt(body)
        text = body.to_s.gsub(/\s+/, ' ').strip
        text.length > ERROR_BODY_EXCERPT ? "#{text[0, ERROR_BODY_EXCERPT]}..." : text
      end
      private_class_method :excerpt
    end
  end
end
