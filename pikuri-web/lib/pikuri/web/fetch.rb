# frozen_string_literal: true

module Pikuri
  module Web
    # Truncation policy and Tool spec for the +fetch+ tool. HTTP work lives in
    # {Web::Scraper.fetch}; this wrapper accepts only textual content-types,
    # applies a character cap, and exposes the result in OpenAI tool-call shape.
    # Sister of {Web::Scrape} but with no extraction pass — bodies are
    # returned verbatim, for raw textual data (JSON APIs, CSV, +robots.txt+,
    # sitemaps, source files) where a rendering pass would corrupt the payload.
    module Fetch
      # @return [Integer] default character cap on the body from {.fetch}.
      #   Smaller than {Web::Scrape::DEFAULT_MAX_CHARS} because fetch's
      #   content is bimodal — most JSON/XML/CSV is tiny, and large dumps are
      #   better re-requested deliberately than padded into every default.
      DEFAULT_MAX_CHARS = 5_000

      # @return [Integer] hard ceiling on {.fetch}'s +max_chars+; matches
      #   {Web::Scrape::MAX_MAX_CHARS}.
      MAX_MAX_CHARS = 100_000

      # Application content-types that are textual in practice, so safe to
      # return verbatim despite failing the +text/*+ check. Anything outside
      # +text/*+ and this list is refused.
      # @return [Array<String>]
      TEXTUAL_APPLICATION_TYPES = %w[
        application/json
        application/xml
        application/javascript
        application/xhtml+xml
        application/rss+xml
        application/atom+xml
      ].freeze

      # On-disk cache for {.fetch}, in its own subdir so a +fetch+ and a
      # +web_scrape+ on the same URL don't collide (raw body vs extracted
      # Markdown). A method so specs can swap {UrlCache::NULL}.
      #
      # @return [UrlCache::OnDisk, #fetch]
      CACHE = UrlCache::OnDisk.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/fetch")
      # Accessor for {CACHE}; specs swap in {UrlCache::NULL} or an isolated cache.
      #
      # @return [UrlCache::OnDisk, #fetch]
      def self.cache
        CACHE
      end

      # Download +url+ via {Web::Scraper.fetch} and return the body verbatim,
      # if the content-type is textual (any +text/*+ plus
      # {TEXTUAL_APPLICATION_TYPES}); anything else (PDF, image, binary) yields
      # an +"Error: ..."+ string. Cached on disk keyed by URL; +max_chars+ is
      # *not* in the key (values share one entry, truncation runs after the
      # lookup). Cached only on success — {Scraper::FetchError} is caught
      # outside +cache.fetch+, so failures are never persisted; other
      # exceptions bubble up.
      #
      # @param url [String] absolute HTTP(S) URL
      # @param max_chars [Integer] body cap, clamped to +[1, {MAX_MAX_CHARS}]+;
      #   default {DEFAULT_MAX_CHARS}. Over the cap, output is cut with a marker.
      # @return [Tool::Result] the body, possibly truncated (+"Fetched 4.2 kB"+),
      #   or {Pikuri::Tool::Result.error} on a recoverable failure
      def self.fetch(url, max_chars: DEFAULT_MAX_CHARS)
        max_chars = max_chars.clamp(1, MAX_MAX_CHARS)
        body = cache.fetch(url) { download(url) }
        Tool::Result.new(content: truncate(body, max_chars),
                         summary: Scraper.transfer_summary(verb: 'Fetched', full: body, max_chars: max_chars))
      rescue Scraper::FetchError => e
        Tool::Result.error(e.message)
      end

      # GET +url+ and verify the content-type is textual. Always hits the
      # network (caller caches/truncates).
      #
      # @param url [String]
      # @return [String] response body
      # @raise [Scraper::FetchError] on HTTP non-2xx, network failure, redirect
      #   exhaustion, missing +Location+, or a non-textual content-type
      def self.download(url)
        fetched = Scraper.fetch(url)
        return fetched.body if textual?(fetched.content_type)

        raise Scraper::FetchError,
              "refused to fetch #{url}: content-type #{fetched.content_type.inspect} " \
              'is not textual (use web_scrape for rendered pages)'
      end

      # @param content_type [String] normalized content-type from {Scraper.fetch}
      # @return [Boolean] true when +text/*+ or in {TEXTUAL_APPLICATION_TYPES}
      def self.textual?(content_type)
        content_type.start_with?('text/') ||
          TEXTUAL_APPLICATION_TYPES.include?(content_type)
      end

      # Cut +body+ to at most +max_chars+, appending a marker with the original
      # length when truncation happens. Same shape as {Web::Scrape.truncate}.
      #
      # @param body [String] full response body
      # @param max_chars [Integer] cap; assumed already clamped
      # @return [String]
      def self.truncate(body, max_chars)
        return body if body.length <= max_chars

        "#{body[0, max_chars]}\n\n" \
          "... [truncated at #{max_chars} of #{body.length} chars; " \
          'call again with a larger `max_chars` to see more]'
      end
    end

    # Verbatim URL download tool — a thin wrapper over {Web::Fetch.fetch} in
    # OpenAI tool-call shape. Use for raw textual payloads (JSON, CSV,
    # +robots.txt+, source files); use {Web::SCRAPE} for rendered pages.
    #
    # Sharing: +P_shared_benign+ — no per-agent state, but {Fetch::CACHE} is
    # process-wide (and on disk, so cross-process too): agent B's +fetch+ can
    # be answered from agent A's download within the TTL. See
    # {Pikuri::Web::UrlCache::OnDisk} for the race and why it's harmless.
    #
    # @return [Tool]
    FETCH = Tool.new(
      name: 'fetch',
      description: <<~DESC,
        Downloads the given URL and returns its body verbatim.

        Usage:
        - Use for raw textual payloads: JSON APIs, CSV files, robots.txt, sitemaps, source files — anywhere a rendering pass would corrupt the data.
        - For rendered HTML pages, use web_scrape — it extracts readable content; fetch returns the raw HTML bytes unchanged.
        - Accepts text/* and common textual application/* types (JSON, XML, JS, XHTML, RSS, Atom). Refuses PDFs, images, and other binaries.
      DESC
      parameters: Tool::Parameters.build { |p|
        p.required_string :url,
                          'Absolute URL to download, including the scheme, ' \
                          'e.g. "https://example.com/data.json".'
        p.optional_integer :max_chars,
                           'Maximum number of characters of the body to ' \
                           'return. Defaults to 5000; hard-capped at ' \
                           '100000. When the body is longer than this, ' \
                           'output is cut and a marker reports the full ' \
                           'length.'
      },
      execute: ->(url:, max_chars: Fetch::DEFAULT_MAX_CHARS) {
        Fetch.fetch(url, max_chars: max_chars)
      },
      # As {SCRAPE}: attacker-choosable host, attacker-authored response.
      trifecta_legs: Pikuri::Tool::TrifectaLegs::ASSUMED
    )
  end
end
