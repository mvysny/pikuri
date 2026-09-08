# frozen_string_literal: true

module Pikuri
  module SubAgent
    # Bundled "focused web research" persona: a narrow network-read
    # toolset (no fs, shell, or recursion) and a step budget sized as a
    # runaway cap, not a tight target — web scrapes hit 404/403/CAPTCHA
    # often enough that a tight cap would burn through on noise. The parent
    # delegates a focused lookup so the intermediate scraped pages don't
    # pollute its context; the child returns one paragraph with source URLs.
    #
    # == Privilege-separation
    #
    # +tool_names+ excludes the filesystem tools, shell, and +agent+
    # itself, so a researcher spawned from inside a coding agent cannot
    # read the user's repo, run code, or delegate further — the persona
    # model's privilege-separation story (this gem's +CLAUDE.md+, *Sub-agent
    # propagation*).
    #
    # @return [Persona]
    RESEARCHER = Persona.new(
      name: 'researcher',
      description: 'Focused web research with web_search, web_scrape, fetch. ' \
                   'Use to delegate multi-page lookups (stack traces, library docs, ' \
                   'API references) so their contents stay out of your context. ' \
                   'Returns one paragraph + sources.',
      tool_names: %w[web_search web_scrape fetch].freeze,
      system_prompt: Pikuri.prompt('persona-researcher')
    )
  end
end
