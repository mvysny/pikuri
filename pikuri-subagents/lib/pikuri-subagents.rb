# frozen_string_literal: true

require 'pikuri-core'
require 'pikuri-workspace'

# Entry file for the pikuri-subagents gem. After
# +require 'pikuri-subagents'+, the +Pikuri::SubAgent+ namespace is
# populated with {Pikuri::SubAgent::SubAgentTool},
# {Pikuri::SubAgent::Persona}, {Pikuri::SubAgent::Extension}, and the
# bundled {Pikuri::SubAgent::RESEARCHER} + {Pikuri::SubAgent::FILE_MINER}
# constants. The gem's +prompts/+ directory is also appended to
# +Pikuri::PROMPT_DIRS+ so +Pikuri.prompt(:'persona-researcher')+
# (and +:'persona-file-miner'+) resolves regardless of which gem actually
# shipped the file.
#
# Per-gem Zeitwerk loader (not shared with pikuri-core's loader) so
# each gem owns its own +lib/+ tree and cooperation between gems is
# via the +Pikuri+ namespace alone. Zeitwerk auto-vivifies
# {Pikuri::SubAgent} from the +pikuri/sub_agent/+ directory, so
# individual files like +lib/pikuri/sub_agent/persona.rb+ autoload as
# +Pikuri::SubAgent::Persona+. See pikuri-core/lib/pikuri-core.rb for
# the core loader.
#
# == Why eager-load
#
# +Pikuri::SubAgent::RESEARCHER+ is an +ALL_CAPS+ value constant;
# Zeitwerk only auto-loads constants matching its filename-↔-CamelCase
# convention. Eager-loading at boot guarantees the file defining the
# constant runs, so the bin scripts can pass
# +Pikuri::SubAgent::RESEARCHER+ straight into the +Agent.new+ block
# without per-file +require+ ceremony.
Pikuri::PROMPT_DIRS << File.expand_path('../prompts', __dir__)

module Pikuri
  # Namespace for the sub-agent (delegation) feature. Three peer
  # classes live here:
  #
  # * {SubAgentTool} — the +Pikuri::Tool+ subclass exposed to the LLM
  #   under the name +agent+. Spawning is a single closure over a
  #   parent {Pikuri::Agent}: pick a {Persona} by +name:+, run its
  #   self-contained task on a fresh agent, return the final
  #   assistant message as the parent's next observation.
  # * {Persona} — the +(name, description, tool_names, system_prompt,
  #   max_steps)+ record bundling "what kind of agent is this." Hosts
  #   declare which personas are spawnable by handing them to
  #   {Extension}.
  # * {Extension} — the {Pikuri::Agent::Extension} that wires the two
  #   onto an agent. Pass an instance to +c.add_extension+ inside the
  #   +Agent.new+ block; the extension appends the +<available_agents>+
  #   snippet to the system prompt and installs the +SubAgentTool+ on
  #   the parent's chat in its +bind+ hook.
  #
  # The {RESEARCHER} bundled persona is also defined here.
  #
  # == Two names, one tool
  #
  # The Ruby class is +SubAgentTool+ — "sub-agent" is how the
  # delegation mechanism is referred to in pikuri's docs and code. The
  # *LLM-visible* tool name is +"agent"+: the parent reads its toolset
  # and sees an +agent+ tool, picks it, and passes +name:+ + +task:+.
  # From the agent's POV it is delegating to another agent, not to a
  # "sub-agent." Same split as Claude Code's internal +Task+ tool that
  # the model sees as +Agent+.
  module SubAgent
    LOADER = Zeitwerk::Loader.new
    LOADER.tag = 'pikuri-subagents'
    LOADER.push_dir(File.expand_path('.', __dir__))
    LOADER.ignore(File.expand_path('pikuri-subagents.rb', __dir__))
    # +RESEARCHER+ / +FILE_MINER+ are +ALL_CAPS+ value constants (each a
    # +Persona+ record), not +Researcher+ / +FileMiner+ module/class
    # files — Zeitwerk's filename↔CamelCase rule would not accept
    # them. Tell the loader to ignore each one; we require_relative
    # them after eager_load so {Persona} is already defined when the
    # constants are built. Same pattern pikuri-core uses for
    # +version.rb+.
    LOADER.ignore(File.expand_path('pikuri/sub_agent/researcher.rb', __dir__))
    LOADER.ignore(File.expand_path('pikuri/sub_agent/file_miner.rb', __dir__))
    LOADER.setup
    LOADER.eager_load
  end
end

require_relative 'pikuri/sub_agent/researcher'
require_relative 'pikuri/sub_agent/file_miner'
