# frozen_string_literal: true

module Pikuri
  class Agent
    # The Extension protocol — how hosts bolt extra capabilities
    # (system-prompt snippets, tools, lifecycle hooks) onto an
    # {Agent}. Extensions are added via {Configurator#add_extension}
    # inside the +Agent.new+ block; the Agent then drives two hooks
    # on each — {#configure} during the block, {#bind} once the
    # agent is fully constructed.
    #
    # Mix this module into an extension class to inherit empty
    # default implementations of both hooks; override the ones you
    # need. Extensions that don't +include+ this module still work
    # if they define both methods themselves (the Agent and
    # Configurator call them by name) — the module exists to make
    # the protocol *explicit* and to give "I want to implement just
    # +configure+" extensions a free no-op +bind+ (and vice versa).
    #
    # == Example
    #
    #   class MyExtension
    #     include Pikuri::Agent::Extension
    #
    #     def configure(c)
    #       c.append_system_prompt("Always be polite.")
    #     end
    #
    #     # bind not overridden — inherits the empty default
    #   end
    #
    # See +Pikuri::Mcp::Extension+ and +Pikuri::Skill::Extension+
    # (once those land in Steps 2-3 of the gem-split refactor — see
    # IDEAS.md §"Extension protocol design") for the canonical
    # worked implementations.
    module Extension
      # Called immediately by {Configurator#add_extension} during the
      # +Agent.new+ block, with the parent agent's {Configurator}.
      # Runs exactly once per extension instance, on the parent agent
      # only — sub-agents do not re-run +configure+. The default is a
      # no-op; override when you need to install *agent-agnostic*
      # state. Things you typically do here:
      #
      # * append snippets to the system prompt via
      #   {Configurator#append_system_prompt}
      # * register tools via {Configurator#add_tool}
      # * register listeners via {Configurator#add_listener}
      # * register parent-only +on_close+ handlers via
      #   {Configurator#on_close} (for cleanup of resources the
      #   extension created in +configure+)
      # * read the agent's transport / cancellable / etc. via the
      #   Configurator's +attr_reader+s
      #
      # @param c [Configurator] the parent agent's Configurator
      # @return [void]
      def configure(c); end

      # Called by {Agent#initialize} after the block returns and the
      # chat is fully wired, with the live {Agent} as the argument.
      # Runs once per agent — on the parent during its construction,
      # and once more on each sub-agent during the sub-agent's
      # construction (same extension instance, multiple +bind+ calls
      # — per-agent state lives in +bind+'s closures, not in
      # extension instance state). The default is a no-op; override
      # when you need to install *per-agent* state. Things you
      # typically do here:
      #
      # * register per-agent dynamic tools via
      #   {Agent#internal_add_tool}
      # * register per-agent +on_close+ handlers via
      #   {Agent#on_close}
      # * stash an +@agent+ reference if the extension's tools need
      #   to act on this specific agent later (e.g. when a tool
      #   fires and wants to register more tools on its owning
      #   chat)
      #
      # @param agent [Agent] the live agent, fully wired
      # @return [void]
      def bind(agent); end
    end
  end
end
