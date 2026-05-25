# frozen_string_literal: true

module Pikuri
  module SubAgent
    # Bundled "focused web research" persona. The first persona
    # pikuri ships — narrow toolset (network reads only, no fs,
    # no shell, no sub-agent recursion), short system prompt that
    # replaces the parent's verbatim, and a small step budget
    # suited to "look it up + summarize."
    #
    # == Use case
    #
    # The parent agent delegates a focused web lookup so the
    # intermediate scraped pages don't pollute its context. The
    # child returns a one-paragraph answer with source URLs; the
    # parent pastes that into a longer chain of reasoning.
    #
    # == Privacy-separation
    #
    # The persona's +tool_names+ list intentionally excludes the
    # filesystem tools, shell, and the +agent+ tool itself. With
    # only network-read tools and no recursion path, a researcher
    # spawned from inside a coding agent cannot read the user's
    # repo, cannot run code, and cannot delegate further. This
    # is the persona model's privilege-separation story — see
    # +CLAUDE.md+ §Scope decisions.
    #
    # @return [Persona]
    RESEARCHER = Persona.new(
      name: 'researcher',
      description: 'Focused web research with web_search, web_scrape, fetch. ' \
                   'Use to delegate multi-page lookups so their contents stay out of your context. ' \
                   'Returns one paragraph + sources.',
      tool_names: %w[web_search web_scrape fetch].freeze,
      system_prompt: Pikuri.prompt('persona-researcher'),
      max_steps: 10
    )
  end
end
