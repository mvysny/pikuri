# frozen_string_literal: true

require_relative '../agent'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  # Factory for a +delegate+ tool: when the model calls it, the host spawns a
  # fresh {Agent} that runs its own Thought / Tool-call / Observation loop on
  # a clean {ChatLog}, then returns only the sub-agent's final assistant
  # message back as the parent's next observation.
  #
  # The sub-agent reuses the parent's transport (the same {OpenAIClient}) and
  # the parent's system prompt, so it shares the same persona and tool-use
  # conventions. Its tool list is whatever the caller passes in +tools+ —
  # typically the parent agent's tools minus this delegate tool, so the
  # sub-agent cannot delegate recursively.
  #
  # @example wiring
  #   sub_tools = [Tool::WEB_SEARCH, Tool::CALCULATOR]
  #   delegate_tool = Tool.delegate(client: client, system_prompt: prompt, tools: sub_tools)
  #   agent = Agent.new(client: client, system_prompt: prompt,
  #                     tools: sub_tools + [delegate_tool])
  #
  # @param client [OpenAIClient] transport for the sub-agent (same one the
  #   parent uses)
  # @param system_prompt [String] system prompt for the sub-agent; typically
  #   the same prompt the parent agent uses
  # @param tools [Array<Tool>] tools the sub-agent is allowed to call. Should
  #   not include the delegate tool itself (recursion guard).
  # @param max_steps [Integer] step budget for each sub-agent run, forwarded
  #   to {Agent#initialize}
  # @return [Tool] a fresh delegate tool; not a singleton, since each
  #   instance closes over a specific +client+, +system_prompt+, and +tools+
  def self.delegate(client:, system_prompt:, tools:, max_steps: 10)
    new(
      name: 'delegate',
      description: 'Delegate a self-contained task to a fresh sub-agent ' \
                   'that has the same tools as you (except `delegate` ' \
                   'itself, so it cannot recurse). The sub-agent runs its ' \
                   'own Thought / Tool-call / Observation loop from a ' \
                   'clean conversation and returns only its final ' \
                   'assistant message. Use this to isolate side-quests — ' \
                   'research, multi-step lookups, exploratory tool use — ' \
                   'so their intermediate observations do not clutter ' \
                   'your own context. The sub-agent cannot see your ' \
                   'conversation; pass everything it needs in `task`.',
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
