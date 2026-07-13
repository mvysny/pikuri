# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-subagents'

# Entry file for the pikuri-vectordb gem: appends the gem's +prompts/+ to
# +Pikuri::PROMPT_DIRS+ and mounts a per-gem Zeitwerk loader at this +lib/+, so
# +lib/pikuri/vector_db/extension.rb+ autoloads as
# +Pikuri::VectorDb::Extension+. The loader eager-loads so the +ALL_CAPS+ value
# constant {Pikuri::VectorDb::LIBRARIAN} (which Zeitwerk's filename↔CamelCase
# rule won't auto-load) is defined at boot — same pattern as pikuri-subagents'
# +RESEARCHER+ / +FILE_MINER+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the local-corpus vector search feature. The host wires it via
  # {Extension} (+c.add_extension+); the {Indexer} orchestrates sources → text →
  # {Chunker} → {Embedder} → +Backend#upsert+; a swappable +Backend+
  # ({Backend::InMemory} / {Backend::Qdrant} / {Backend::Chroma}) stores and
  # queries; the optional {Reranker::LlamaServer} is a quality knob. The
  # +Tools/+ directory ({Tools::Search} / {Tools::Read} / {Tools::Reindex}) *is*
  # the gem's LLM-facing surface, and {LIBRARIAN} is the bundled opt-in persona.
  #
  # Two name conventions: the Ruby namespace is +VectorDb+ (the +Mcp+/+SubAgent+
  # casing precedent), the LLM-visible tool is +vectordb_search+ (snake_case, no
  # underscore between +vector+ and +db+ — matches the other bundled tools).
  module VectorDb
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-vectordb'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-vectordb.rb', __dir__))
    # +LIBRARIAN+ is an +ALL_CAPS+ value constant Zeitwerk won't map from the
    # filename; ignore here, +require_relative+ below (see the file header).
    LOADER.ignore(File.expand_path('pikuri/vector_db/librarian.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end

require_relative 'pikuri/vector_db/librarian'
