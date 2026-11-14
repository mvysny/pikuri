# frozen_string_literal: true

module Pikuri
  class Agent
    # The Extension protocol — how hosts bolt extra capabilities
    # (system-prompt sections, tools, lifecycle hooks) onto an {Agent}.
    # Added via {Configurator#add_extension} inside the +Agent.new+ block,
    # which calls {#configure} at once; the Agent then pulls
    # {#system_prompt_snippets} when it assembles the prompt and calls
    # {#on_user_message} on every user turn.
    #
    #   class Reminder
    #     include Pikuri::Agent::Extension
    #     def system_prompt_snippets = ["Always be polite."]
    #   end
    #
    # An instance serves one agent, which is one conversation: build a fresh
    # one for every +Agent.new+, so per-conversation state is plain instance
    # state and nothing has to reset it; {Configurator#add_extension} refuses
    # a reused one. A resource that legitimately outlives the conversation is
    # built by the host and passed in.
    #
    # Mix this module in to inherit no-op defaults for every hook, and
    # override what you need. Not including it also works *if the class
    # defines every hook* — the Agent calls them by name with no
    # +respond_to?+ guard, so a missing one raises.
    #
    # The whole surface fires on the *parent agent only* — sub-agents do not
    # inherit extensions (each persona owns its toolset and prompt verbatim).
    # See +Pikuri::Mcp::Extension+ / +Pikuri::Skill::Extension+ for worked
    # implementations.
    module Extension
      # Install this extension on the agent being built. Keep +c+ to act on
      # the agent later — {Configurator#emit_event} from a change callback,
      # {Configurator#add_raw_tool} from a tool's +execute+. Default no-op.
      #
      # A resumed conversation is {Configurator#history}, so an extension can
      # rebuild what the transcript implies — the tools it had registered
      # mid-conversation.
      #
      # @param c [Configurator] the agent's Configurator
      # @return [void]
      def configure(c); end

      # Optional per-turn hook fired after a user message is added to the
      # chat. Default no-op returning +nil+; override and return a {String} to
      # have it appended after the user turn as a +<system-reminder>+ reference
      # block (see {Agent#append_reference_block} for the envelope and why it
      # is not a +:system+ message).
      #
      # The Agent only ever *appends* the returned block at the tail — never
      # rewrites or removes an earlier one, which would bust the provider
      # prefix cache for everything after the edit. Stale blocks ride the
      # existing context-window machinery, not a per-turn rewrite.
      #
      # @param content [String] the user message's text (initial or
      #   interloper); +""+ when the turn carries only attachments
      # @param attachments [Array<Pikuri::Attachment>] what the model was
      #   shown with it. Passed as data, so each extension words it as it
      #   needs — pikuri-memory records a note naming each file, while a
      #   reminder that only reacts to the turn ignores them.
      # @return [String, nil] text to inject verbatim as a system-role message
      #   after the user message, or +nil+ to inject nothing
      def on_user_message(content, attachments); end

      # This extension's system-prompt contributions, as text sections.
      # Default none (+[]+); override to contribute one or more.
      #
      # Pull, not push: the {Agent} assembles its prompt once, at
      # construction, by concatenating the base with what every extension
      # returns here. A section computed from live state (a resident memory
      # persona, +MACHINE.md+ from disk) is therefore as of the conversation's
      # start, and a "/clear" — a new agent — takes it again.
      #
      # No argument: read instance state populated in {#configure} (which runs
      # first). Producing that state (starting servers, probing a model)
      # belongs in +configure+; this only *reads* it (memoize an expensive
      # one-shot at its source — +Pikuri::Os::SystemInfo#prompt_section+).
      # Sections are joined by the Agent (blank/nil dropped), in registration
      # order.
      #
      # @return [Array<String>] zero or more prompt sections; +[]+ for none
      def system_prompt_snippets = []

      # What this extension adds to the lethal-trifecta tree
      # ({Pikuri::Trifecta}): legs the wired agent holds beyond its own tools,
      # and child nodes for any sub-agents it introduces. Default none.
      #
      # Only two kinds of extension owe an answer, and both are things per-tool
      # tagging structurally cannot see: one that introduces **sub-agents** (a
      # whole node, plus the gate on the delegation edge) and one that mounts a
      # **foreign tool surface** whose tools carry no legs of their own.
      #
      # +tools+ is the wired agent's tools plus its sub-agent tools, so an
      # extension resolving a persona's +tool_names+ can select the same
      # objects the sub-agent will actually receive — the resolution and the
      # node it produces stay with whoever owns them.
      #
      # Unlike every other hook here, the Agent calls this **guarded by
      # +respond_to?+**: this protocol permits a class that defines all hooks
      # without including the module, and an unguarded new hook would break
      # those. So a non-including extension may simply not have it.
      #
      # @param tools [Array<Pikuri::Tool>] the agent's tools + sub-agent tools
      # @return [Pikuri::Trifecta::Contribution, nil] +nil+ for none
      def trifecta_contribution(tools) = nil
    end
  end
end
