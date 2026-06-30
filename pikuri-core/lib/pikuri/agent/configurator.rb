# frozen_string_literal: true

module Pikuri
  class Agent
    # Build-time collector yielded into the +Pikuri::Agent.new+ block.
    # Hosts and {Extension} implementations call its methods to declare
    # additional tools, listeners, +on_close+ handlers, extension
    # instances, and persona-flavored sub-agents;
    # {Agent#initialize} drains the collected state into the agent's
    # final wiring before returning. (System-prompt contributions are
    # *not* collected here — the Agent pulls them from each extension's
    # {Extension#system_prompt_snippets} at assembly time.)
    #
    # == Why this exists
    #
    # Splits "configure the agent" from "the agent's runtime state".
    # Hosts can write a block that reads cleanly:
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_listener Pikuri::Agent::Listener::Terminal.new
    #     c.add_tool     Pikuri::Tool::WebSearch.build
    #     c.add_tool     Pikuri::Tool::WEB_SCRAPE
    #     c.add_tool     Pikuri::Tool::FETCH
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog)
    #   end
    #
    # == Two tool pools: regular vs. sub-agent-only
    #
    # {#add_tool} registers a tool the parent agent can call: it lands
    # in {#tools} and gets handed to ruby_llm via +chat.with_tool+.
    # {#add_sub_agent_tool} registers a tool the parent *cannot* call
    # — it lands in {#sub_agent_tools} and is never sent to ruby_llm
    # for the parent, but is visible to {Pikuri::SubAgent::Extension}'s
    # persona-tool-name resolution. The use case is the lethal-trifecta
    # defense in {Pikuri::Code::Bash::Sandbox} terms: keep network tools
    # (+web_search+ / +web_scrape+ / +fetch+) off the parent so a prompt-
    # injected file read cannot egress through the parent's own tools,
    # while still letting the +researcher+ persona reach them via the
    # +agent+ delegation tool. See SECURITY.md §"Defense: capability
    # boundaries via sub-agents".
    #
    # Extensions implement their +configure(c)+ hook against the same
    # type, so the call sites for "block users add stuff" and
    # "extensions add stuff" share one API.
    #
    # == Lifecycle
    #
    # One +Configurator+ per +Agent.new+ invocation. The Configurator
    # is constructed inside {Agent#initialize}, yielded to the block
    # (if any), then its collected state is drained by the Agent body.
    # The Configurator instance is discarded once +Agent.new+ returns
    # — it carries no runtime state.
    class Configurator
      # @return [Agent::ChatTransport] same transport the Agent will
      #   use. Extensions read this to wire helpers consistently
      #   (e.g. an MCP description-synthesizer that calls the same
      #   model the agent itself uses).
      attr_reader :transport

      # @return [String] the +system_prompt:+ kwarg passed to
      #   {Agent#initialize}, untouched. The base the Agent prepends to
      #   the pulled {Extension#system_prompt_snippets}; exposed here so
      #   an extension's +configure+ can peek at the base for diagnostics.
      attr_reader :system_prompt_base

      # @return [String] this agent's unique identifier; empty for the
      #   main agent, persona-rooted (e.g. +"researcher 0"+) for sub-agents.
      attr_reader :id

      # @return [Boolean] +true+ when the agent opted into chunk-level
      #   streaming.
      attr_reader :streaming

      # @return [Control::StepLimit, nil] step-budget control passed
      #   to the Agent ctor, or +nil+.
      attr_reader :step_limit

      # @return [Control::Cancellable, nil] cancellation control
      #   passed to the Agent ctor, or +nil+. Extensions that run
      #   sub-LLM calls during +configure+ (e.g. an MCP description
      #   synthesizer) share this so a user cancel during boot
      #   propagates correctly.
      attr_reader :cancellable

      # @return [Control::Interloper, nil] mid-loop user-input queue
      #   passed to the Agent ctor, or +nil+.
      attr_reader :interloper

      # @return [Array<Tool>] tools added via {#add_tool}, in
      #   declaration order. Drained by {Agent#initialize} and
      #   registered with ruby_llm so the parent LLM can call them.
      attr_reader :tools

      # @return [Array<Tool>] tools added via {#add_sub_agent_tool},
      #   in declaration order. Drained by {Agent#initialize} but
      #   *not* registered with ruby_llm — invisible to the parent
      #   LLM, available only to sub-agents through
      #   {Pikuri::SubAgent::Extension}'s persona-tool-name
      #   resolution. See the class header.
      attr_reader :sub_agent_tools

      # @return [Array<Listener::Base>] listeners added via
      #   {#add_listener}, in declaration order. Drained by
      #   {Agent#initialize}.
      attr_reader :listeners

      # @return [Array<Proc>] +on_close+ handlers added via
      #   {#on_close}, in declaration order. Fired by {Agent#close}
      #   in LIFO order with per-handler rescue.
      attr_reader :on_close_handlers

      # @return [Array<#configure>] extension instances added via
      #   {#add_extension}, in declaration order. The Agent ctor
      #   walks this list after wiring is complete and calls +bind+
      #   on each with the agent's {ExtensionContext}.
      attr_reader :extensions

      # @param transport [Agent::ChatTransport]
      # @param system_prompt_base [String]
      # @param id [String]
      # @param streaming [Boolean]
      # @param step_limit [Control::StepLimit, nil]
      # @param cancellable [Control::Cancellable, nil]
      # @param interloper [Control::Interloper, nil]
      # @param on_close_sink [Array<Proc>, nil] array that {#on_close}
      #   appends to. {Agent#initialize} passes its own live
      #   +@on_close_handlers+ so a handler an extension arms via
      #   +c.on_close+ is reachable the instant it's registered — which
      #   is what lets the constructor close a half-built agent if a
      #   later extension's +configure+ raises. Defaults to a fresh
      #   array for standalone use (e.g. specs).
      def initialize(transport:, system_prompt_base:, id:, streaming:,
                     step_limit:, cancellable:, interloper:,
                     on_close_sink: nil)
        @transport = transport
        @system_prompt_base = system_prompt_base
        @id = id
        @streaming = streaming
        @step_limit = step_limit
        @cancellable = cancellable
        @interloper = interloper

        @tools = []
        @sub_agent_tools = []
        @listeners = []
        @on_close_handlers = on_close_sink || []
        @extensions = []
      end

      # Append a tool to the agent's static tool list.
      #
      # @param tool [Tool]
      # @return [void]
      def add_tool(tool)
        @tools << tool
        nil
      end

      # Append several tools at once. Equivalent to calling {#add_tool}
      # for each element of +tools+; declaration order is preserved.
      #
      # @param tools [Enumerable<Tool>]
      # @return [void]
      def add_tools(tools)
        tools.each { |t| @tools << t }
        nil
      end

      # Append a tool to the sub-agent-only pool. The parent LLM
      # never sees it; only sub-agents whose persona +tool_names+
      # include the tool's +name+ get it in their toolset. See the
      # class header for the trifecta-defense rationale.
      #
      # @param tool [Tool]
      # @return [void]
      def add_sub_agent_tool(tool)
        @sub_agent_tools << tool
        nil
      end

      # Append a listener to the agent's listener list.
      #
      # @param listener [Listener::Base]
      # @return [void]
      def add_listener(listener)
        @listeners << listener
        nil
      end

      # Append several listeners at once. Accepts any enumerable
      # (Array, {ListenerList}, …); declaration order is preserved.
      #
      # @param listeners [Enumerable<Listener::Base>]
      # @return [void]
      def add_listeners(listeners)
        listeners.each { |l| @listeners << l }
        nil
      end

      # Register an extension. The extension's +configure(self)+ is
      # called immediately so source-order matches execution-order.
      # The instance is also retained for the +bind(ctx)+ sweep
      # that runs at the end of {Agent#initialize}.
      #
      # Extensions must implement both +configure+ and +bind+. The
      # easy way is to +include Pikuri::Agent::Extension+ — that
      # mixes in empty defaults for both, so an extension overrides
      # only what it cares about and leaves the other as a no-op.
      #
      # @param extension [Extension, #configure, #bind] extension instance
      # @return [void]
      def add_extension(extension)
        @extensions << extension
        extension.configure(self)
        nil
      end

      # Register a handler called by {Agent#close}. Handlers fire in
      # LIFO order, each inside its own +rescue+ — same semantics as
      # +ensure+-block cleanup discipline.
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
