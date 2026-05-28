# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-subagents'

# Entry file for the pikuri-vectordb gem. After
# +require 'pikuri-vectordb'+, the +Pikuri::VectorDb+ namespace is
# populated with the {Pikuri::VectorDb::Extension} host-facing API,
# the {Pikuri::VectorDb::Indexer}, the two +Backend+ classes
# (+InMemory+ + +Chroma+), {Pikuri::VectorDb::Embedder},
# {Pikuri::VectorDb::Reranker::LlamaServer}, the chunker, the
# tokenizer, the +vectordb_search+ tool, and the bundled
# +Pikuri::VectorDb::LIBRARIAN+ persona. The gem's +prompts/+
# directory is also appended to +Pikuri::PROMPT_DIRS+ so
# +Pikuri.prompt(:'persona-librarian')+ resolves regardless of
# which gem actually shipped the file.
#
# Per-gem Zeitwerk loader (not shared with pikuri-core's loader) so
# each gem owns its own +lib/+ tree and cooperation between gems is
# via the +Pikuri+ namespace alone. Zeitwerk auto-vivifies
# {Pikuri::VectorDb} from the +pikuri/vector_db/+ directory, so
# individual files like +lib/pikuri/vector_db/extension.rb+
# autoload as +Pikuri::VectorDb::Extension+. See
# pikuri-core/lib/pikuri-core.rb for the core loader.
#
# == Why eager-load
#
# +Pikuri::VectorDb::LIBRARIAN+ is an +ALL_CAPS+ value constant;
# Zeitwerk only auto-loads constants matching its
# filename-↔-CamelCase convention. Eager-loading at boot
# guarantees the file defining the constant runs, so host scripts
# can pass +Pikuri::VectorDb::LIBRARIAN+ straight into the
# +Agent.new+ block without per-file +require+ ceremony. Same
# pattern pikuri-subagents uses for +RESEARCHER+ / +FILE_MINER+
# and pikuri-core uses for +VERSION+.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the local-corpus vector search feature. Houses:
  #
  # * {Extension} — the {Pikuri::Agent::Extension} that wires the
  #   search tool, indexer, and corpus pipeline onto an agent.
  #   Pass an instance to +c.add_extension+ inside the
  #   +Agent.new+ block.
  # * {Indexer} — composes sources → text extractor → chunker →
  #   embedder → backend.upsert. The one class that orchestrates
  #   the indexing pipeline.
  # * +Backend::InMemory+ / +Backend::Chroma+ — two swappable
  #   stores behind the same duck-typed interface (+#upsert+,
  #   +#query+, +#delete_all+, +#count+). InMemory is the
  #   educational default (pure-Ruby cosine over +Array<Float>+);
  #   Chroma is a thin Faraday HTTP client for persistence.
  # * {Embedder} — thin wrapper over +RubyLLM.embed+ so tests can
  #   inject a fake without monkey-patching ruby_llm.
  # * +Reranker::LlamaServer+ — optional quality knob; speaks
  #   +/v1/rerank+ against a cross-encoder model on a llama.cpp
  #   server. +Extension+ with +reranker: nil+ skips rerank.
  # * +Chunker::FixedWindow+ + +Tokenizer::*+ — the chunking
  #   pipeline. Tokenizer is owned by the Chunker (not the
  #   Extension) because tokenization is a chunking detail.
  # * +Search+ — the +vectordb_search+ {Pikuri::Tool} subclass.
  # * {LIBRARIAN} — the bundled {Pikuri::SubAgent::Persona}
  #   constant. Hosts wire it via
  #   +SubAgent::Extension.new(personas: [..., LIBRARIAN])+ —
  #   same shape +pikuri-code+ uses for +GIT_REPO_RESEARCHER+.
  #
  # == Two name conventions
  #
  # The Ruby namespace is +VectorDb+ (matches +Mcp+ / +SubAgent+
  # casing precedent — pikuri prefers +Mcp+ over +MCP+ for
  # acronym-bearing compounds). The LLM-visible tool name is
  # +vectordb_search+ (snake_case, no underscore between
  # +vector+ and +db+) — short, scannable, matches the
  # one-word-per-segment pattern of the other bundled tools.
  module VectorDb
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-vectordb'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-vectordb.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
