# frozen_string_literal: true

require 'pikuri-core'

# Entry file for the pikuri-memory gem. After
# +require 'pikuri-memory'+, the +Pikuri::Memory+ namespace is
# populated with the {Pikuri::Memory::Extension} host-facing API,
# the thin {Pikuri::Memory::Mem0Client} (Faraday client against a mem0
# server), the {Pikuri::Memory::Recorder} (async extraction queue),
# the {Pikuri::Memory::Record} value type, and the +recall+ tool
# ({Pikuri::Memory::Recall}). The gem's +prompts/+ directory is
# appended to +Pikuri::PROMPT_DIRS+ so
# +Pikuri.prompt(:'memory-extraction')+ resolves regardless of
# which gem shipped the file.
#
# Per-gem Zeitwerk loader (not shared with pikuri-core's loader) so
# each gem owns its own +lib/+ tree and cooperation between gems is
# via the +Pikuri+ namespace alone. Zeitwerk auto-vivifies
# {Pikuri::Memory} from the +pikuri/memory/+ directory, so files
# like +lib/pikuri/memory/extension.rb+ autoload as
# +Pikuri::Memory::Extension+. See pikuri-core/lib/pikuri-core.rb
# for the core loader and pikuri-vectordb for the same per-gem shape.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the durable cross-conversation memory feature.
  # Houses:
  #
  # * {Extension} — the {Pikuri::Agent::Extension} that wires the
  #   +recall+ tool, the automatic per-turn prefetch, and the
  #   asynchronous capture queue onto an agent. Pass an instance to
  #   +c.add_extension+ inside the +Agent.new+ block.
  # * {Mem0Client} — a thin Faraday HTTP client against a mem0 server
  #   (+POST /memories+, +POST /search+, +GET/DELETE /memories+,
  #   +POST /reset+). The append-only +add+ / read-time +search+
  #   surface; mem0 owns extraction, embedding, and resolution.
  # * {Recorder} — an off-the-interaction-path extraction queue: a
  #   background worker drains enqueued user turns into
  #   {Mem0Client#add}, so a turn never blocks on the ~3s extraction
  #   call. Flushed (bounded) on agent close.
  # * {Record} — the value type a {Mem0Client} row deserializes to
  #   (+id+ / +text+ / +score+ / +created_at+ / +metadata+ /
  #   +event+).
  # * {Recall} — the +recall+ {Pikuri::Tool} subclass for explicit,
  #   topic-driven deepening beyond the automatic prefetch slice.
  #
  # == Three retrieval tiers (the layered shape)
  #
  # 1. **Resident persona** — a small always-in-prompt summary of
  #    high-frequency facts, appended once via
  #    {Configurator#append_system_prompt} at construction.
  # 2. **Automatic prefetch** — {Extension#on_user_message} embeds
  #    the latest user message, searches mem0, and injects a small
  #    high-precision slice as a +:system+ +<memory-context>+ block.
  # 3. **Explicit deepening** — the +recall+ tool, called by the
  #    model when the prefetch slice hints there is more.
  #
  # The same resident-vs-triggered split as +pikuri-vectordb+'s
  # +vectordb_search+ / +vectordb_read+ — one mental model across
  # memory and RAG. See ideas/memory.md.
  #
  # == Safety posture (v1)
  #
  # Automatic capture + automatic recall are safe only on an agent
  # with no untrusted ingest and no egress (the +@private+
  # configuration in ideas/assistant.md): a poisoned memory + an
  # egress leg is the lethal trifecta. Capture feeds *user-role
  # content only*, and recall lands as +:system+ context (never a
  # user turn), so the recall→re-extraction feedback loop cannot
  # form. Porting this onto an egress-capable agent re-opens
  # recall-poisoning and must not be done blindly.
  module Memory
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-memory'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-memory.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end
