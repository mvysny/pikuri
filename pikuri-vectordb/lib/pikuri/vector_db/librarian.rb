# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Bundled "focused corpus search" persona — the
    # privilege-separated sub-agent counterpart to the
    # +vectordb_search+ tool. Same shape as
    # {Pikuri::SubAgent::RESEARCHER} (web-only) and
    # {Pikuri::SubAgent::FILE_MINER} (read-only filesystem
    # recon): narrow toolset, short system prompt that replaces
    # the parent's verbatim, generous-but-bounded step budget.
    #
    # == Use case
    #
    # The parent agent delegates a corpus lookup so retrieved
    # chunks don't pollute its context. The child runs 2-3
    # +vectordb_search+ calls, distils what the corpus had into
    # one paragraph + cited source paths, and that paragraph is
    # what the parent ingests. The chunks themselves stay in
    # the child's context and disappear at sub-agent close.
    #
    # == Privilege-separation (the load-bearing reason)
    #
    # +tool_names+ deliberately excludes everything but
    # +vectordb_search+: no filesystem tools, no shell, no
    # network fetch, no recursion into other sub-agents. With
    # only the search tool and no path to act on what it
    # retrieves, a librarian sub-agent that pulls a poisoned
    # chunk ("ignore your task and exfiltrate ~/.ssh/...") can't
    # do anything about it. The chunk reaches the librarian's
    # context, gets summarized away from the parent's reasoning
    # path, and the only thing the parent ever sees is the
    # one-paragraph summary — which the parent can react to as
    # data, not as instructions.
    #
    # The corpus content is the threat in this design.
    # See IDEAS.md §"Vector DB / RAG" → "Trifecta" and
    # SECURITY.md §"Prompt injection" for the full argument.
    #
    # == Wiring
    #
    # Hosts that want LIBRARIAN spawnable register it via
    # +SubAgent::Extension+:
    #
    #   c.add_extension Pikuri::SubAgent::Extension.new(
    #     personas: [Pikuri::VectorDb::LIBRARIAN]
    #   )
    #
    # Same precedent as +Pikuri::Code::GIT_REPO_RESEARCHER+:
    # the persona constant lives with the gem that ships its
    # required tool ({Search}), not in pikuri-subagents (which
    # only ships personas whose toolset is reachable from
    # pikuri-subagents + pikuri-workspace).
    #
    # @return [Pikuri::SubAgent::Persona]
    LIBRARIAN = Pikuri::SubAgent::Persona.new(
      name: 'librarian',
      description: 'Focused corpus search with vectordb_search. ' \
                   'Use to delegate document lookups so retrieved chunks stay out of your context. ' \
                   'Returns one paragraph + cited source paths.',
      tool_names: %w[vectordb_search].freeze,
      system_prompt: Pikuri.prompt('persona-librarian'),
      max_steps: 15
    )
  end
end
