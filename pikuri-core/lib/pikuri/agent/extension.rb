# frozen_string_literal: true

module Pikuri
  class Agent
    # The Extension protocol — how hosts bolt extra capabilities
    # (system-prompt sections, tools, lifecycle hooks) onto an {Agent}.
    # Added via {Configurator#add_extension} inside the +Agent.new+ block;
    # the Agent then drives a fixed hook set: {#configure} during the block
    # (gets the {Configurator}), {#bind} once fully constructed,
    # {#on_user_message} per user turn, {#on_conversation_reset} per
    # {Agent#clear_conversation} (these three get the runtime
    # {ExtensionContext}), and {#system_prompt_snippets} whenever the prompt
    # is (re)assembled (no argument — reads state set in +configure+).
    #
    # Mix this module in to inherit no-op defaults for every hook, and
    # override what you need. Not including it also works *if the class
    # defines every hook* — the Agent calls them by name with no
    # +respond_to?+ guard, so a missing one raises.
    #
    # The whole surface fires on the *parent agent only* — sub-agents do not
    # inherit extensions (each persona owns its toolset and prompt verbatim).
    #
    # == Example
    #
    #   class MyExtension
    #     include Pikuri::Agent::Extension
    #     def system_prompt_snippets = ["Always be polite."]
    #     # configure / bind not overridden — inherit the empty defaults
    #   end
    #
    # See +Pikuri::Mcp::Extension+ / +Pikuri::Skill::Extension+ for worked
    # implementations.
    module Extension
      # Called immediately by {Configurator#add_extension} during the
      # +Agent.new+ block, once per instance, with the parent's
      # {Configurator}. Default no-op; override to install *agent-agnostic*
      # state — typically:
      #
      # * tools via {Configurator#add_tool}, listeners via
      #   {Configurator#add_listener}
      # * parent-only +on_close+ cleanup via {Configurator#on_close}
      # * read transport / cancellable / etc. off the Configurator
      #
      # @param c [Configurator] the parent agent's Configurator
      # @return [void]
      def configure(c); end

      # Called by {Agent#initialize} after the block returns and the chat is
      # fully wired, with the agent's {ExtensionContext}. Default no-op;
      # override to install state keyed to the live agent — typically:
      #
      # * dynamic tools via {ExtensionContext#add_raw_tool}
      # * domain-event wiring via {ExtensionContext#emit_event}
      # * per-agent +on_close+ via {ExtensionContext#on_close}
      # * stash +ctx+ if the extension's tools act on this agent later
      #
      # @param ctx [ExtensionContext] capability facade for the live agent
      # @return [void]
      def bind(ctx); end

      # Optional per-turn hook fired after a user message is added to the
      # chat. Default no-op returning +nil+; override and return a {String}
      # to inject it as a +:system+ message after the user turn.
      #
      # The Agent only ever *appends* the returned block at the tail — never
      # rewrites or removes an earlier one, which would bust the provider
      # prefix cache for everything after the edit. Stale blocks ride the
      # existing context-window machinery, not a per-turn rewrite.
      #
      # @param ctx [ExtensionContext] the live agent whose turn this is (same
      #   instance +bind+ received)
      # @param content [String] the user message (initial or interloper)
      # @return [String, nil] text to inject verbatim as a system-role message
      #   after the user message, or +nil+ to inject nothing
      def on_user_message(ctx, content); end

      # Optional hook fired by {Agent#clear_conversation} (a "/clear").
      # Override to drop *conversation-scoped* state; default no-op, so an
      # extension holding only process/infrastructure state opts out by not
      # defining it.
      #
      # That distinction is the point: reset state that only makes sense
      # within one conversation (+Pikuri::Tasks::Extension+ clears its list,
      # the workspace clears its read-record); leave infrastructure alone
      # (MCP subprocesses, a docker-backed server, the memory recorder's
      # queue — a clear is not a quit).
      #
      # Do *not* touch the system prompt here — that refreshes automatically
      # via {#system_prompt_snippets}, which the clear re-pulls. This hook is
      # only for imperative state the prompt machinery can't express. An
      # extension owning a domain event should emit it here so UI listeners
      # see the reset (Tasks fires +Tasks::ListChanged+ with an empty list),
      # synchronously after the Agent's {Event::Reset}.
      #
      # @param ctx [ExtensionContext] the live agent being cleared (same
      #   instance +bind+ received)
      # @return [void]
      def on_conversation_reset(ctx); end

      # This extension's system-prompt contributions, as text sections.
      # Default none (+[]+); override to contribute one or more.
      #
      # Pull, not push: the {Agent} assembles its prompt by concatenating the
      # base with what every extension returns here — at construction and
      # again on every {Agent#clear_conversation}. So a section computed from
      # live state (a resident memory persona, +MACHINE.md+ from disk) is
      # *recomputed* on clear and stays current; a static section returns the
      # same constant.
      #
      # No argument: read instance state populated in {#configure} (which runs
      # first). Producing that state (starting servers, probing a model)
      # belongs in +configure+; this only *reads* it, so it stays cheap enough
      # for every clear (memoize an expensive one-shot at its source —
      # +Pikuri::Os::SystemInfo#prompt_section+). Sections are joined by the
      # Agent (blank/nil dropped), in registration order.
      #
      # @return [Array<String>] zero or more prompt sections; +[]+ for none
      def system_prompt_snippets = []
    end
  end
end
