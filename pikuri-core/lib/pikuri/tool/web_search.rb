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
    # environment — the host supplies them (CLAUDE.md "Environment is not a
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
    # cache ({Engines::CACHE}) is class-level as well, so one agent's search
    # answers another's within the TTL.
    #
    # The consequence a host should plan for is latency, not corruption: see
    # {Search::RateLimiter} for the serialization and the shared circuit
    # breaker.
    module WebSearch
      # Description shown to the LLM, opencode-shape (summary + +Usage:+).
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - Use this to find candidate URLs, then call web_scrape on the most promising one(s) for full content. Snippets alone rarely answer a question.
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
      # @param engines [Array<String, Symbol>, nil] engine names to use —
      #   +duckduckgo+, +brave+, +exa+. +nil+ selects DuckDuckGo plus every
      #   engine whose key is supplied. Order carries no preference; see
      #   {Search::Engines.resolve}.
      # @param brave_key [String, nil] Brave key
      #   (https://api-dashboard.search.brave.com).
      # @param exa_key [String, nil] Exa key (https://exa.ai).
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      # @raise [ArgumentError] on an unusable selection: an empty or repeated
      #   +engines+ list, an unknown engine name, or an engine named without
      #   its key.
      def self.build(engines: nil, brave_key: nil, exa_key: nil)
        # Validated here as well as inside the cascade, so a mis-wired host is
        # refused at the call it actually wrote even if this stops constructing
        # the cascade eagerly.
        Search::Engines.resolve(engines: engines, brave_key: brave_key, exa_key: exa_key)
        cascade = Search::Engines.new(engines: engines, brave_key: brave_key, exa_key: exa_key)
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
          execute: ->(query:, max_results: 10) { cascade.search(query, max_results: max_results) },
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
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      # @raise [ArgumentError] as {build}, plus on a malformed block; see
      #   {Search::Engines.config_from_h}.
      def self.from_h(config)
        build(**Search::Engines.config_from_h(config))
      end
    end
  end
end
