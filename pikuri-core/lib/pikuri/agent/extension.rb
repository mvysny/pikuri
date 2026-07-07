# frozen_string_literal: true

module Pikuri
  class Agent
    # The Extension protocol — how hosts bolt extra capabilities
    # (system-prompt sections, tools, lifecycle hooks) onto an
    # {Agent}. Extensions are added via {Configurator#add_extension}
    # inside the +Agent.new+ block; the Agent then drives a fixed set
    # of hooks on each: {#configure} during the block, {#bind} once the
    # agent is fully constructed, {#system_prompt_snippets} whenever the
    # prompt is (re)assembled, {#on_user_message} on every user turn,
    # and {#on_conversation_reset} on every {Agent#clear_conversation}.
    #
    # Each phase receives that phase's context object: +configure+
    # gets the build-time {Configurator}; +bind+,
    # +on_user_message+, and +on_conversation_reset+ get the runtime
    # {ExtensionContext} — the capability facade for everything that
    # acts on the live agent (domain-event emission, raw tool
    # registration, sub-agent listener derivation), with the agent
    # itself readable via {ExtensionContext#agent}.
    # {#system_prompt_snippets} takes no argument — it reads instance
    # state populated in +configure+.
    #
    # Mix this module into an extension class to inherit empty
    # default implementations of every hook; override the ones
    # you need. Extensions that don't +include+ this module still
    # work *if they define every hook themselves* — the Agent
    # and Configurator call them by name with no +respond_to?+ guard,
    # so a missing one raises. The module exists to make the protocol
    # *explicit* and to give "I want to implement just +configure+"
    # extensions free no-op defaults for the rest (in any combination).
    #
    # == Example
    #
    #   class MyExtension
    #     include Pikuri::Agent::Extension
    #
    #     def system_prompt_snippets = ["Always be polite."]
    #
    #     # configure / bind not overridden — inherit the empty defaults
    #   end
    #
    # See +Pikuri::Mcp::Extension+ and +Pikuri::Skill::Extension+ for
    # the canonical worked implementations.
    module Extension
      # Called immediately by {Configurator#add_extension} during the
      # +Agent.new+ block, with the parent agent's {Configurator}.
      # Runs exactly once per extension instance, on the parent agent
      # only — sub-agents do not re-run +configure+. The default is a
      # no-op; override when you need to install *agent-agnostic*
      # state. Things you typically do here:
      #
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
      # == System prompt is handled separately
      #
      # Do *not* touch the system prompt here. An extension's prompt
      # contribution comes from {#system_prompt_snippets}, which
      # {Agent#clear_conversation} re-pulls and re-assembles on every
      # clear — so a section read from live state (a resident memory
      # persona, +MACHINE.md+ notes) refreshes automatically without any
      # code in this hook. This hook is only for *imperative*
      # conversation-scoped state the prompt machinery can't express.
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

      # This extension's contributions to the agent's system prompt, as
      # a list of text sections. The default is none ([]); override to
      # contribute one or more.
      #
      # == Pull, not push — and why it refreshes on clear
      #
      # The {Agent} *assembles* its system prompt by concatenating its
      # base prompt with the sections every extension returns here —
      # once at construction, and again on every
      # {Agent#clear_conversation}. So this method is the single source
      # of an extension's prompt contribution; there is no
      # "append once" call. The payoff is refresh: a section computed
      # from live state (a resident memory persona fetched from a store,
      # +MACHINE.md+ read from disk) is *recomputed* on clear, so
      # persistent data stays current across a "/clear" instead of being
      # frozen at construction. A static section just returns the same
      # constant each call.
      #
      # == Argument-free; reads instance state set in +configure+
      #
      # No context is passed: a contributor reads its own instance state
      # (catalogs, clients, registries) populated during {#configure},
      # which always runs first. Side effects that *produce* that state
      # (starting MCP servers, probing a model) belong in {#configure};
      # this method only *reads* the result, so it stays cheap enough to
      # call on every clear. The one caller-managed cost is deliberate —
      # e.g. re-reading a small file or re-querying a store; an expensive
      # one-shot probe should be memoized at its source so a re-pull is
      # free (worked example: +Pikuri::Os::SystemInfo#prompt_section+).
      #
      # Sections are joined by the Agent (blank/nil entries dropped), in
      # extension-registration order. Like the rest of the surface, this
      # is consulted on the parent agent only — sub-agents do not inherit
      # extensions.
      #
      # @return [Array<String>] zero or more prompt sections; +[]+ to
      #   contribute nothing
      def system_prompt_snippets = []
    end
  end
end
