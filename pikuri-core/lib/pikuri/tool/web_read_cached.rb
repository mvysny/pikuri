# frozen_string_literal: true

require 'time'

module Pikuri
  class Tool
    # Reading policy for the +web_read_cached+ tool: a search result's page
    # text, from the {Search::PageStore} a +page_text+ {WebSearch} filled —
    # never from the page's origin.
    #
    #   WebReadCached.read('a3f9c21e').content
    #   # => "URL: https://docs.ruby-lang.org/en/3.4/Data.html\nTitle: Data\n
    #   #     Indexed: 2026-11-10T05:22:14Z\n\nclass Data …"
    #
    # Takes a handle, never a URL: a URL would mean a fetch, and the page a
    # model picks is a channel (+D_no_result_scraper+) — let alone a URL it
    # writes. For the same reason links inside a page can't be followed. The
    # text is the engine's snapshot — Brave's in excerpts, possibly older than
    # the live page — so the read says when the engine fetched it, when known.
    module WebReadCached
      # Read the page behind +handle+, cut to +max_chars+ with {WebScrape}'s
      # marker.
      #
      # @param handle [String] as printed in the search results, e.g. +"a3f9c21e"+
      # @param max_chars [Integer] text cap, clamped to
      #   +[1, {WebScrape::MAX_MAX_CHARS}]+; default {WebScrape::DEFAULT_MAX_CHARS}
      # @param store [Search::PageStore]
      # @return [Tool::Result] the URL, title, index time and text (+"Read
      #   12.4 kB"+), or {Tool::Result.error} for an unknown or evicted handle
      def self.read(handle, max_chars: WebScrape::DEFAULT_MAX_CHARS, store: Search::PageStore.default)
        page = store.read(handle)
        if page.nil?
          return Tool::Result.error(
            "No stored page for handle #{handle.to_s.strip.inspect}. " \
            'Run web_search again and use a handle from its results.'
          )
        end

        max_chars = max_chars.clamp(1, WebScrape::MAX_MAX_CHARS)
        header = "URL: #{page.url}\nTitle: #{page.title}\n"
        header += "Indexed: #{page.indexed_at.utc.iso8601}\n" if page.indexed_at
        Tool::Result.new(content: "#{header}\n#{WebScrape.truncate(page.text, max_chars)}",
                         summary: Scraper.transfer_summary(verb: 'Read', full: page.text, max_chars: max_chars))
      end
    end

    # A web_search result's stored page text — a thin wrapper over
    # {Tool::WebReadCached.read} in OpenAI tool-call shape. Pairs with a
    # +page_text+ {WebSearch.build}; wired without one, every read answers
    # "search again".
    #
    # Sends nothing: no network request at all, so the bytes it returns came
    # in with the search, and what left the machine was that search's query —
    # see each engine's +Privacy posture+ ({Search::Brave}, {Search::Exa}).
    #
    # Sharing: +P_shared_locked+ — no state of its own; it reads the
    # process-wide {Search::PageStore}, whose +Mutex+ guards it.
    #
    # @return [Tool]
    WEB_READ_CACHED = new(
      name: 'web_read_cached',
      description: <<~DESC,
        Returns the full text of a web_search result's page.

        Usage:
        - Takes a handle from web_search's results — the hex code in brackets before a result's title, e.g. [a3f9c21e] — never a URL. A result without a handle can't be read.
        - When a handle is unknown, run web_search again and use a handle from its results.
        - The text may come in excerpts and be older than the live page; the Indexed line, when present, says when it was captured.
        - Links inside the page can't be followed: only pages web_search returned are readable.
      DESC
      parameters: Parameters.build { |p|
        p.required_string :handle,
                          'Handle of a web_search result, as printed in brackets ' \
                          'before its title, e.g. "a3f9c21e".'
        p.optional_integer :max_chars,
                           'Maximum number of characters of page text to ' \
                           'return. Defaults to 20000; hard-capped at ' \
                           '100000. When the page is longer than this, ' \
                           'output is cut and a marker reports the full ' \
                           'length.'
      },
      execute: ->(handle:, max_chars: WebScrape::DEFAULT_MAX_CHARS) {
        WebReadCached.read(handle, max_chars: max_chars)
      },
      # No request, so no egress leg; the text is whatever the page's author
      # wrote, verbatim into context, hence +:hard+.
      trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
        private: false, untrusted: :hard, egress_payload_review: :no_egress
      )
    )
  end
end
