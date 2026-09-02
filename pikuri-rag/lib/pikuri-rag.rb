# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-vectordb'

# Entry file for the pikuri-rag gem: appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ and mounts a per-gem Zeitwerk loader at this +lib/+, so
# +lib/pikuri/rag/extension.rb+ autoloads as +Pikuri::Rag::Extension+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Hybrid retrieval — a keyword index beside the vectors — as one +rag_*+ tool
  # family over a local corpus. Wire it and ask both kinds of question:
  #
  #   agent = Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
  #     c.add_extension Pikuri::Rag::Extension.new(
  #       backend: Pikuri::VectorDb::Backend::InMemory.new,
  #       source:  '~/notes',
  #       private: true, trusted: true
  #     )
  #   end
  #
  # Four tools, split along the two questions a corpus gets asked. *Relevance*
  # is +rag_search+ ({Tools::Search}) — "what did we agree about the migration
  # plan?", answered as top-k chunks with the vector and keyword legs fused.
  # *Completeness* is +rag_find+ ({Tools::Find}) — "every note mentioning
  # Acme", answered as a listing with no cutoff. +rag_read+ and +rag_reindex+
  # are {Pikuri::VectorDb::Tools::Read} / {Pikuri::VectorDb::Tools::Reindex}
  # under +family: 'rag'+, so this gem adds no code for them.
  #
  # Underneath, {Backend::Fts5} is the keyword store and {Backend::Hybrid}
  # holds it beside the host's vector store; {Extension} pairs them.
  #
  # Two things a reader arriving here should know before wiring it.
  #
  # *It is exclusive with {Pikuri::VectorDb::Extension} on one agent* — each
  # refuses the other's tool names at +configure+, because the two answer the
  # same question with different promises.
  #
  # *Stemming is English-only*, being FTS5's built-in +porter+: "meetings"
  # matches "meeting", and nothing analogous happens in any other language. A
  # current limitation rather than a design position.
  #
  # The threat model is +pikuri-vectordb+'s, unchanged — same corpus, same
  # +private:+ / +trusted:+ declaration ({Pikuri::VectorDb::Extension#trusted?}
  # is still where those clauses live), no egress leg on any tool, same
  # membership gate on the reader. Which is why there is no +DESIGN.md+ here.
  # The fork that made this a gem, and the roads not taken, are +DECISIONS.md+
  # +D_rag_gem+; the walk-through is +book/rag.md+.
  module Rag
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-rag'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-rag.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
