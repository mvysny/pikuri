# frozen_string_literal: true

module Pikuri
  module Web
    # Builder for the LLM-facing web-search tool, and the namespace of the
    # engines behind it. Orchestration lives in {Engines}; this owns only the
    # {.build} factory wiring a configured {Engines} into a {Tool}.
    #
    # Unlike the other web tools (shared value constants), web_search is
    # *host-configured*: the paid providers (Brave/Exa) join the cascade only
    # when the host passes their key, so it's built per-wiring, not a shared
    # constant. pikuri reads no key from the
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
    # breaker. Which is why this is the one web tool that opts into the
    # per-call {Tool::ExecuteContext} (see {Pikuri::Tool}'s +== Cancellation+):
    # an agent queued behind another agent's pacing wait can abandon it, even
    # though the tool itself may be shared.
    #
    # A build with a +confirmer:+ takes the confirmer's posture as well: a
    # {Workspace::Confirmer::Terminal} is +P_one_agent+, so share that build
    # only as far as the confirmer allows.
    module Search
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

      # Description for a +snippets_only: true+ build, which pairs with no
      # page reader at all.
      #
      # @return [String]
      SNIPPETS_ONLY_DESCRIPTION = <<~DESC
        Searches the web for a query and returns the top results as a Markdown list of titles, URLs, and short snippets.

        Usage:
        - The snippets are all you get; you can't open the result pages. Answer from the snippets, or refine the query and search again.
        - When a snippet answers the question, cite its URL.
      DESC

      # Build the +web_search+ tool. Calls {Search::Engines#search}, which
      # cascades the selected providers in random order, falling back on
      # unavailability and rendering the winner's rows to a stable Markdown
      # shape.
      #
      #   Search.build                                          # DuckDuckGo alone
      #   Search.build(brave_key: 'BSA...')                     # DuckDuckGo + Brave
      #   Search.build(engines: [:brave], brave_key: 'BSA...')  # Brave alone
      #
      # For a search-only agent, pair a +page_text+ build with
      # {Web::READ_CACHED} instead of +web_scrape+: the reader makes no
      # request, so the agent's one egress leg stays this tool's vouched one.
      #
      #   c.add_tool Search.build(engines: [:exa], exa_key: 'xyz', page_text: true)
      #   c.add_tool Web::READ_CACHED
      #
      # For an agent with no page reader whatsoever, +snippets_only: true+
      # tells the model the snippets are the whole answer, rather than sending
      # it after a +web_scrape+ it doesn't have. Its egress is then this
      # tool's query and nothing else, which is what makes the next knob
      # worth having.
      #
      # A +confirmer:+ shows the human each query before it leaves, editable,
      # and the edited text is what gets searched. The query is the tool's
      # whole payload, so a confirmer that {Workspace::Confirmer#blocks_on_human?}
      # grades the leg +:human_reviewed+ — the human sees the bytes, not a
      # proxy. It is not an injection defense: the destination is already
      # +:tool_vouched+, so an injected query lands in an engine's logs the
      # attacker can't read, and the trifecta verdict doesn't move. What it
      # buys is privacy from the engine operator, for an agent holding
      # private data that may otherwise quote it into a query unprompted.
      #
      #   c.add_tool Search.build(snippets_only: true, confirmer: Workspace::Confirmer::Terminal.new)
      #
      # @param engines [Array<String, Symbol>, nil] engine names to use —
      #   +duckduckgo+, +brave+, +exa+. +nil+ selects DuckDuckGo plus every
      #   engine whose key is supplied. Order carries no preference; see
      #   {Search::Engines.resolve}.
      # @param brave_key [String, nil] Brave key
      #   (https://api-dashboard.search.brave.com).
      # @param exa_key [String, nil] Exa key (https://exa.ai).
      # @param page_text [Boolean] bring back each result's page text from the
      #   engine's index and print a handle for {Web::READ_CACHED}; see
      #   {Search::Engines}' +== Page text+. Needs Brave or Exa among the engines.
      # @param snippets_only [Boolean] describe the snippets as the whole
      #   answer, for an agent wired with no page reader; excludes +page_text+.
      # @param confirmer [Workspace::Confirmer, nil] asks the human to approve
      #   (and possibly rewrite) each query before it is sent; +nil+ sends
      #   unasked.
      # @return [Tool] the +web_search+ tool in OpenAI tool-call shape
      # @raise [ArgumentError] on an unusable selection: an empty or repeated
      #   +engines+ list, an unknown engine name, an engine named without its
      #   key, +page_text+ without Brave or Exa, or +page_text+ together with
      #   +snippets_only+.
      def self.build(engines: nil, brave_key: nil, exa_key: nil, page_text: false,
                     snippets_only: false, confirmer: nil)
        raise ArgumentError, 'page_text and snippets_only exclude each other' if page_text && snippets_only

        cascade = Search::Engines.new(engines: engines, brave_key: brave_key, exa_key: exa_key,
                                      page_text: page_text)
        description = if page_text then PAGE_TEXT_DESCRIPTION
                      elsif snippets_only then SNIPPETS_ONLY_DESCRIPTION
                      else DESCRIPTION
                      end
        Tool.new(
          name: 'web_search',
          description: description,
          parameters: Tool::Parameters.build { |p|
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
            asked = query
            if confirmer
              case decision = confirmer.ask(request: Workspace::Confirmer::Request.new(
                question: 'Send this web search query to the search engine?',
                detail: query, editable: true
              ))
              in Workspace::Confirmer::Approved(new_request_detail:) then query = new_request_detail
              in Workspace::Confirmer::Rejected | Workspace::Confirmer::Redirected
                return decision.observation('the web search')
              end
            end
            result = cascade.search(query, max_results: max_results, cancellable: context.cancellable)
            return result if query == asked || result.content.start_with?('Error:')

            # The model would otherwise read results that don't match what it
            # asked for, and wonder why.
            result.with(content: "The user changed the query to: #{query}\n\n#{result.content}")
          },
          # Snippets are written by whoever ranks for the query, and the query
          # string itself leaves the machine — a search is an outbound channel
          # even though nothing is "sent". Unless a human-blocking confirmer
          # shows it first, nobody reviews that query, hence +:unreviewed+;
          # the whole difference from {FETCH} is the destination.
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
            egress_payload_review: confirmer&.blocks_on_human? ? :human_reviewed : :unreviewed,
            egress_destination: :tool_vouched
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
      #   c.add_tool Pikuri::Web::Search.from_h(examples_config['search'])
      #
      # @param config [Hash{String, Symbol => Object}, nil] the +search:+ block;
      #   +nil+ (an absent key) yields the DuckDuckGo-only default.
      # +page_text+ is a wiring choice, paired with the tools the host adds, so
      # it never comes from the config file — a host wanting it calls {build}:
      #
      #   Search.build(**Search::Engines.config_from_h(cfg), page_text: true)
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
