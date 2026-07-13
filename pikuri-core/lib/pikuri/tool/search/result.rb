# frozen_string_literal: true

module Pikuri
  class Tool
    module Search
      # A single search hit from a {Tool::Search} provider ({DuckDuckGo},
      # {Brave}, {Exa}). Providers return +Array<Result>+; {Engines.search}
      # concatenates them into the smolagents-style Markdown the LLM sees.
      # Structure split from rendering keeps the providers interchangeable —
      # they need only agree on these three fields (provider extras like scores
      # or dates are discarded, since no caller uses them).
      #
      # @!attribute [r] url
      #   @return [String] absolute URL of the hit
      # @!attribute [r] title
      #   @return [String] plain-text title, provider highlight markup
      #     ({Brave}'s +<strong>+, {DuckDuckGo}'s +<b>+) already stripped
      # @!attribute [r] body
      #   @return [String] plain-text snippet, possibly empty (an {Exa}
      #     navigational result with no highlights)
      Result = Data.define(:url, :title, :body)
    end
  end
end
