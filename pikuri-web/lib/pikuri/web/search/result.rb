# frozen_string_literal: true

module Pikuri
  module Web
    module Search
      # A single search hit from a {Web::Search} provider ({DuckDuckGo},
      # {Brave}, {Exa}). Providers return +Array<Result>+; {Engines#search}
      # renders them into the smolagents-style Markdown the LLM sees. Structure
      # split from rendering keeps the providers interchangeable — they need
      # only agree on these fields (provider extras like scores are discarded,
      # since no caller uses them).
      #
      #   Result.new(url: 'https://example.com', title: 'Example', body: 'A snippet.')
      #
      # @!attribute [r] url
      #   @return [String] absolute URL of the hit
      # @!attribute [r] title
      #   @return [String] plain-text title, provider highlight markup
      #     ({Brave}'s +<strong>+, {DuckDuckGo}'s +<b>+) already stripped
      # @!attribute [r] body
      #   @return [String] plain-text snippet, possibly empty (an {Exa}
      #     navigational result with no highlights)
      # @!attribute [r] text
      #   @return [String, nil] the page's text as the engine stored it, only
      #     from a provider built with +page_text: true+; +nil+ otherwise, and
      #     for a row that came back without any
      # @!attribute [r] indexed_at
      #   @return [Time, nil] when the engine last fetched the page, if it says
      #     ({Brave}'s LLM Context does; {Exa} doesn't)
      Result = Data.define(:url, :title, :body, :text, :indexed_at) do
        # @param url [String]
        # @param title [String]
        # @param body [String]
        # @param text [String, nil]
        # @param indexed_at [Time, nil]
        def initialize(url:, title:, body:, text: nil, indexed_at: nil)
          super
        end
      end
    end
  end
end
