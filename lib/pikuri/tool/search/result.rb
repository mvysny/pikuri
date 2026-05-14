# frozen_string_literal: true

module Pikuri
  class Tool
    module Search
      # A single search hit produced by a {Tool::Search} provider
      # ({DuckDuckGo}, {Brave}, {Exa}). Providers return +Array<Result>+
      # from +.parse+ / +.search+; {Engines.search} concatenates the
      # rows into the smolagents-style Markdown the LLM sees.
      #
      # Splitting structure from rendering keeps the three providers
      # interchangeable — they only have to agree on these three fields
      # (provider-specific extras like relevance scores or published
      # dates are discarded today, which is fine because no caller uses
      # them).
      #
      # @!attribute [r] url
      #   @return [String] absolute URL of the hit
      # @!attribute [r] title
      #   @return [String] plain-text title, with provider-specific
      #     highlight markup ({Brave}'s +<strong>+, {DuckDuckGo}'s
      #     +<b>+) already stripped
      # @!attribute [r] body
      #   @return [String] plain-text snippet, possibly empty (e.g. an
      #     {Exa} navigational result with no highlights)
      Result = Data.define(:url, :title, :body)
    end
  end
end
