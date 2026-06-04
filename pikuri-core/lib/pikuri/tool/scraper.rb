# frozen_string_literal: true

require 'faraday'
require 'stringio'
require 'uri'

module Pikuri
  class Tool
    # HTTP side of the web tools ({Tool::WEB_SCRAPE} and {Tool::FETCH}):
    # GET the URL with a real-browser User-Agent, follow redirects, and
    # hand the response body to {Pikuri::Extractor.extract} with the
    # response's +Content-Type+ as the hint. HTML/XHTML render via
    # {Extractor::HTML}, any other +text/*+ type passes through
    # verbatim, and plug-in extractors extend the set (with pikuri-pdf
    # registered, +application/pdf+ extracts — by header or by +%PDF-+
    # magic, so a PDF served under a lying header still works); the
    # remaining types raise {FetchError} so the LLM observes the
    # failure instead of receiving an empty rendering.
    #
    # Split into a thin HTTP fetch ({.fetch}) and the extraction
    # wrapper ({.visit}) so tests can drive each piece in isolation and
    # {Tool::Fetch} can reuse the HTTP half without the extraction
    # pass. Nothing here knows about the LLM; the tools that wrap this
    # module own caching and truncation and turn rendered Markdown (or
    # {FetchError}) into the next observation.
    module Scraper
      # Raised when a URL cannot be rendered into Markdown text — HTTP
      # non-2xx, network failure, redirect-loop, missing +Location+,
      # unsupported content-type, or a parse failure that reads as "try
      # a different URL" to the LLM. Catching this in
      # {Tool::WEB_SCRAPE} / {Tool::FETCH} turns the failure into an
      # +"Error: ..."+ observation; anything else bubbles up so genuine
      # bugs stay visible.
      class FetchError < StandardError; end

      # @return [String] User-Agent sent with each request; many sites
      #   reject requests with no UA or an obvious bot UA
      USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 ' \
                   '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      # @return [String] +Accept+ header sent with each request, so
      #   servers that content-negotiate hand back something we can use:
      #   rendered HTML first, +application/pdf+ for hosts with a PDF
      #   extractor registered, then any +text/*+ for the verbatim
      #   pass-through arm.
      ACCEPT = 'text/html,application/xhtml+xml,application/pdf,text/*;q=0.8'
      # @return [Integer] maximum number of HTTP redirects to follow
      #   before giving up
      MAX_REDIRECTS = 5
      # @return [Integer] connect timeout in seconds for the underlying
      #   Faraday request
      OPEN_TIMEOUT = 10
      # @return [Integer] read timeout in seconds for the underlying
      #   Faraday request
      READ_TIMEOUT = 20

      # @return [Integer] maximum number of characters of an error
      #   response body to include in a {FetchError} message. The body is
      #   often a multi-kilobyte HTML challenge page (Cloudflare, WAF
      #   interstitial, etc.); a short excerpt tells the LLM what kind of
      #   page came back without flooding the next observation.
      ERROR_BODY_EXCERPT = 200

      # Result of a successful {Scraper.fetch}: the response body, the
      # normalized content-type (lower-cased, with any +; charset=...+
      # parameters stripped), and the final URL after redirects.
      Fetched = Data.define(:body, :content_type, :url)

      # Fetch +url+ and render its main content as Markdown.
      #
      # No caching here — every call hits the network. Callers that want
      # to memoize results should wrap this method themselves (see
      # {Tool::WebScrape.visit}, which does exactly that).
      #
      # The extracted output is +String#strip+'d so the LLM never sees
      # a body that opens or closes with blank lines — common with
      # extracted PDFs' page-feed whitespace and with text bodies that
      # carry a trailing newline. Interior whitespace is preserved
      # because Markdown paragraph breaks and source-code indentation
      # are load-bearing.
      #
      # @param url [String] absolute HTTP(S) URL of the page to download
      # @return [String] full Markdown representation of the page with
      #   leading/trailing whitespace trimmed, uncapped otherwise —
      #   caller is responsible for any size limiting before feeding
      #   the result back to the LLM
      # @raise [FetchError] on HTTP non-2xx, network failure, redirect
      #   loop, a 3xx without a +Location+ header, a response no
      #   extractor recognizes, or an extraction failure (malformed
      #   PDF, ...)
      def self.visit(url)
        extract(fetch(url)).strip
      end

      # Render a {Fetched} response as Markdown via
      # {Pikuri::Extractor.extract}, re-raising both extraction failure
      # modes as {FetchError} — the single exception type the web tools
      # rescue. The content-type is passed verbatim (including the +""+
      # of a missing header, which matches no text arm — a body without
      # transport metadata is refused, not sniffed; only a strong magic
      # sniff like pikuri-pdf's +%PDF-+ overrides a wrong or missing
      # header, because such a sniff never misfires on text).
      #
      # @param fetched [Fetched]
      # @return [String] Markdown representation produced by the
      #   matched extractor
      # @raise [FetchError] when no extractor matches the response's
      #   content-type, or when extraction fails
      def self.extract(fetched)
        Pikuri::Extractor.extract(StringIO.new(fetched.body), content_type: fetched.content_type)
      rescue Pikuri::Extractor::Unsupported
        raise FetchError, "unsupported content-type #{fetched.content_type.inspect} for #{fetched.url}"
      rescue Pikuri::Extractor::Error => e
        raise FetchError, e.message
      end

      # Download the body of +url+, manually following up to
      # {MAX_REDIRECTS} redirects. Faraday is configured with no
      # middleware so behavior here mirrors the rest of the codebase
      # (see +Tool::Search::DuckDuckGo.search+).
      #
      # All recoverable failures — HTTP 4xx/5xx, +Faraday::Error+ network
      # blips, exhausted redirect budget, 3xx without a +Location+ —
      # surface as {FetchError} so the caller has a single exception type
      # to rescue. Error bodies are trimmed to {ERROR_BODY_EXCERPT}
      # characters with whitespace collapsed, so a Cloudflare-challenge
      # response doesn't dump kilobytes of inline HTML into the next LLM
      # observation.
      #
      # @param url [String] absolute HTTP(S) URL to fetch
      # @param limit [Integer] redirects remaining; recurses with
      #   +limit - 1+ on each 3xx
      # @return [Fetched] body, normalized content-type, and final URL
      #   after redirects
      # @raise [FetchError] on non-2xx/3xx responses, network errors,
      #   redirect-loop exhaustion, or 3xx without a +Location+ header
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

      # Whitespace-collapse +body+ and clip to {ERROR_BODY_EXCERPT}
      # characters, so the {FetchError} message stays a single readable
      # line even when the server returned a multi-KB HTML challenge
      # page.
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
