# frozen_string_literal: true

require_relative '../agent'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  # Factory for a +sub_agent+ tool: when the model calls it, the host spawns
  # a fresh {Agent} that runs its own Thought / Tool-call / Observation loop
  # on a clean {ChatLog}, then returns only the sub-agent's final assistant
  # message back as the parent's next observation.
  #
  # The sub-agent reuses the parent's transport (the same {OpenAIClient}) and
  # the parent's system prompt, so it shares the same persona and tool-use
  # conventions. Its tool list is whatever the caller passes in +tools+ —
  # typically the parent agent's tools minus this sub-agent tool, so the
  # sub-agent cannot spawn further sub-agents recursively.
  #
  # @example wiring
  #   sub_tools = [Tool::WEB_SEARCH, Tool::CALCULATOR]
  #   sub_agent_tool = Tool.sub_agent(client: client, system_prompt: prompt, tools: sub_tools)
  #   agent = Agent.new(client: client, system_prompt: prompt,
  #                     tools: sub_tools + [sub_agent_tool])
  #
  # @param client [OpenAIClient] transport for the sub-agent (same one the
  #   parent uses)
  # @param system_prompt [String] system prompt for the sub-agent; typically
  #   the same prompt the parent agent uses
  # @param tools [Array<Tool>] tools the sub-agent is allowed to call. Should
  #   not include the sub-agent tool itself (recursion guard).
  # @param max_steps [Integer] step budget for each sub-agent run, forwarded
  #   to {Agent#initialize}
  # @return [Tool] a fresh sub-agent tool; not a singleton, since each
  #   instance closes over a specific +client+, +system_prompt+, and +tools+
  def self.sub_agent(client:, system_prompt:, tools:, max_steps: 10)
    new(
      name: 'sub_agent',
      description: 'Delegate a self-contained task to a fresh sub-agent ' \
                   'that has the same tools as you (except `sub_agent` ' \
                   'itself, so it cannot recurse). The sub-agent runs its ' \
                   'own Thought / Tool-call / Observation loop from a ' \
                   'clean conversation and returns only its final ' \
                   'assistant message. Use this to isolate side-quests — ' \
                   'research, multi-step lookups, exploratory tool use — ' \
                   'so their intermediate observations do not clutter ' \
                   'your own context. The sub-agent shares your system ' \
                   'prompt — so persona, tool-use conventions, and ' \
                   'output format carry over — but cannot see your ' \
                   'conversation. Only pass task-specific context in ' \
                   '`task`; you do not need to re-explain who you are or ' \
                   'how to use tools.',
      parameters: Parameters.build { |p|
        p.required_string :task,
                          'Self-contained instructions for the sub-agent. ' \
                          'It has no access to the parent conversation, ' \
                          'so include all necessary context.'
      },
      execute: lambda { |task:|
        sub_agent = Agent.new(
          client: client,
          system_prompt: system_prompt,
          tools: tools,
          max_steps: max_steps
        )
        sub_agent.run_loop(user_message: task)
        sub_agent.log.to_a.last.content
      }
    )
  end
end
