# frozen_string_literal: true

require_relative '../agent'

# Loaded after {Tool} itself is defined; the +class Tool+ reopening below
# assumes that order.
class Tool
  # Factory for a +sub_agent+ tool: when the model calls it, the host spawns
  # a fresh {Agent} that runs its own conversation against +RubyLLM::Chat+
  # on a clean message history, then returns only the sub-agent's final
  # assistant message back as the parent's next observation.
  #
  # The sub-agent reuses the parent's model and system prompt, so it
  # shares the same persona and tool-use conventions. Its tool list is
  # whatever the caller passes in +tools+ — typically the parent agent's
  # tools minus this sub-agent tool, so the sub-agent cannot spawn
  # further sub-agents recursively.
  #
  # @example wiring
  #   sub_tools = [Tool::WEB_SEARCH, Tool::CALCULATOR]
  #   sub_agent_tool = Tool.sub_agent(model: 'gpt-4', system_prompt: prompt, tools: sub_tools)
  #   agent = Agent.new(model: 'gpt-4', system_prompt: prompt, tools: sub_tools + [sub_agent_tool])
  #
  # @param model [String, nil] LLM identifier for the sub-agent; +nil+
  #   defers to +RubyLLM.config.default_model+
  # @param system_prompt [String] system prompt for the sub-agent; typically
  #   the same prompt the parent agent uses
  # @param tools [Array<Class>] tools the sub-agent is allowed to call.
  #   Should not include the sub-agent tool itself (recursion guard).
  # @param max_steps [Integer] step budget for each sub-agent run, forwarded
  #   to {Agent#initialize}
  # @return [Class] a fresh sub-agent tool (a synthetic +RubyLLM::Tool+
  #   subclass); not a singleton, since each invocation closes over a
  #   specific +model+, +system_prompt+, and +tools+
  def self.sub_agent(system_prompt:, tools:, model: nil, max_steps: 10)
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
        sub = Agent.new(
          model: model,
          system_prompt: system_prompt,
          tools: tools,
          max_steps: max_steps
        )
        sub.run_loop(user_message: task)
        sub.last_assistant_content
      }
    )
  end
end
