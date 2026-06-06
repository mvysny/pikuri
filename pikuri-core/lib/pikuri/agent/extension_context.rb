# frozen_string_literal: true

module Pikuri
  class Agent
    # Capability facade handed to {Extension#bind} and
    # {Extension#on_user_message} — the runtime counterpart of
    # {Configurator}. Where the Configurator collects *build-time*
    # declarations (tools, listeners, prompt snippets), this object
    # grants the *runtime* capabilities an extension needs once the
    # agent is fully wired: emitting domain events onto the listener
    # stream, registering raw per-agent tools, and deriving sub-agent
    # listener lists.
    #
    # == Why a handed object, not a getter on Agent
    #
    # The {Agent} deliberately exposes NO public path to these
    # capabilities — no +listeners+ reader, no +chat+ reader, no
    # emit method. Holding an agent reference grants read access to
    # its configuration ({Agent#tools}, {Agent#transport}, ...) and
    # nothing more; the write capabilities live here, and the only
    # way to obtain this object is to be an {Extension} receiving a
    # +bind+ / +on_user_message+ call (or to be handed it onward by
    # one, e.g. {Pikuri::SubAgent::SubAgentTool} and
    # {Pikuri::Mcp::Servers::Connect} both capture the context their
    # extension's +bind+ received). Capabilities flow by explicit
    # handoff, never by fetching from a globally reachable object.
    #
    # The usual Ruby caveat applies: nothing here is mechanically
    # sealed (+instance_variable_get+ exists). The boundary is the
    # API contract — same as every seam in CLAUDE.md.
    #
    # == Boundary rule
    #
    # Operations that *act on* the live agent's wiring live here.
    # Passive readers of constructor-given config (+transport+,
    # +id+, +streaming+, +tools+, +cancellable+, ...) stay on
    # {Agent}, reachable via {#agent}. Don't move readers in; don't
    # add capabilities to Agent.
    #
    # == Audit
    #
    # One context per agent, constructed by {Agent#initialize} right
    # before the extension +bind+ sweep. {ListenerList#emit} has
    # exactly two callers: {Agent} (loop narration) and this class
    # (extension domain events). The roster of capability users is
    # +grep -rn 'emit_event\|add_raw_tool\|sub_agent_listeners'
    # pikuri-*/lib/+.
    class ExtensionContext
      # @param agent [Agent] the live, fully wired agent.
      # @param chat [RubyLLM::Chat] the agent's underlying chat —
      #   target of {#add_raw_tool}.
      # @param listeners [ListenerList] the agent's listener list —
      #   target of {#emit_event} / {#sub_agent_listeners}.
      # @param on_close_sink [Array<Proc>] the agent's live
      #   +@on_close_handlers+ array, which {#on_close} appends to —
      #   same live-sink shape as {Configurator}'s +on_close_sink:+.
      def initialize(agent:, chat:, listeners:, on_close_sink:)
        @agent = agent
        @chat = chat
        @listeners = listeners
        @on_close_handlers = on_close_sink
      end

      # @return [Agent] the live agent, for read access to its
      #   configuration (tools, transport, id, streaming, ...).
      attr_reader :agent

      # Emit a domain event onto the agent's listener stream.
      #
      # Core {Event} variants narrate the chat loop and are emitted
      # by {Agent} alone; gems define their own variants (e.g.
      # +Pikuri::Tasks::ListChanged+) in their own namespace and
      # emit them here. Listeners must no-op on variants they don't
      # recognize — {Listener::Base#on_event}'s default and
      # +case+-fallthrough give that for free.
      #
      # Called on the agent's thread (typically from inside a tool's
      # +execute+, where the event lands between {Event::ToolCall}
      # and {Event::ToolResult} in the stream). Listeners doing
      # cross-thread handoff snapshot/serialize inside +on_event+.
      #
      # @param event [Object] an immutable event value (by
      #   convention a +Data+ instance).
      # @return [void]
      def emit_event(event)
        @listeners.emit(event)
        nil
      end

      # Register a raw +RubyLLM::Tool+ subclass on the agent's
      # underlying chat, bypassing the {Pikuri::Tool}
      # strict-validation seam — hence "raw": native pikuri tools
      # should go through {Pikuri::Tool} (registered at build time
      # via {Configurator#add_tool}) so they get {Tool::Parameters}
      # validation and the LLM-actionable +"Error: ..."+ contract.
      # Intended callers: {Pikuri::Mcp::Servers} (MCP tools
      # deliberately bypass — see IDEAS.md §"MCP tools bypass
      # +Pikuri::Tool+ entirely") and
      # {Pikuri::SubAgent::Extension} (the +agent+ tool must
      # register after the parent's tool list is final).
      #
      # The added tool does NOT enter {Agent#tools}, only the chat's
      # tool list. Sub-agents therefore cannot snapshot it — which
      # is the whole point: activation is strictly per-agent, see
      # IDEAS.md §"Per-agent activation, no propagation".
      #
      # @param ruby_llm_tool [Class] subclass of +RubyLLM::Tool+
      # @return [void]
      def add_raw_tool(ruby_llm_tool)
        @chat.with_tool(ruby_llm_tool)
        nil
      end

      # Derive a listener list for a spawned sub-agent via
      # {ListenerList#for_sub_agent}. Sole intended caller:
      # {Pikuri::SubAgent::SubAgentTool}, once per spawn.
      #
      # The derived list deliberately aliases the parent's listener
      # *instances* where a listener opts to share by reference
      # (stateful sinks like {Listener::InMemoryEventList}) — see
      # {ListenerList#for_sub_agent} for the per-listener semantics.
      #
      # @param params [Hash{Symbol => Object}] forwarded to each
      #   listener's +for_sub_agent+ hook (currently +id:+).
      # @return [ListenerList]
      def sub_agent_listeners(**params)
        @listeners.for_sub_agent(**params)
      end

      # Register a handler called by {Agent#close}. Symmetric to
      # {Configurator#on_close} — same LIFO + per-handler-rescue +
      # idempotent semantics — but available post-construction, so
      # an {Extension}'s +bind+ can install per-agent cleanup keyed
      # to this specific agent (e.g. +Pikuri::Memory::Extension+
      # arms its recorder's bounded flush here).
      #
      # @yield called with no arguments at close time
      # @return [void]
      def on_close(&blk)
        raise ArgumentError, 'on_close requires a block' unless block_given?

        @on_close_handlers << blk
        nil
      end
    end
  end
end
