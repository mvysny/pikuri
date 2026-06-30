# frozen_string_literal: true

module Pikuri
  class Agent
    # The Extension protocol — how hosts bolt extra capabilities
    # (system-prompt snippets, tools, lifecycle hooks) onto an
    # {Agent}. Extensions are added via {Configurator#add_extension}
    # inside the +Agent.new+ block; the Agent then drives three hooks
    # on each — {#configure} during the block, {#bind} once the agent
    # is fully constructed, and {#on_user_message} on every user turn
    # thereafter.
    #
    # Each phase receives that phase's context object: +configure+
    # gets the build-time {Configurator}; +bind+ and
    # +on_user_message+ get the runtime {ExtensionContext} — the
    # capability facade for everything that acts on the live agent
    # (domain-event emission, raw tool registration, sub-agent
    # listener derivation), with the agent itself readable via
    # {ExtensionContext#agent}.
    #
    # Mix this module into an extension class to inherit empty
    # default implementations of all three hooks; override the ones
    # you need. Extensions that don't +include+ this module still
    # work *if they define all three methods themselves* — the Agent
    # and Configurator call them by name with no +respond_to?+ guard,
    # so a missing one raises. The module exists to make the protocol
    # *explicit* and to give "I want to implement just +configure+"
    # extensions free no-op +bind+ / +on_user_message+ defaults (and
    # any other combination).
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
      # chat is fully wired, with the agent's {ExtensionContext} as
      # the argument. Fires once per agent the extension was
      # registered to via {Configurator#add_extension} — in the
      # typical setup that's the parent agent only, since sub-agents
      # do not inherit extensions. The default is a no-op; override
      # when you need to install state keyed to the live agent.
      # Things you typically do here:
      #
      # * register dynamic tools via {ExtensionContext#add_raw_tool}
      #   (used by {Pikuri::Mcp::Extension} for +mcp_connect+,
      #   whose +execute+ closure needs the context so activations
      #   register on the right chat)
      # * wire domain-event emission via
      #   {ExtensionContext#emit_event} (e.g. +Pikuri::Tasks::Extension+
      #   arms its list's +on_change+ here)
      # * register per-agent +on_close+ handlers via
      #   {ExtensionContext#on_close}
      # * stash the +ctx+ if the extension's tools need to act on
      #   this specific agent later
      #
      # @param ctx [ExtensionContext] capability facade for the
      #   live, fully wired agent
      # @return [void]
      def bind(ctx); end

      # Optional per-turn hook fired by the {Agent} after a user-message
      # is added to the chat. The
      # default is a no-op returning +nil+; override and return {String}
      # to emit a `:system` message with that text.
      #
      # == Append-only, never mutate
      #
      # The Agent only ever *appends* the returned block at the tail; it never
      # rewrites or removes an earlier one. Mutating mid-log would bust the
      # provider prefix cache for every message after the edit. Stale blocks
      # ride the existing context-window machinery, not a per-turn rewrite.
      #
      # == Not inherited by sub-agents
      #
      # Like the rest of the extension surface, this fires on the parent agent
      # only — sub-agents do not inherit extensions, so a persona's turns are
      # never prefetched or recorded by the parent's memory.
      #
      # @param ctx [ExtensionContext] capability facade for the live
      #   agent whose turn this is — same instance +bind+ received
      # @param content [String] the user message (initial or interloper) about
      #   to be sent to the model
      # @return [String, nil] an optional block of text to be injected verbatim as
      #   a system-role message (after the user message), or +nil+ to inject nothing
      def on_user_message(ctx, content); end

      # Optional hook fired by {Agent#clear_conversation} when the host
      # clears the conversation log (a "/clear"). Override to drop
      # *conversation-scoped* state the extension owns; the default is a
      # no-op, so an extension that holds only process / infrastructure
      # state (MCP connections, a self-managed server, the memory
      # capture worker) opts out simply by not defining it.
      #
      # == Conversation-scoped vs infrastructure
      #
      # The distinction is the whole point of the hook. State that only
      # makes sense *within one conversation* is reset here:
      # +Pikuri::Tasks::Extension+ clears its list (a plan with no
      # context to plan against is meaningless) and the workspace
      # extension clears its read-record (the read-before-edit gate's
      # memory of what was read). State that spans conversations or is
      # plain infrastructure is *not*: MCP subprocesses stay connected,
      # a docker-backed server keeps running, and the memory recorder
      # keeps draining its queue — a clear is not a quit, and turns
      # already enqueued are real memories the background worker should
      # still write.
      #
      # == System prompt is handled for you
      #
      # An extension's system-prompt contributions
      # ({Configurator#append_system_prompt}) are baked into the agent's
      # system prompt at construction; {Agent#clear_conversation}
      # re-applies that prompt verbatim, so there is nothing to do here
      # for them. Snippets read from live state at +configure+ time
      # (e.g. a resident memory persona) are deliberately *not* refreshed
      # on clear — the construction-time snapshot persists, matching how
      # they already don't refresh per-turn within a conversation.
      #
      # An extension that owns a domain event should emit it from here so
      # UI listeners see the reset — e.g. +Pikuri::Tasks::Extension+'s
      # list clear fires +Tasks::ListChanged+ with an empty list, the
      # same way every other list mutation notifies. Runs on the agent
      # thread, synchronously, after the {Event::Reset} the Agent emits
      # to the listener stream.
      #
      # Like the rest of the extension surface, this fires on the parent
      # agent only — sub-agents do not inherit extensions.
      #
      # @param ctx [ExtensionContext] capability facade for the live
      #   agent whose conversation is being cleared — same instance
      #   +bind+ received
      # @return [void]
      def on_conversation_reset(ctx); end
    end
  end
end
