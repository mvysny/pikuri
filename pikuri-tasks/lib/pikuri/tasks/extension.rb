# frozen_string_literal: true

module Pikuri
  # Namespace for the in-memory task-list feature. Holds the
  # {List} value type, the four task tool classes ({Create},
  # {InProgress}, {Completed}, {Delete}), and the {Extension} that
  # wires them into an {Pikuri::Agent}.
  module Tasks
    # An {Pikuri::Agent::Extension} that auto-wires an in-memory
    # task list onto an agent: constructs a fresh {List}, registers
    # the four task tool classes against it, and appends a brief
    # workflow snippet to the system prompt.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Tasks::Extension.new
    #   end
    #
    # The list is per-Agent and in-memory. It is dropped when the
    # agent is garbage-collected — nothing is written to disk.
    #
    # == Sub-agents
    #
    # Sub-agents do not inherit extensions (see CLAUDE.md's "Seams").
    # Concretely: a sub-agent spawned by the +agent+ tool gets a
    # fresh persona, fresh toolset, no task list. That keeps the
    # parent's plan private to the parent and avoids the
    # who-owns-which-task confusion a shared list would produce.
    # If a host wants the sub-agent to also have a task list, it
    # adds the extension to the sub-agent's own configurator —
    # cleanly opt-in, no implicit sharing.
    #
    # == Empty default
    #
    # No +catalog+-style empty state: registering the extension
    # always installs the four tools and the snippet. A host that
    # doesn't want tasks simply omits the extension.
    class Extension
      include Pikuri::Agent::Extension

      # System-prompt snippet appended once per agent. Short by
      # design: rules-of-thumb only, no inventory (the tool
      # descriptions cover their own usage). Mirrors the shape of
      # opencode's +todowrite.txt+ but condensed to fit pikuri's
      # "short prose over abstract framing" docs convention.
      #
      # @return [String]
      PROMPT_SNIPPET = <<~PROMPT
        <tasks_usage>
        You have an in-memory task list. Use it to plan and track multi-step work.

        Workflow:
        - When a task has 3+ steps, call `task_create` once with the full plan (newline-separated items, all start as `pending`).
        - Before starting an item, call `task_in_progress` with its exact content. Keep exactly one item `in_progress` at a time.
        - When an item is fully done (including any required verification), call `task_completed` with its exact content.
        - Use `task_delete` to remove items that turn out not to be needed.

        Skip task tracking entirely for single-step or purely informational requests — it adds noise, not value.

        Every mutation returns the full current list, so you do not need a separate read tool. Content doubles as identifier across the four tools: spelling and capitalization must match exactly.
        </tasks_usage>
      PROMPT

      # Tool classes the extension auto-registers. Used both for
      # construction and for the duplicate-registration guard below.
      TOOL_CLASSES = [Create, InProgress, Completed, Delete].freeze

      # @return [Extension]
      def initialize
        @list = List.new
      end

      # @return [List] the per-agent list, exposed for tests and for
      #   hosts that want to render it in a UI (a future TUI could
      #   surface +list.items+ in a sidebar).
      attr_reader :list

      # Construct the four tools (each sharing +@list+) and register
      # them, then append {PROMPT_SNIPPET}. Raises if any of the four
      # tool classes have been pre-registered via +c.add_tool+ — the
      # whole point of the extension is to be the single owner of the
      # shared list, and a manually pre-registered tool would bind to
      # a different list.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        TOOL_CLASSES.each do |cls|
          if c.tools.any?(cls)
            raise "#{cls} cannot be pre-registered (in tools: or via c.add_tool) " \
                  'when adding Pikuri::Tasks::Extension — the extension auto-registers all four task tools ' \
                  'so they share the same in-memory list.'
          end
        end

        TOOL_CLASSES.each { |cls| c.add_tool(cls.new(list: @list)) }
        c.append_system_prompt(PROMPT_SNIPPET)
        nil
      end
    end
  end
end
