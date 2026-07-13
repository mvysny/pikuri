# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-subagents gem. Appends the gem's +prompts/+
# to +Pikuri::PROMPT_DIRS+ (so +Pikuri.prompt(:'persona-researcher')+ /
# +:'persona-file-miner'+ resolve) and sets up the per-gem Zeitwerk loader.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the sub-agent (delegation) feature. Three peer classes:
  # {SubAgentTool} (the +Pikuri::Tool+ the LLM sees as +agent+),
  # {Persona} (the record bundling "what kind of agent is this"), and
  # {Extension} (wires the two onto a parent agent). Bundled personas
  # {RESEARCHER} + {FILE_MINER} live here too.
  #
  # == Two names, one tool
  #
  # The Ruby class is +SubAgentTool+ — "sub-agent" is how the delegation
  # mechanism is referred to in pikuri's docs and code — but the
  # LLM-visible tool name is +"agent"+: from the parent's POV it delegates
  # to another agent, not a "sub-agent." Same split as Claude Code's
  # internal +Task+ tool the model sees as +Agent+.
  module SubAgent
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-subagents'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-subagents.rb', __dir__))
    # +RESEARCHER+ / +FILE_MINER+ are +ALL_CAPS+ value constants Zeitwerk's
    # filename↔CamelCase rule won't accept, so ignore them here and
    # require_relative below (after eager_load, so {Persona} is defined).
    LOADER.ignore(File.expand_path('pikuri/sub_agent/researcher.rb', __dir__))
    LOADER.ignore(File.expand_path('pikuri/sub_agent/file_miner.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end

require_relative 'pikuri/sub_agent/researcher'
require_relative 'pikuri/sub_agent/file_miner'
