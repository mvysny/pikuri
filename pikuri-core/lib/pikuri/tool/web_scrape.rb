# frozen_string_literal: true

module Pikuri
  class Tool
    # Truncation policy and Tool spec for the +web_scrape+ tool. Scraping lives
    # in {Tool::Scraper}; this wrapper applies a character cap and exposes the
    # result in OpenAI tool-call shape.
    module WebScrape
      # @return [Integer] default character cap on the Markdown from {.visit}.
      #   Sized to cover most post-readability article bodies in full on the
      #   first call, so the LLM doesn't re-request and duplicate the prefix in
      #   its context. Genuinely long pages still get cut, and the marker invites
      #   a deliberate larger call.
      DEFAULT_MAX_CHARS = 20_000

      # @return [Integer] hard ceiling on {.visit}'s +max_chars+; requests above
      #   it are clamped silently so the LLM can't dump an arbitrarily large page.
      MAX_MAX_CHARS = 100_000

      # On-disk cache for {.visit}. A method so specs can swap {UrlCache::NULL}.
      #
      # @return [UrlCache, #fetch]
      CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_scrape")
      # Accessor for {CACHE}; specs swap in {UrlCache::NULL} or an isolated cache.
      #
      # @return [UrlCache, #fetch]
      def self.cache
        CACHE
      end

      # Fetch +url+ via {Tool::Scraper} and truncate the rendered Markdown to
      # +max_chars+. The full Markdown is cached on disk keyed by URL (repeat
      # visits skip the network and extraction); +max_chars+ is *not* in the key
      # (values share one entry, truncation runs after the lookup).
      # {Scraper::FetchError} is caught outside +cache.fetch+ and returned as
      # +"Error: ..."+ (so the LLM can retry a different URL) — never persisted;
      # other exceptions bubble up.
      #
      # @param url [String] absolute HTTP(S) URL
      # @param max_chars [Integer] Markdown cap, clamped to +[1, {MAX_MAX_CHARS}]+;
      #   default {DEFAULT_MAX_CHARS}. Over the cap, output is cut with a marker.
      # @return [String] Markdown, possibly truncated, or +"Error: ..."+ on a
      #   recoverable fetch failure
      def self.visit(url, max_chars: DEFAULT_MAX_CHARS)
        max_chars = max_chars.clamp(1, MAX_MAX_CHARS)
        markdown = cache.fetch(url) { Scraper.visit(url) }
        truncate(markdown, max_chars)
      rescue Scraper::FetchError => e
        "Error: #{e.message}"
      end

      # Cut +markdown+ to at most +max_chars+, appending a marker with the
      # original length when truncation happens.
      #
      # @param markdown [String] full Markdown text
      # @param max_chars [Integer] cap; assumed already clamped
      # @return [String]
      def self.truncate(markdown, max_chars)
        return markdown if markdown.length <= max_chars

        "#{markdown[0, max_chars]}\n\n" \
          "... [truncated at #{max_chars} of #{markdown.length} chars; " \
          'call again with a larger `max_chars` to see more]'
      end
    end

    # Webpage download + Markdown conversion tool — a thin wrapper over
    # {Tool::WebScrape.visit} in OpenAI tool-call shape.
    #
    # Sharing: +P_shared_benign+ — as {Tool::FETCH}: no per-agent state, but
    # {WebScrape::CACHE} is process-wide and on disk, so one agent's scrape
    # answers another's within the TTL. See {Pikuri::UrlCache}.
    #
    # @return [Tool]
    WEB_SCRAPE = new(
      name: 'web_scrape',
      description: <<~DESC,
        Scrapes the rendered webpage or text file at the given URL and returns its main content as Markdown.

        Usage:
        - Use for HTML pages where you want readable content — readability extraction strips nav, sidebars, and boilerplate.
        - For raw textual payloads (JSON, CSV, robots.txt, source files), use fetch instead — it returns bytes verbatim, while web_scrape would corrupt them with a Markdown pass.
        - A Single Page App may return very little or no content. Do NOT retry with a larger max_chars; try a different URL instead.
      DESC
      parameters: Parameters.build { |p|
        p.required_string :url,
                          'Absolute URL of the webpage to scrape, including ' \
                          'the scheme, e.g. "https://example.com/article".'
        p.optional_integer :max_chars,
                           'Maximum number of characters of Markdown to ' \
                           'return. Defaults to 20000; hard-capped at ' \
                           '100000. When the page is longer than this, ' \
                           'output is cut and a marker reports the full ' \
                           'length.'
      },
      execute: ->(url:, max_chars: WebScrape::DEFAULT_MAX_CHARS) {
        WebScrape.visit(url, max_chars: max_chars)
      },
      # Exactly {TrifectaLegs::ASSUMED}, and the archetype it was named for: the
      # page is authored by whoever runs the site, and the model picks the URL,
      # so the request is itself an outbound channel.
      trifecta_legs: Pikuri::Tool::TrifectaLegs::ASSUMED
    )
  end
end
