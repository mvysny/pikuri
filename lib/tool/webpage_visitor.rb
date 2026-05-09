# frozen_string_literal: true

require 'tool/scraper/simple'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order, and exposing it as +Tool::VISIT_WEBPAGE+ requires
# +Tool+ already be a class.
class Tool
  # Truncation policy and Tool spec for the +visit_webpage+ tool. The
  # actual scraping lives in {Tool::Scraper::Simple}; this module is a
  # thin wrapper that picks the scraper, applies a character cap so the
  # LLM doesn't drown in long-form content, and exposes the result to
  # the agent loop in OpenAI tool-call shape.
  module WebpageVisitor
    # @return [Integer] default character cap on the Markdown returned
    #   by {.visit}. Long-form articles routinely run 50K+ chars after
    #   readability extraction; 5K is enough to give the LLM the gist
    #   of most pages without flooding the context window.
    DEFAULT_MAX_CHARS = 5_000

    # @return [Integer] hard ceiling on the +max_chars+ argument to
    #   {.visit}. Requests above this are clamped silently so the LLM
    #   cannot dump an arbitrarily large page into the conversation.
    MAX_MAX_CHARS = 100_000

    # Fetch +url+ via {Tool::Scraper::Simple} and truncate the rendered
    # Markdown to +max_chars+ characters.
    #
    # The scraper caches the full extracted Markdown on disk, so
    # different +max_chars+ values for the same URL share one cache
    # entry — truncation runs after the cache lookup.
    #
    # @param url [String] absolute HTTP(S) URL of the page to download
    # @param max_chars [Integer] character cap on the returned Markdown.
    #   Clamped to +[1, {MAX_MAX_CHARS}]+; defaults to
    #   {DEFAULT_MAX_CHARS}. When the full page exceeds the cap, output
    #   is cut and a marker noting the original length is appended.
    # @return [String] Markdown representation of the page, possibly
    #   truncated
    # @raise [ArgumentError] if too many redirects are encountered
    # @raise [RuntimeError] if the HTTP response is non-success or a
    #   redirect arrives without a +Location+ header
    def self.visit(url, max_chars: DEFAULT_MAX_CHARS)
      max_chars = max_chars.clamp(1, MAX_MAX_CHARS)
      truncate(Scraper::Simple.visit(url), max_chars)
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
  # {Tool::WebpageVisitor.visit} that exposes it to the agent loop in
  # OpenAI tool-call shape. Pairs naturally with {Tool::WEB_SEARCH}: the
  # search tool surfaces candidate URLs, this one reads them.
  #
  # @return [Tool]
  VISIT_WEBPAGE = new(
    name: 'visit_webpage',
    description: 'Reads the webpage at the given URL and returns its main ' \
                 'content as Markdown. Use this whenever you need the ' \
                 'actual contents of a page — after `web_search` surfaces ' \
                 'a promising URL, when the user supplies a link, or when ' \
                 'a search snippet is too short to answer the question. ' \
                 'Internally tries JSON-LD structured data first (works ' \
                 'well for product, article, and recipe pages) and falls ' \
                 'back to a readability extraction of the main article ' \
                 'body. Output is truncated to roughly 5000 characters by ' \
                 'default — enough for the gist of most pages; pass ' \
                 '`max_chars` to read more when the truncation marker ' \
                 'shows the page was longer and you need the rest.',
    parameters: Parameters.build { |p|
      p.required_string :url,
                        'Absolute URL of the webpage to visit, including ' \
                        'the scheme, e.g. "https://example.com/article".'
      p.optional_integer :max_chars,
                         'Maximum number of characters of Markdown to ' \
                         'return. Defaults to 5000; hard-capped at ' \
                         '100000. When the page is longer than this, ' \
                         'output is cut and a marker reports the full ' \
                         'length so you can retry with a larger value.'
    },
    execute: ->(url:, max_chars: WebpageVisitor::DEFAULT_MAX_CHARS) {
      WebpageVisitor.visit(url, max_chars: max_chars)
    }
  )
end
