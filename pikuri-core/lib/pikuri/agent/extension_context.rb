# frozen_string_literal: true

module Pikuri
  class Agent
    # Capability facade handed to {Extension#bind} and
    # {Extension#on_user_message} — the runtime counterpart of {Configurator}.
    # Where the Configurator collects *build-time* declarations, this grants
    # the *runtime* capabilities an extension needs once the agent is wired:
    # emitting domain events, registering raw per-agent tools, deriving
    # sub-agent listener lists.
    #
    # == Why a handed object, not a getter on Agent
    #
    # {Agent} exposes NO public path to these capabilities (no +listeners+ /
    # +chat+ reader, no emit method): holding an agent grants read access to
    # its config and nothing more. The only way to obtain this object is to be
    # an {Extension} receiving +bind+ / +on_user_message+ — or to be handed it
    # onward by one ({Pikuri::SubAgent::SubAgentTool} and
    # {Pikuri::Mcp::Servers::Connect} both capture the context their +bind+
    # received). Capabilities flow by explicit handoff, never by fetching from
    # a globally reachable object. The boundary is the API contract, not a
    # mechanical seal — same as every seam in AGENTS.md.
    #
    # == Boundary rule
    #
    # Operations that *act on* the live agent's wiring live here; passive
    # readers of constructor-given config (+transport+, +id+, +tools+, ...)
    # stay on {Agent}, reachable via {#agent}. Don't move readers in; don't add
    # capabilities to Agent.
    #
    # == Audit
    #
    # One context per agent, built by {Agent#initialize} before the +bind+
    # sweep. {ListenerList#emit} has exactly two callers: {Agent} (loop
    # narration) and this class (domain events). Capability-user roster:
    # +grep -rn 'emit_event\|add_raw_tool\|sub_agent_listeners' pikuri-*/lib/+.
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

      # Emit a domain event onto the agent's listener stream. Core {Event}
      # variants narrate the loop ({Agent}-emitted); gems define their own
      # (e.g. +Pikuri::Tasks::ListChanged+) and emit them here. Listeners must
      # no-op on variants they don't recognize (the {Listener::Base#on_event}
      # default gives that for free).
      #
      # Called on the agent's thread (typically inside a tool's +execute+,
      # landing between {Event::ToolCall} and {Event::ToolResult}); listeners
      # doing cross-thread handoff snapshot inside +on_event+.
      #
      # @param event [Object] an immutable event value (by convention a +Data+)
      # @return [void]
      def emit_event(event)
        @listeners.emit(event)
        nil
      end

      # Register a raw +RubyLLM::Tool+ subclass on the agent's chat, bypassing
      # the {Pikuri::Tool} strict-validation seam — hence "raw" (native tools
      # go through {Configurator#add_tool} for {Tool::Parameters} validation).
      # Callers: {Pikuri::Mcp::Servers} (MCP tools deliberately bypass) and
      # {Pikuri::SubAgent::Extension} (the +agent+ tool registers after the
      # parent's tool list is final).
      #
      # The tool does NOT enter {Agent#tools}, only the chat's list — so
      # sub-agents can't snapshot it, which is the point: activation is strictly
      # per-agent.
      #
      # @param ruby_llm_tool [Class] subclass of +RubyLLM::Tool+
      # @return [void]
      def add_raw_tool(ruby_llm_tool)
        @chat.with_tool(ruby_llm_tool)
        nil
      end

      # Derive a listener list for a spawned sub-agent via
      # {ListenerList#for_sub_agent}. Sole caller:
      # {Pikuri::SubAgent::SubAgentTool}, once per spawn. The derived list
      # aliases the parent's listener *instances* where a listener opts to
      # share by reference — see {ListenerList#for_sub_agent}.
      #
      # @param params [Hash{Symbol => Object}] forwarded to each listener's
      #   +for_sub_agent+ hook (currently +id:+).
      # @return [ListenerList]
      def sub_agent_listeners(**params)
        @listeners.for_sub_agent(**params)
      end

      # Register a handler called by {Agent#close} — symmetric to
      # {Configurator#on_close} (LIFO, per-handler rescue, idempotent) but
      # available post-construction, so an {Extension}'s +bind+ can install
      # per-agent cleanup (Memory arms its recorder's bounded flush here).
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
