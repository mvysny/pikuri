# frozen_string_literal: true

module Pikuri
  class Tool
    # Builder for the LLM-facing web-search tool. Orchestration lives in
    # {Tool::Search::Engines}; this owns only the {.build} factory wiring a
    # configured {Search::Engines} into a {Tool}.
    #
    # Unlike the stateless bundled tools (shared value constants), web_search is
    # *host-configured*: the paid providers (Brave/Exa) join the cascade only
    # when the host passes their key, so it's built per-wiring (like
    # {Code::Bash}), not a shared constant. pikuri reads no key from the
    # environment — the host supplies them (AGENTS.md "Environment is not a
    # secret store").
    #
    # == Sharing
    #
    # +P_shared_locked+, and the interesting case: build one per agent or share
    # one — it makes no difference to the throttling, because the pacing state
    # is neither per agent nor per instance. Each provider's limiter is a
    # class-level constant ({Search::DuckDuckGo::LIMITER} and friends), so all
    # ten agents queue behind the same one. That is the only correct scope:
    # what it protects is the egress IP and the API key's quota, and neither is
    # per agent.
    #
    # What *is* per instance is trivial — the provider list and a
    # last-logged-set memo, which can only duplicate an INFO line. The result
    # caches ({Engines::DISK_CACHE}, {Engines::MEMORY_CACHE} and their text
    # twins) are class-level as well, so one agent's search answers another's
    # within the TTL, and a +page_text+ build writes the one process-wide
    # {Search::PageStore}, so a sub-agent's handle reads in its parent.
    #
    # The consequence a host should plan for is latency, not corruption: see
    # {Search::RateLimiter} for the serialization and the shared circuit
    # breaker. Which is why this is the one bundled tool that opts into the
    # per-call {Tool::ExecuteContext} (see {Pikuri::Tool}'s +== Cancellation+):
    # an agent queued behind another agent's pacing wait can abandon it, even
    # though the tool itself may be shared.
    module WebSearch
      # Description shown to the LLM, opencode-shape (summary + +Usage:+).
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - Use this to find candidate URLs, then call web_scrape on the most promising one(s) for full content. Snippets alone rarely answer a question.
      DESC

      # Description for a +page_text: true+ build, which pairs with
      # +web_read_cached+ rather than +web_scrape+.
      #
      # @return [String]
      PAGE_TEXT_DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - A result led by a handle in brackets, e.g. [a3f9c21e], can be read in full: call web_read_cached with that handle. Snippets alone rarely answer a question.
        - A result without a handle can't be read; pick another result or refine the query.
      DESC

      # Build the +web_search+ tool. Calls {Search::Engines#search}, which
      # cascades the selected providers in random order, falling back on
      # unavailability and rendering the winner's rows to a stable Markdown
      # shape.
      #
      #   WebSearch.build                                          # DuckDuckGo alone
      #   WebSearch.build(brave_key: 'BSA...')                     # DuckDuckGo + Brave
      #   WebSearch.build(engines: [:brave], brave_key: 'BSA...')  # Brave alone
      #
      # For a search-only agent, pair a +page_text+ build with
      # {Tool::WEB_READ_CACHED} instead of +web_scrape+: the reader makes no
      # request, so the agent's one egress leg stays this tool's vouched one.
      #
      #   c.add_tool WebSearch.build(engines: [:exa], exa_key: 'xyz', page_text: true)
      #   c.add_tool Tool::WEB_READ_CACHED
      #
      # @param engines [Array<String, Symbol>, nil] engine names to use —
      #   +duckduckgo+, +brave+, +exa+. +nil+ selects DuckDuckGo plus every
      #   engine whose key is supplied. Order carries no preference; see
      #   {Search::Engines.resolve}.
      # @param brave_key [String, nil] Brave key
      #   (https://api-dashboard.search.brave.com).
      # @param exa_key [String, nil] Exa key (https://exa.ai).
      # @param page_text [Boolean] bring back each result's page text from the
      #   engine's index and print a handle for {Tool::WEB_READ_CACHED}; see
      #   {Search::Engines}' +== Page text+. Needs Brave or Exa among the engines.
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      # @raise [ArgumentError] on an unusable selection: an empty or repeated
      #   +engines+ list, an unknown engine name, an engine named without its
      #   key, or +page_text+ without Brave or Exa.
      def self.build(engines: nil, brave_key: nil, exa_key: nil, page_text: false)
        cascade = Search::Engines.new(engines: engines, brave_key: brave_key, exa_key: exa_key,
                                      page_text: page_text)
        Tool.new(
          name: 'web_search',
          description: page_text ? PAGE_TEXT_DESCRIPTION : DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :query,
                              'The search query, e.g. "BigDecimal precision Ruby".'
            p.optional_integer :max_results,
                               'Maximum number of result entries to return. ' \
                               'Defaults to 10; most providers cap this at 20.'
          },
          # +wants_context:+ opts in to the per-call {Tool::ExecuteContext}, so
          # a shared instance still honours whichever agent is waiting.
          wants_context: true,
          execute: lambda { |query:, max_results: 10, context:|
            cascade.search(query, max_results: max_results, cancellable: context.cancellable)
          },
          # Snippets are written by whoever ranks for the query, and the query
          # string itself leaves the machine — a search is an outbound channel
          # even though nothing is "sent". Nobody reviews that query, hence
          # +:unreviewed+; the whole difference from {FETCH} is the destination.
          #
          # +:tool_vouched+ against the three clauses: the caller supplies a
          # query, never a host, and the engine set is this file's own
          # ({Search::Engines::ENGINE_NAMES}); a search engine does not
          # republish the queries it receives; and the request rides TLS to a
          # party with no relationship to the attacker. A host picks from that
          # closed list of three and cannot extend it, so the destination is
          # still *this code* choosing, not the model.
          #
          # It is not a claim that the leg is harmless. A secret can still be
          # pushed out inside a query — it just cannot be read back, and only
          # while this stays the agent's sole egress leg.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(
            private: false, untrusted: :hard,
            egress_payload_review: :unreviewed, egress_destination: :tool_vouched
          )
        )
      end

      # Build the +web_search+ tool from a config file's +search:+ block, the
      # host-facing shortcut for {build}:
      #
      #   # ~/.pikuri-examples-config.yaml
      #   search:
      #     brave_key: BSA...
      #     engines: [brave]
      #
      #   c.add_tool Pikuri::Tool::WebSearch.from_h(examples_config['search'])
      #
      # @param config [Hash{String, Symbol => Object}, nil] the +search:+ block;
      #   +nil+ (an absent key) yields the DuckDuckGo-only default.
      # +page_text+ is a wiring choice, paired with the tools the host adds, so
      # it never comes from the config file — a host wanting it calls {build}:
      #
      #   WebSearch.build(**Search::Engines.config_from_h(cfg), page_text: true)
      #
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      # @raise [ArgumentError] as {build}, plus on a malformed block; see
      #   {Search::Engines.config_from_h}.
      def self.from_h(config)
        build(**Search::Engines.config_from_h(config))
      end
    end
  end
end
