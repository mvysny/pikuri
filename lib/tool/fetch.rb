# frozen_string_literal: true

class Tool
  # Truncation policy and Tool spec for the +fetch+ tool. The HTTP work
  # lives in {Tool::Scraper::Simple.fetch}; this module is a thin
  # wrapper that accepts only textual content-types, applies a character
  # cap so the LLM doesn't drown in long-form bodies, and exposes the
  # result to the agent loop in OpenAI tool-call shape.
  #
  # Sister of {Tool::WebScrape}, but without HTML→Markdown or PDF→text
  # extraction: bodies are returned verbatim. Useful for raw textual
  # data — JSON APIs, CSV files, +robots.txt+, sitemaps, source files —
  # where any rendering pass would corrupt the payload.
  module Fetch
    # @return [Integer] default character cap on the body returned by
    #   {.fetch}. Smaller than {Tool::WebScrape::DEFAULT_MAX_CHARS}
    #   because fetch's content profile is bimodal — most JSON/XML/CSV
    #   responses are tiny, and the long-tail (large data dumps) is
    #   better re-requested deliberately than padded into every default.
    DEFAULT_MAX_CHARS = 5_000

    # @return [Integer] hard ceiling on the +max_chars+ argument to
    #   {.fetch}. Matches {Tool::WebScrape::MAX_MAX_CHARS}.
    MAX_MAX_CHARS = 100_000

    # Application content-types that are textual in practice and so
    # safe to return verbatim to the LLM, despite their +application/+
    # prefix making them fail the +text/*+ check. Anything outside
    # +text/*+ and this allowlist is refused.
    # @return [Array<String>]
    TEXTUAL_APPLICATION_TYPES = %w[
      application/json
      application/xml
      application/javascript
      application/xhtml+xml
      application/rss+xml
      application/atom+xml
    ].freeze

    # On-disk cache used by {.fetch} to memoize downloads. Defined as a
    # method so specs can swap it for an isolated cache or
    # {UrlCache::NULL} without touching the shared instance. Lives in
    # its own subdir under {UrlCache::ROOT_DIR} so a +fetch+ on a URL
    # and a +web_scrape+ on the same URL cannot collide on the same
    # cache file (one returns the raw body, the other returns extracted
    # Markdown).
    #
    # @return [UrlCache, #fetch]
    CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/fetch")
    def self.cache
      CACHE
    end

    # Download +url+ via {Tool::Scraper::Simple.fetch} and return the
    # response body verbatim, provided the content-type is one we deem
    # textual (any +text/*+, plus the formats listed in
    # {TEXTUAL_APPLICATION_TYPES}). Anything else — PDFs, images, other
    # binaries — produces an +"Error: ..."+ string in the calculator-
    # style convention so the agent loop feeds the failure back to the
    # model as the next observation.
    #
    # The body is cached on disk via {.cache}, keyed by URL, so repeat
    # fetches within the cache TTL skip the network. +max_chars+ is not
    # part of the cache key — different values for the same URL share
    # one entry, and truncation runs after the cache lookup. The cache
    # is only populated on success: {Scraper::FetchError} (HTTP non-2xx,
    # network failure, redirect-loop exhaustion, refused content-type)
    # is caught outside the +cache.fetch+ block, so failure strings are
    # never persisted and a retry on the next call hits the network
    # again. Other exceptions (parser bugs in our own code) bubble up
    # unchanged.
    #
    # @param url [String] absolute HTTP(S) URL to download
    # @param max_chars [Integer] character cap on the returned body.
    #   Clamped to +[1, {MAX_MAX_CHARS}]+; defaults to
    #   {DEFAULT_MAX_CHARS}. When the body exceeds the cap, output is
    #   cut and a marker noting the original length is appended.
    # @return [String] response body, possibly truncated, or
    #   +"Error: ..."+ on a recoverable failure
    def self.fetch(url, max_chars: DEFAULT_MAX_CHARS)
      max_chars = max_chars.clamp(1, MAX_MAX_CHARS)
      body = cache.fetch(url) { download(url) }
      truncate(body, max_chars)
    rescue Scraper::FetchError => e
      "Error: #{e.message}"
    end

    # GET +url+ and verify the response's content-type is textual.
    # Caller is responsible for caching and truncation; this method
    # always hits the network.
    #
    # @param url [String]
    # @return [String] response body
    # @raise [Scraper::FetchError] on HTTP non-2xx, network failure,
    #   redirect-loop exhaustion, missing +Location+ on a 3xx, or a
    #   non-textual content-type
    def self.download(url)
      fetched = Scraper::Simple.fetch(url)
      return fetched.body if textual?(fetched.content_type)

      raise Scraper::FetchError,
            "refused to fetch #{url}: content-type #{fetched.content_type.inspect} " \
            'is not textual (use web_scrape for PDFs or rendered pages)'
    end

    # @param content_type [String] normalized content-type (no +charset+
    #   parameter, lowercased) as produced by {Scraper::Simple.fetch}
    # @return [Boolean] true when the content-type is +text/*+ or one
    #   of {TEXTUAL_APPLICATION_TYPES}
    def self.textual?(content_type)
      content_type.start_with?('text/') ||
        TEXTUAL_APPLICATION_TYPES.include?(content_type)
    end

    # Cut +body+ to at most +max_chars+ characters, appending a marker
    # describing the original length when truncation actually happens.
    # Returns +body+ unchanged if it already fits. Same shape as
    # {Tool::WebScrape.truncate} so the LLM sees a consistent
    # truncation marker across both tools.
    #
    # @param body [String] full response body
    # @param max_chars [Integer] character cap; assumed already clamped
    # @return [String]
    def self.truncate(body, max_chars)
      return body if body.length <= max_chars

      "#{body[0, max_chars]}\n\n" \
        "... [truncated at #{max_chars} of #{body.length} chars; " \
        'call again with a larger `max_chars` to see more]'
    end
  end

  # Verbatim URL download tool. Thin wrapper over {Tool::Fetch.fetch}
  # that exposes it to the agent loop in OpenAI tool-call shape. Use for
  # raw textual payloads (JSON APIs, CSV files, +robots.txt+, source
  # files); use {Tool::WEB_SCRAPE} for rendered web pages or PDFs where
  # readability extraction makes the result usable.
  #
  # @return [Tool]
  FETCH = new(
    name: 'fetch',
    description: 'Downloads the given URL and returns its body verbatim. ' \
                 'Accepts text/* and a fixed allowlist of textual ' \
                 'application/* types (JSON, XML, JavaScript, XHTML, RSS, ' \
                 'Atom); refuses PDFs, images, and other binary content. ' \
                 'Prefer web_scrape for rendered HTML pages or PDFs — ' \
                 'web_scrape extracts the readable content, while fetch ' \
                 'returns the raw bytes.',
    parameters: Parameters.build { |p|
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
    }
  )
end
