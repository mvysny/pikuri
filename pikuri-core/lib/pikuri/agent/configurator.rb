# frozen_string_literal: true

module Pikuri
  class Agent
    # The one handle for wiring an {Agent}, yielded into the +Pikuri::Agent.new+
    # block and handed to every {Extension#configure}:
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_listener Pikuri::Agent::Listener::Terminal.new
    #     c.add_tool     Pikuri::Tool::CALCULATOR
    #     c.add_extension Pikuri::Workspace::Extension.new(filesystem: fs, confirmer: confirmer)
    #   end
    #
    # Two kinds of call. *Declarations* — {#add_tool}, {#add_listener},
    # {#add_extension}, {#on_close} — shape the agent being built. *Capabilities*
    # — {#emit_event}, {#add_raw_tool}, {#sub_agent_listeners} — act on the live
    # agent, so an extension keeps the Configurator and uses them later, from a
    # callback or a tool's +execute+:
    #
    #   def configure(c)
    #     @list.on_change = -> { c.emit_event(ListChanged.new(items: @list.items)) }
    #   end
    #
    # == Why a handed object, not methods on Agent
    #
    # {Agent} has no public path to these capabilities (no +listeners+ or
    # +chat+ reader, no emit method): holding an agent grants read access to
    # its config and nothing more. The way to them is to be handed the
    # Configurator — by +Agent.new+, or onward by whoever was
    # ({Pikuri::SubAgent::SubAgentTool} keeps its extension's). The boundary is
    # the API contract, not a mechanical seal.
    #
    # == Two tool pools: regular vs. sub-agent-only
    #
    # {#add_tool} registers a tool the parent agent can call. {#add_sub_agent_tool}
    # registers one the parent *cannot* call, which only a sub-agent whose
    # persona names it receives. The use case is the lethal-trifecta defense:
    # keep network tools (+web_search+ / +web_scrape+ / +fetch+) off the parent
    # so a prompt-injected file read can't egress through it, while the
    # +researcher+ persona still reaches them via the +agent+ tool. See
    # SECURITY.md.
    #
    # == Implementation details
    #
    # {#add_raw_tool} reaches the chat at once, so a raw tool added inside the
    # block precedes the regular tools, which the Agent registers when the block
    # returns. An event emitted inside the block reaches only the listeners
    # added so far.
    class Configurator
      # @return [Agent] the agent being built. Its constructor arguments
      #   (+transport+, +id+, +cancellable+, +interloper+, ...) are readable at
      #   once; what the block declares (+tools+, +system_prompt+) only once
      #   +Agent.new+ returns.
      attr_reader :agent

      # @return [History, nil] the conversation +Agent.new(history:)+ resumes,
      #   as passed in, or +nil+ for a fresh one — so an extension can rebuild
      #   what the transcript implies (MCP re-registers the tools of servers it
      #   had connected).
      attr_reader :history

      # @return [Array<Tool>] tools added via {#add_tool}, in declaration order.
      attr_reader :tools

      # @return [Array<Tool>] tools added via {#add_sub_agent_tool}, in
      #   declaration order.
      attr_reader :sub_agent_tools

      # @return [Array<Extension>] extensions added via {#add_extension}, in
      #   declaration order.
      attr_reader :extensions

      # @param agent [Agent] the agent under construction
      # @param chat [RubyLLM::Chat] its chat, the target of {#add_raw_tool}
      # @param listeners [ListenerList] its listener list
      # @param history [History, nil]
      # @param on_close_sink [Array<Proc>] the agent's live +on_close+ list, so
      #   a handler armed mid-block is there when a later +configure+ raises
      #   and the constructor closes the half-built agent.
      def initialize(agent:, chat:, listeners:, history:, on_close_sink:)
        @agent = agent
        @chat = chat
        @listeners = listeners
        @history = history
        @on_close_handlers = on_close_sink
        @tools = []
        @sub_agent_tools = []
        @extensions = []
      end

      # @param tool [Tool]
      # @return [void]
      def add_tool(tool)
        @tools << tool
        nil
      end

      # @param tools [Enumerable<Tool>]
      # @return [void]
      def add_tools(tools)
        tools.each { |t| add_tool(t) }
        nil
      end

      # Add a tool only sub-agents can receive; see +== Two tool pools+.
      #
      # @param tool [Tool]
      # @return [void]
      def add_sub_agent_tool(tool)
        @sub_agent_tools << tool
        nil
      end

      # @param listener [Listener::Base]
      # @return [void]
      def add_listener(listener)
        @listeners.add(listener)
        nil
      end

      # @param listeners [Enumerable<Listener::Base>]
      # @return [void]
      def add_listeners(listeners)
        listeners.each { |l| add_listener(l) }
        nil
      end

      # Register an extension and run its +configure(self)+ at once, so source
      # order is execution order: a later extension sees what earlier ones
      # added. +include Pikuri::Agent::Extension+ for no-op defaults.
      #
      # An instance serves one agent ({Extension}), so one already added to
      # any agent — this one included, and even after that agent closed — is
      # refused before its +configure+ runs. Reuse is a host bug that fails
      # quietly otherwise: the second agent would share the first one's
      # per-conversation state and the servers it started.
      #
      # @param extension [Extension, #configure] extension instance
      # @return [void]
      # @raise [ArgumentError] when +extension+ was already added to an agent
      def add_extension(extension)
        claim(extension)
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

      # Emit a domain event onto the agent's listener stream. Core {Event}
      # variants narrate the loop; gems define their own (e.g. a task list's
      # +ListChanged+) and emit them here. Listeners no-op on
      # variants they don't recognize ({Listener::Base#on_event}'s default).
      #
      # Call it on the agent's thread — typically inside a tool's +execute+,
      # landing between {Event::ToolCall} and {Event::ToolResult}.
      #
      # @param event [Object] an immutable event value (by convention a +Data+)
      # @return [void]
      def emit_event(event)
        @listeners.on_event(event)
        nil
      end

      # Register a raw +RubyLLM::Tool+ subclass on the agent's chat, bypassing
      # {Pikuri::Tool}'s strict validation — MCP's tools, whose schema is the
      # server's. Usable mid-conversation (+mcp_connect+ adds a server's tools
      # when the model asks).
      #
      # The tool does NOT enter {Agent#tools}, so sub-agents can't snapshot it:
      # activation is strictly per-agent.
      #
      # @param ruby_llm_tool [Class] subclass of +RubyLLM::Tool+
      # @return [void]
      def add_raw_tool(ruby_llm_tool)
        @chat.with_tools(ruby_llm_tool)
        nil
      end

      # A listener list for a spawned sub-agent, via {ListenerList#for_sub_agent}.
      #
      # @param params [Hash{Symbol => Object}] forwarded to each listener's
      #   +for_sub_agent+ hook (currently +id:+)
      # @return [ListenerList]
      def sub_agent_listeners(**params)
        @listeners.for_sub_agent(**params)
      end

      # Every extension ever added, process-wide. Keyed by identity (a
      # +WeakMap+, not a +WeakKeyMap+, so two equal value objects stay two
      # extensions) and weak, so a claim never keeps an extension alive.
      CLAIMED = ObjectSpace::WeakMap.new
      # Agents may be built on several threads; the check and the mark are
      # one step.
      CLAIM_LOCK = Mutex.new
      private_constant :CLAIMED, :CLAIM_LOCK

      private

      # @param extension [Object]
      # @return [void]
      # @raise [ArgumentError] when +extension+ is already claimed
      def claim(extension)
        CLAIM_LOCK.synchronize do
          if CLAIMED.key?(extension)
            raise ArgumentError, "#{extension.class} instance is already added to an agent; " \
                                 'build a fresh one for every Agent.new'
          end

          CLAIMED[extension] = true
        end
      end
    end
  end
end
