# frozen_string_literal: true

require 'tool/scraper/simple'
require 'url_cache'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order, and exposing it as +Tool::WEB_FETCH+ requires
# +Tool+ already be a class.
class Tool
  # Truncation policy and Tool spec for the +web_fetch+ tool. The actual
  # scraping lives in {Tool::Scraper::Simple}; this module is a thin
  # wrapper that picks the scraper, applies a character cap so the LLM
  # doesn't drown in long-form content, and exposes the result to the
  # agent loop in OpenAI tool-call shape.
  module WebFetch
    # @return [Integer] default character cap on the Markdown returned
    #   by {.visit}. Long-form articles routinely run 50K+ chars after
    #   readability extraction; 5K is enough to give the LLM the gist
    #   of most pages without flooding the context window.
    DEFAULT_MAX_CHARS = 5_000

    # @return [Integer] hard ceiling on the +max_chars+ argument to
    #   {.visit}. Requests above this are clamped silently so the LLM
    #   cannot dump an arbitrarily large page into the conversation.
    MAX_MAX_CHARS = 100_000

    # On-disk cache used by {.visit} to memoize fetched pages. Defined
    # as a method so specs can swap it for an isolated cache or
    # {UrlCache::NULL} without touching the shared instance.
    #
    # @return [UrlCache, #fetch]
    CACHE = UrlCache.new(ttl: UrlCache::DEFAULT_TTL, dir: "#{UrlCache::ROOT_DIR}/web_fetch")
    def self.cache
      CACHE
    end

    # Fetch +url+ via {Tool::Scraper::Simple} and truncate the rendered
    # Markdown to +max_chars+ characters.
    #
    # The full extracted Markdown is cached on disk via {.cache}, keyed
    # by URL, so repeat visits within the cache TTL skip the network
    # and the extraction pass entirely. +max_chars+ is not part of the
    # cache key — different values for the same URL share one entry,
    # and truncation runs after the cache lookup.
    #
    # {Tool::Scraper::FetchError} (HTTP non-2xx, network failure,
    # redirect-loop, missing +Location+ header) is caught and returned
    # as +"Error: ..."+ in the calculator-style convention so the agent
    # loop feeds the failure back to the model as the next observation
    # instead of crashing — the LLM can then try a different URL or
    # search again. The rescue lives outside {.cache}'s +fetch+ block,
    # so failure strings are never persisted: a retry on the next call
    # hits the network again. Other exceptions (parser bugs in our own
    # code) bubble up unchanged.
    #
    # @param url [String] absolute HTTP(S) URL of the page to download
    # @param max_chars [Integer] character cap on the returned Markdown.
    #   Clamped to +[1, {MAX_MAX_CHARS}]+; defaults to
    #   {DEFAULT_MAX_CHARS}. When the full page exceeds the cap, output
    #   is cut and a marker noting the original length is appended.
    # @return [String] Markdown representation of the page, possibly
    #   truncated, or +"Error: ..."+ on a recoverable fetch failure
    def self.visit(url, max_chars: DEFAULT_MAX_CHARS)
      max_chars = max_chars.clamp(1, MAX_MAX_CHARS)
      markdown = cache.fetch(url) { Scraper::Simple.visit(url) }
      truncate(markdown, max_chars)
    rescue Scraper::FetchError => e
      "Error: #{e.message}"
    end

    # Cut +markdown+ to at most +max_chars+ characters, appending a
    # marker describing the original length when truncation actually
    # happens. Returns +markdown+ unchanged if it already fits.
    #
    # @param markdown [String] full Markdown text
    # @param max_chars [Integer] character cap; assumed already clamped
    # @return [String]
    def self.truncate(markdown, max_chars)
      return markdown if markdown.length <= max_chars

      "#{markdown[0, max_chars]}\n\n" \
        "... [truncated at #{max_chars} of #{markdown.length} chars; " \
        'call again with a larger `max_chars` to see more]'
    end
  end

  # Webpage download + Markdown conversion tool. Thin wrapper over
  # {Tool::WebFetch.visit} that exposes it to the agent loop in OpenAI
  # tool-call shape.
  #
  # @return [Tool]
  WEB_FETCH = new(
    name: 'web_fetch',
    description: 'Fetches the webpage at the given URL and returns its ' \
                 'main content as Markdown — not the raw HTML; the page ' \
                 'is parsed and rendered. Internally tries JSON-LD ' \
                 'structured data first (works well for product, article, ' \
                 'and recipe pages) and falls back to a readability ' \
                 'extraction of the main article body. Output is ' \
                 'truncated to roughly 5000 characters by default — ' \
                 'enough for the gist of most pages; pass `max_chars` to ' \
                 'read more when the truncation marker shows the page was ' \
                 'longer and you need the rest.',
    parameters: Parameters.build { |p|
      p.required_string :url,
                        'Absolute URL of the webpage to fetch, including ' \
                        'the scheme, e.g. "https://example.com/article".'
      p.optional_integer :max_chars,
                         'Maximum number of characters of Markdown to ' \
                         'return. Defaults to 5000; hard-capped at ' \
                         '100000. When the page is longer than this, ' \
                         'output is cut and a marker reports the full ' \
                         'length so you can retry with a larger value.'
    },
    execute: ->(url:, max_chars: WebFetch::DEFAULT_MAX_CHARS) {
      WebFetch.visit(url, max_chars: max_chars)
    }
  )
end
