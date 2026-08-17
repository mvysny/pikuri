# frozen_string_literal: true

module Pikuri
  class Agent
    # Build-time collector yielded into the +Pikuri::Agent.new+ block. Hosts
    # and {Extension}s call its methods to declare tools, listeners,
    # +on_close+ handlers, and extension instances; {Agent#initialize} drains
    # the collected state into the agent's wiring before returning, then
    # discards the Configurator (it carries no runtime state). System-prompt
    # contributions are *not* collected here — the Agent pulls them from each
    # extension's {Extension#system_prompt_snippets} at assembly time.
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_listener Pikuri::Agent::Listener::Terminal.new
    #     c.add_tool     Pikuri::Tool::WebSearch.build
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog, root: project_root)
    #   end
    #
    # Extensions implement +configure(c)+ against this same type, so
    # block-users and extensions share one API.
    #
    # == Two tool pools: regular vs. sub-agent-only
    #
    # {#add_tool} registers a tool the parent agent can call (lands in {#tools},
    # handed to ruby_llm). {#add_sub_agent_tool} registers one the parent
    # *cannot* call (lands in {#sub_agent_tools}, never sent to ruby_llm for the
    # parent) but which {Pikuri::SubAgent::Extension}'s persona-tool-name
    # resolution can reach. The use case is the lethal-trifecta defense: keep
    # network tools (+web_search+ / +web_scrape+ / +fetch+) off the parent so a
    # prompt-injected file read can't egress through it, while the +researcher+
    # persona still reaches them via the +agent+ tool. See SECURITY.md.
    class Configurator
      # @return [Agent::ChatTransport] same transport the Agent will use, so an
      #   extension can wire helpers against the same model.
      attr_reader :transport

      # @return [String] the +system_prompt:+ kwarg, untouched — the base the
      #   Agent prepends to the pulled {Extension#system_prompt_snippets}.
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

      # @return [Control::Cancellable, nil] cancellation control, or +nil+.
      #   Extensions running sub-LLM calls in +configure+ share it so a user
      #   cancel during boot propagates.
      attr_reader :cancellable

      # @return [Control::Interloper, nil] mid-loop user-input queue
      #   passed to the Agent ctor, or +nil+.
      attr_reader :interloper

      # @return [Array<Tool>] tools added via {#add_tool}, in declaration order;
      #   drained by {Agent#initialize} and registered with ruby_llm.
      attr_reader :tools

      # @return [Array<Tool>] tools added via {#add_sub_agent_tool}, in
      #   declaration order; drained but *not* registered with ruby_llm —
      #   available only to sub-agents (see the class header).
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
      #   {#add_extension}, in declaration order. The Agent calls +bind+ on
      #   each after wiring is complete.
      attr_reader :extensions

      # @param transport [Agent::ChatTransport]
      # @param system_prompt_base [String]
      # @param id [String]
      # @param streaming [Boolean]
      # @param step_limit [Control::StepLimit, nil]
      # @param cancellable [Control::Cancellable, nil]
      # @param interloper [Control::Interloper, nil]
      # @param on_close_sink [Array<Proc>, nil] array {#on_close} appends to.
      #   {Agent#initialize} passes its live +@on_close_handlers+ so a handler
      #   armed via +c.on_close+ is reachable instantly — what lets the
      #   constructor close a half-built agent if a later +configure+ raises.
      #   Defaults to a fresh array (standalone/spec use).
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

      # Register an extension: its +configure(self)+ runs immediately (so
      # source order matches execution order), and the instance is retained for
      # the +bind(ctx)+ sweep at the end of {Agent#initialize}. Both hooks are
      # required — +include Pikuri::Agent::Extension+ for no-op defaults.
      #
      # @param extension [Extension, #configure, #bind] extension instance
      # @return [void]
      def add_extension(extension)
        @extensions << extension
        extension.configure(self)
        nil
      end

      # Register a handler called by {Agent#close} (LIFO, each inside its own
      # +rescue+).
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
