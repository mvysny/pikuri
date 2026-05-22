# frozen_string_literal: true

module Pikuri
  class Agent
    # Build-time collector yielded into the +Pikuri::Agent.new+ block.
    # Hosts and {Extension} implementations call its methods to declare
    # additional tools, listeners, system-prompt snippets, +on_close+
    # handlers, and extension instances; {Agent#initialize} drains the
    # collected state into the agent's final wiring before returning.
    #
    # == Why this exists
    #
    # Splits "configure the agent" from "the agent's runtime state".
    # Hosts can write a block that reads cleanly:
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_listener Pikuri::Agent::Listener::Terminal.new
    #     c.add_tool     Pikuri::Tool::CALCULATOR
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
      #   agent, hierarchical (+"sub_agent 0_1"+) for sub-agents.
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

      # @return [SubAgentRequest, nil] set when the block called
      #   {#allow_sub_agent}; +nil+ otherwise. The Agent ctor uses
      #   this to decide whether to create a {Tool::SubAgent}
      #   instance after the chat is wired (so the SubAgent tool's
      #   parent.tools snapshot doesn't include itself —
      #   recursion guard).
      attr_reader :sub_agent_request

      # Record holding the +max_steps+ value the host passed to
      # {#allow_sub_agent}. The Agent ctor consumes one of these
      # records to build a {Tool::SubAgent} keyed to that step
      # budget.
      SubAgentRequest = Data.define(:max_steps)

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
      # Sole intended caller today is {Tool::SubAgent}, which seeds a
      # sub-agent's Configurator from the parent's tool snapshot.
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
      # Sole intended caller today is {Tool::SubAgent}, which seeds a
      # sub-agent's Configurator from the parent's listener list (run
      # through {ListenerList#for_sub_agent}).
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

      # Retain a list of already-configured extensions for the
      # bind sweep without re-running +configure+. Sole intended
      # caller is {Tool::SubAgent}, which seeds a sub-agent's
      # Configurator from the parent's extension list — the parent
      # already drove +configure+ and its system-prompt snippets /
      # static tools are inherited by the sub-agent verbatim
      # through {#add_tools} + {#add_listeners} + the augmented
      # +system_prompt+; re-running +configure+ on the sub-agent
      # would double up those contributions. The +bind(sub_agent)+
      # sweep in {Agent#initialize} still fires on each inherited
      # extension so per-agent state (MCP's per-agent connect tool,
      # for example) gets installed fresh on the sub-agent.
      #
      # @param extensions [Enumerable<Extension>]
      # @return [void]
      def inherit_extensions(extensions)
        extensions.each { |ext| @extensions << ext }
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

      # Enable the +sub_agent+ tool on this agent. Records the
      # +max_steps+ budget for sub-agent runs; the Agent ctor reads
      # {#sub_agent_request} after the block returns and constructs
      # the actual {Tool::SubAgent} so its snapshot of the parent's
      # tool list doesn't include itself (recursion guard).
      #
      # Sub-agents inherit the parent's tool list (minus +sub_agent+
      # itself), augmented system prompt, listeners (via
      # +for_sub_agent+ per listener), controls (per the per-control
      # rule), and the parent's extension list. Each inherited
      # extension's +bind(sub_agent)+ fires during the sub-agent's
      # construction — that's how MCP's per-agent connect tool ends
      # up keyed to the sub-agent rather than the parent.
      #
      # @param max_steps [Integer] step budget for each sub-agent
      #   run, passed to {Tool::SubAgent#initialize}.
      # @raise [RuntimeError] if called more than once on the same
      #   Configurator.
      # @return [void]
      def allow_sub_agent(max_steps: 10)
        raise 'allow_sub_agent may only be called once per agent' if @sub_agent_request

        @sub_agent_request = SubAgentRequest.new(max_steps: max_steps)
        nil
      end
    end
  end
end
