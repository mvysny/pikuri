# frozen_string_literal: true

module Pikuri
  class Tool
    # Builder for the LLM-facing web-search tool. The search orchestration
    # lives in {Tool::Search::Engines}; this module owns only the {.build}
    # factory that wires a configured {Search::Engines} into a {Tool}.
    #
    # Unlike the stateless bundled tools (+CALCULATOR+ / +WEB_SCRAPE+ /
    # +FETCH+, shared value constants), web_search is *host-configured*:
    # the paid providers (Brave / Exa) join the cascade only when the host
    # passes their API key, so the tool is built per-wiring — like
    # {Code::Bash} — rather than handed out as a single shared constant.
    # pikuri reads no key from the environment; the host supplies them (the
    # bundled +bin/+ examples load a JSON config file by convention). See
    # CLAUDE.md "Environment is not a secret store".
    module WebSearch
      # Description shown to the LLM, opencode-shape (summary + +Usage:+).
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - Use this to find candidate URLs, then call web_scrape on the most promising one(s) for full content. Snippets alone rarely answer a question.
      DESC

      # Build the +web_search+ tool. It calls {Search::Engines#search},
      # which cascades through DuckDuckGo (always) plus whichever keyed
      # providers were configured, in random order, falling back on
      # temporary-unavailability errors and rendering the winning
      # provider's rows into a stable Markdown shape.
      #
      # @param brave_key [String, nil] Brave Search API key; when present
      #   (non-blank) Brave joins the cascade. Get one at
      #   https://api-dashboard.search.brave.com.
      # @param exa_key [String, nil] Exa API key; when present (non-blank)
      #   Exa joins the cascade. Get one at https://exa.ai.
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      def self.build(brave_key: nil, exa_key: nil)
        engines = Search::Engines.new(brave_key: brave_key, exa_key: exa_key)
        Tool.new(
          name: 'web_search',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'The search query, e.g. "BigDecimal precision Ruby".'
            p.optional_integer :max_results,
                               'Maximum number of result entries to return. ' \
                               'Defaults to 10; most providers cap this at 20.'
          },
          execute: ->(query:, max_results: 10) { engines.search(query, max_results: max_results) }
        )
      end
    end
  end
end
