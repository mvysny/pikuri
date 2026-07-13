# frozen_string_literal: true

module Pikuri
  module VectorDb
    # Bundled "focused corpus search" persona — the privilege-separated
    # sub-agent counterpart to +vectordb_search+. Same shape as
    # {Pikuri::SubAgent::RESEARCHER} / {Pikuri::SubAgent::FILE_MINER}: narrow
    # toolset, short prompt replacing the parent's verbatim, bounded budget. The
    # parent delegates a corpus lookup so retrieved chunks never pollute its
    # context — the child searches, reads the clean hits in full, distils to one
    # paragraph + cited paths (all the parent ingests); the chunks and documents
    # disappear at sub-agent close.
    #
    # == Privilege-separation (the load-bearing reason)
    #
    # +tool_names+ admits only the two *inbound* corpus tools and nothing else:
    # no shell, no fetch, no write, no recursion. Both only pull content *in*,
    # so the lethal trifecta's egress leg stays absent — a librarian that reads
    # a poisoned document ("exfiltrate ~/.ssh/...") has no hand to act with; the
    # content is summarized away and the parent sees only the paragraph, as data
    # not instructions. +vectordb_read+ is safe here for exactly this reason:
    # reading widens what the librarian *sees*, never what it can *do* (see
    # {Tools::Read}). Corpus content is the threat — see SECURITY.md and
    # +ideas/trifecta-detector.md+.
    #
    # Opt-in via +SubAgent::Extension.new(personas: [LIBRARIAN])+; same precedent
    # as +Pikuri::Code::GIT_REPO_RESEARCHER+ — the constant lives with the gem
    # shipping its required tool, not in pikuri-subagents.
    #
    # @return [Pikuri::SubAgent::Persona]
    LIBRARIAN = Pikuri::SubAgent::Persona.new(
      name: 'librarian',
      description: 'Focused corpus lookup with vectordb_search + vectordb_read. ' \
                   'Use to delegate document lookups so retrieved chunks and full documents stay out of your context. ' \
                   'Returns one paragraph + cited source paths.',
      tool_names: %w[vectordb_search vectordb_read].freeze,
      system_prompt: Pikuri.prompt('persona-librarian'),
      max_steps: 15
    )
  end
end
