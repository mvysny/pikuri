# frozen_string_literal: true

module Pikuri
  class Tool
    # The +sub_agent+ tool, expressed as a {Tool} subclass: instantiating
    # +Tool::SubAgent.new(parent_agent)+ produces a tool whose
    # {Tool#to_ruby_llm_tool} wiring is identical to any bundled tool's,
    # so ruby_llm sees nothing special about it. When the model calls it,
    # the closure inside +execute+ spawns a fresh {Agent} that runs its
    # own Thought / Tool-call / Observation loop on a clean message
    # history, then returns only the sub-agent's final assistant message
    # back as the parent's next observation.
    #
    # The sub-agent reuses the parent's +transport+, +system_prompt+,
    # +context_window_cap+, and +name+ (as its hierarchical prefix), so
    # it shares the same persona, hits the same server, and inherits the
    # same context-window cap without re-probing. Its tool list is a
    # snapshot of the parent's {Agent#tools} taken at construction —
    # {Agent#allow_sub_agent} only appends the sub-agent tool to its own
    # +@tools+ *after* this snapshot, so the sub-agent's tool list never
    # contains itself (recursion guard).
    #
    # Its listener list comes from the parent's {Agent#listeners} via
    # {Agent::ListenerList#for_sub_agent}, which forwards to each
    # listener's own +for_sub_agent+ hook: +Terminal+ swaps to a padded
    # fresh instance, +TokenLog+ resets its snapshot, +StepLimit+ picks
    # +max_steps:+ out of the params, and listeners without the hook
    # ({Agent::Listener::InMemoryList}, …) are shared by reference so
    # structured capture and other stateful renderers flow continuously.
    #
    # All parent state is captured by value at construction — the closure
    # does not chase +parent_agent+ mutations later. The one piece of
    # mutable state is a monotonic counter used to generate sub-agent ids:
    # +"sub_agent 0"+, +"sub_agent 1"+, ... at the top level; nested
    # children of +"sub_agent 0"+ are +"sub_agent 0_0"+, +"sub_agent 0_1"+,
    # ... — the +"sub_agent "+ prefix appears once at the top and the
    # underscore-separated counter chain records depth.
    class SubAgent < Tool
      # Description shown to the LLM. Follows the opencode-shape (summary
      # + +Usage:+ bullets) prescribed by the project's tool-description
      # convention.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Delegate a self-contained task to a fresh sub-agent that runs its own Thought / Tool-call / Observation loop on a clean conversation, returning only its final assistant message.

        Usage:
        - Use to isolate side-quests — research, multi-step lookups, exploratory tool use — so intermediate observations do not clutter your own context.
        - The sub-agent has your tools minus `sub_agent` itself, so it cannot recurse.
        - It shares your system prompt — persona, tool-use conventions, and output format carry over. Do NOT re-explain who you are or how to use tools.
        - It cannot see your conversation. Put ALL task-specific context inside `task`; the sub-agent has zero memory of what came before.
      DESC

      # @param parent_agent [Agent] the calling agent. Read for its
      #   {Agent#transport}, {Agent#system_prompt}, {Agent#tools},
      #   {Agent#listeners}, {Agent#context_window_cap}, and {Agent#name}.
      # @param max_steps [Integer] step budget for each sub-agent run,
      #   forwarded as the +max_steps:+ kwarg to
      #   {Agent::ListenerList#for_sub_agent} (consumed by
      #   {Agent::Listener::StepLimit#for_sub_agent}).
      # @return [SubAgent]
      def initialize(parent_agent, max_steps: 10)
        transport      = parent_agent.transport
        system_prompt  = parent_agent.system_prompt
        sub_tools      = parent_agent.tools.dup
        listeners      = parent_agent.listeners
        context_window = parent_agent.context_window_cap
        parent_name    = parent_agent.name
        sub_counter    = 0

        super(
          name: 'sub_agent',
          description: DESCRIPTION,
          parameters: Parameters.build { |p|
            p.required_string :task,
                              'Self-contained instructions for the sub-agent, ' \
                              'e.g. "Find the populations of Reykjavik and ' \
                              'Helsinki in 2024 and report both numbers." ' \
                              'It has no access to the parent conversation, ' \
                              'so include all necessary context.'
          },
          execute: lambda { |task:|
            idx = sub_counter
            sub_counter += 1
            sub_name = parent_name.empty? ? "sub_agent #{idx}" : "#{parent_name}_#{idx}"

            sub = Agent.new(
              transport: transport,
              system_prompt: system_prompt,
              tools: sub_tools,
              listeners: listeners.for_sub_agent(max_steps: max_steps, name: sub_name),
              context_window: context_window,
              name: sub_name
            )
            sub.run_loop(user_message: task)
            sub.last_assistant_content
          }
        )
      end
    end
  end
end
