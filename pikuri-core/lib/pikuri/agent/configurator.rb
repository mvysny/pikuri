# frozen_string_literal: true

module Pikuri
  class Agent
    # Build-time collector yielded into the +Pikuri::Agent.new+ block.
    # Hosts and {Extension} implementations call its methods to declare
    # additional tools, listeners, system-prompt snippets, +on_close+
    # handlers, extension instances, and persona-flavored sub-agents;
    # {Agent#initialize} drains the collected state into the agent's
    # final wiring before returning.
    #
    # == Why this exists
    #
    # Splits "configure the agent" from "the agent's runtime state".
    # Hosts can write a block that reads cleanly:
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_listener Pikuri::Agent::Listener::Terminal.new
    #     c.add_tool     Pikuri::Tool::WEB_SEARCH
    #     c.add_tool     Pikuri::Tool::WEB_SCRAPE
    #     c.add_tool     Pikuri::Tool::FETCH
    #     c.allow_agent  Pikuri::Tool::SubAgent::RESEARCHER
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog)
    #   end
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
      #   {Agent#initialize}, untouched. Extensions append to the
      #   prompt via {#append_system_prompt} rather than mutating
      #   this; the attribute exists so a peek at the base is
      #   available for diagnostics.
      attr_reader :system_prompt_base

      # @return [String] this agent's identifier; empty for the main
      #   agent, persona-rooted (e.g. +"researcher 0"+) for sub-agents.
      attr_reader :name

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
      #   declaration order. Drained by {Agent#initialize}.
      attr_reader :tools

      # @return [Array<Listener::Base>] listeners added via
      #   {#add_listener}, in declaration order. Drained by
      #   {Agent#initialize}.
      attr_reader :listeners

      # @return [Array<String>] system-prompt snippets added via
      #   {#append_system_prompt}, in declaration order. Joined with
      #   double-newline separators between the base prompt and each
      #   snippet by {Agent#initialize}.
      attr_reader :system_prompt_additions

      # @return [Array<Proc>] +on_close+ handlers added via
      #   {#on_close}, in declaration order. Fired by {Agent#close}
      #   in LIFO order with per-handler rescue.
      attr_reader :on_close_handlers

      # @return [Array<#configure>] extension instances added via
      #   {#add_extension}, in declaration order. The Agent ctor
      #   walks this list and calls +bind(self)+ on each after
      #   wiring is complete.
      attr_reader :extensions

      # @return [Hash{String=>Tool::SubAgent::Persona}] personas
      #   registered via {#allow_agent}, keyed by +persona.name+ in
      #   insertion order. Empty when no persona was registered, in
      #   which case the Agent ctor skips creating a
      #   {Tool::SubAgent} and never appends the +<available_agents>+
      #   snippet to the system prompt.
      attr_reader :personas

      # @param transport [Agent::ChatTransport]
      # @param system_prompt_base [String]
      # @param name [String]
      # @param streaming [Boolean]
      # @param step_limit [Control::StepLimit, nil]
      # @param cancellable [Control::Cancellable, nil]
      # @param interloper [Control::Interloper, nil]
      def initialize(transport:, system_prompt_base:, name:, streaming:,
                     step_limit:, cancellable:, interloper:)
        @transport = transport
        @system_prompt_base = system_prompt_base
        @name = name
        @streaming = streaming
        @step_limit = step_limit
        @cancellable = cancellable
        @interloper = interloper

        @tools = []
        @listeners = []
        @system_prompt_additions = []
        @on_close_handlers = []
        @extensions = []
        @personas = {}
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

      # Append a snippet to the system prompt. Snippets are joined
      # to the base prompt with double-newline separators.
      #
      # Used by extensions to register +<available_skills>+,
      # +<available_mcps>+, and similar advertisement blocks. Block
      # users typically pass the full system prompt via the ctor's
      # +system_prompt:+ kwarg instead.
      #
      # @param snippet [String]
      # @return [void]
      def append_system_prompt(snippet)
        @system_prompt_additions << snippet
        nil
      end

      # Register an extension. The extension's +configure(self)+ is
      # called immediately so source-order matches execution-order.
      # The instance is also retained for the +bind(agent)+ sweep
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

      # Register a persona that the agent may spawn via the +agent+
      # tool. Each persona declares its own tool subset, system
      # prompt, and step budget — see {Tool::SubAgent::Persona}.
      #
      # The Agent ctor reads {#personas} after the block returns
      # and, when non-empty, constructs one {Tool::SubAgent}
      # instance keyed to the whole map and appends a single
      # +<available_agents>+ snippet to the system prompt
      # describing every registered persona.
      #
      # == Validation
      #
      # +persona.tool_names+ must be a subset of the tools already
      # registered (via {#add_tool} / {#add_tools} / an extension's
      # +configure+). Registering a persona whose +tool_names+
      # reference an unregistered tool raises here — surfaces as a
      # host-side bug (forgot to wire a tool) rather than an
      # LLM-facing validation error at runtime. Practical
      # implication: call +c.allow_agent+ *after* the tools the
      # persona depends on.
      #
      # Registering the same +persona.name+ twice raises (likely a
      # copy-paste bug; one slot per name).
      #
      # @param persona [Tool::SubAgent::Persona]
      # @raise [ArgumentError] if +persona+ is not a
      #   {Tool::SubAgent::Persona}, the name is already
      #   registered, or +tool_names+ references a tool not in
      #   {#tools}
      # @return [void]
      def allow_agent(persona)
        raise ArgumentError, "expected Tool::SubAgent::Persona, got #{persona.class}" \
          unless persona.is_a?(Tool::SubAgent::Persona)
        raise ArgumentError, "persona #{persona.name.inspect} is already registered" \
          if @personas.key?(persona.name)

        have = @tools.map(&:name)
        missing = persona.tool_names - have
        unless missing.empty?
          raise ArgumentError,
                "persona #{persona.name.inspect} references unregistered tool(s) " \
                "#{missing.inspect}. Register them via c.add_tool before calling " \
                "c.allow_agent. Currently registered: #{have.inspect}."
        end

        @personas[persona.name] = persona
        nil
      end
    end
  end
end
