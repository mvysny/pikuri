# frozen_string_literal: true

class Tool
  # Factory namespace for the +sub_agent+ tool. The canonical entry point
  # is {SubAgent.build}; {Tool.sub_agent} is a one-line alias kept at the
  # +Tool+ level so callers don't have to type the inner namespace.
  #
  # When the model calls a sub-agent tool, the host spawns a fresh
  # {Agent} that runs its own conversation against +RubyLLM::Chat+ on a
  # clean message history, then returns only the sub-agent's final
  # assistant message back as the parent's next observation.
  #
  # The sub-agent reuses the parent's model and system prompt, so it
  # shares the same persona and tool-use conventions. Its tool list is
  # whatever the caller passes in +tools+ — typically the parent agent's
  # tools minus this sub-agent tool, so the sub-agent cannot spawn
  # further sub-agents recursively. Its listener list comes from the
  # parent's {Agent::ListenerList} via
  # {Agent::ListenerList#for_sub_agent}, which forwards to each
  # listener's own +for_sub_agent+ hook: +Terminal+ swaps to a padded
  # fresh instance, +TokenLog+ resets its snapshot, +StepLimit+ picks
  # +max_steps:+ out of the params, and listeners without the hook
  # ({Listener::InMemoryList}, …) are shared by reference so structured
  # capture and other stateful renderers flow continuously.
  module SubAgent
    # Build a sub-agent tool that closes over a specific transport /
    # system prompt / tool list / listener list.
    #
    # @example wiring
    #   sub_tools = [Tool::WEB_SEARCH, Tool::CALCULATOR]
    #   transport = Agent::ChatTransport.new(model: 'gpt-4')
    #   sub_agent_tool = Tool::SubAgent.build(
    #     transport: transport, system_prompt: prompt, tools: sub_tools, listeners: agent.listeners
    #   )
    #   agent = Agent.new(transport: transport, system_prompt: prompt, tools: sub_tools + [sub_agent_tool])
    #
    # @param transport [Agent::ChatTransport] model-resolution bundle
    #   for the spawned sub-agent. Typically the parent's
    #   {Agent#transport} so the sub-agent's chat hits the same
    #   server with the same registry-bypass posture; passing them as
    #   a single value object is how this method avoids the recurring
    #   bug where individual kwargs got missed at the forwarding site.
    # @param system_prompt [String] system prompt for the sub-agent;
    #   typically the same prompt the parent agent uses
    # @param tools [Array<Tool>] tools the sub-agent is allowed to call.
    #   Should not include the sub-agent tool itself (recursion guard).
    # @param listeners [Agent::ListenerList] parent agent's listener
    #   list; the spawned sub-agent gets
    #   +listeners.for_sub_agent(max_steps: max_steps)+, which forwards
    #   to each listener's own sub-agent hook — same renderers and
    #   recorders shared by reference, fresh +StepLimit+ at the
    #   sub-agent's cap, fresh +TokenLog+ (so the sub-agent's
    #   context-window snapshot tracks its own +RubyLLM::Chat+ rather
    #   than the parent's), and a fresh +Terminal+ indented by
    #   {Agent::Listener::Terminal::SUB_AGENT_PADDING} so sub-agent
    #   output is visually nested under the parent's.
    # @param max_steps [Integer] step budget for each sub-agent run,
    #   forwarded as the +max_steps:+ kwarg to
    #   {Agent::ListenerList#for_sub_agent} (consumed by
    #   {Agent::Listener::StepLimit#for_sub_agent})
    # @param context_window [Integer, nil] context-window cap for the
    #   sub-agent, forwarded as the +context_window:+ override on its
    #   {Agent}. Typically the parent's {Agent#context_window_cap} so
    #   the sub-agent inherits the same cap (same model, same server)
    #   without re-probing on every invocation.
    # @return [Tool] a fresh sub-agent tool; not a singleton, since each
    #   invocation closes over a specific +transport+, +system_prompt+,
    #   +tools+, and +listeners+
    def self.build(transport:, system_prompt:, tools:, listeners:,
                   max_steps: 10, context_window: nil)
      Tool.new(
        name: 'sub_agent',
        description: <<~DESC,
          Delegate a self-contained task to a fresh sub-agent that runs its own Thought / Tool-call / Observation loop on a clean conversation, returning only its final assistant message.

          Usage:
          - Use to isolate side-quests — research, multi-step lookups, exploratory tool use — so intermediate observations do not clutter your own context.
          - The sub-agent has your tools minus `sub_agent` itself, so it cannot recurse.
          - It shares your system prompt — persona, tool-use conventions, and output format carry over. Do NOT re-explain who you are or how to use tools.
          - It cannot see your conversation. Put ALL task-specific context inside `task`; the sub-agent has zero memory of what came before.
        DESC
        parameters: Parameters.build { |p|
          p.required_string :task,
                            'Self-contained instructions for the sub-agent, ' \
                            'e.g. "Find the populations of Reykjavik and ' \
                            'Helsinki in 2024 and report both numbers." ' \
                            'It has no access to the parent conversation, ' \
                            'so include all necessary context.'
        },
        execute: lambda { |task:|
          sub = Agent.new(
            transport: transport,
            system_prompt: system_prompt,
            tools: tools,
            listeners: listeners.for_sub_agent(max_steps: max_steps),
            context_window: context_window
          )
          sub.run_loop(user_message: task)
          sub.last_assistant_content
        }
      )
    end
  end

  # Convenience alias at the +Tool+ level. See {SubAgent.build}.
  def self.sub_agent(transport:, system_prompt:, tools:, listeners:,
                     max_steps: 10, context_window: nil)
    SubAgent.build(
      transport: transport, system_prompt: system_prompt, tools: tools, listeners: listeners,
      max_steps: max_steps, context_window: context_window
    )
  end
end
