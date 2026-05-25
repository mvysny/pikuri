# frozen_string_literal: true

module Pikuri
  module Mcp
    # An {Pikuri::Agent::Extension} that wires MCP (Model Context
    # Protocol) support onto an agent: builds an {Mcp::Servers}
    # runtime from a {Registry}, appends the +<available_mcps>+ block
    # to the system prompt, registers an +on_close+ handler that
    # tears down the live MCP clients, and (in +bind+) installs a
    # per-agent +mcp_connect+ tool so the LLM can pull MCP-exposed
    # tools into its toolset on demand.
    #
    # == Configure / bind split
    #
    # +configure+ runs once on the parent's Configurator and creates
    # the *shared* {Mcp::Servers} runtime — that's the resource the
    # extension owns. +bind+ fires once on the parent agent and
    # installs a +Connect+ tool keyed to it, registered via
    # {Agent#internal_add_tool} so the tool's +execute+ closure can
    # call back into the right chat when the LLM activates a server.
    # Sub-agents do not inherit extensions, so they receive neither
    # the +Connect+ tool nor any MCP-backed tools — personas own
    # their toolset by construction.
    #
    # == Usage
    #
    #   registry = Pikuri::Mcp::Registry.new(entries: [
    #     Pikuri::Mcp::Registry::StdioEntry.new(id: 'gmail', command: %w[gmail-mcp])
    #   ])
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Mcp::Extension.new(registry: registry)
    #   end
    #
    # == Empty registry
    #
    # When the registry is {Registry#empty?}, the extension is a
    # no-op — no Servers, no snippet, no tool, no on_close. Same
    # semantics as the legacy +mcp_registry:+ kwarg on
    # {Pikuri::Agent#initialize}, which routes through this
    # extension as a transition layer.
    class Extension
      include Pikuri::Agent::Extension

      # @param registry [Mcp::Registry] configured MCP servers.
      #   Defaults to {Registry::EMPTY} — extension is a no-op then.
      # @param synthesize_descriptions [Boolean] threads a
      #   {Synthesizer} into {Servers} so servers without an
      #   +instructions+ / +serverInfo.title+ field get an
      #   LLM-synthesized description for the +<available_mcps>+
      #   block. On by default — see the +synthesize_descriptions:+
      #   kwarg on +Agent#initialize+ for the full rationale.
      # @param verify_mcp_servers [Boolean] threads a {Verifier}
      #   into {Servers} so every server's handshake + tool surface
      #   is checked for prompt-injection patterns before tools can
      #   register. On by default — see the +verify_mcp_servers:+
      #   kwarg on +Agent#initialize+.
      def initialize(registry: Registry::EMPTY,
                     synthesize_descriptions: true,
                     verify_mcp_servers: true)
        @registry = registry
        @synthesize_descriptions = synthesize_descriptions
        @verify_mcp_servers = verify_mcp_servers
        @servers = nil
      end

      # @return [Mcp::Servers, nil] the runtime built in +configure+,
      #   or +nil+ when the registry was empty (extension is a
      #   no-op).
      attr_reader :servers

      # Build the shared {Servers} runtime, append the
      # +<available_mcps>+ block to the system prompt, and register
      # the close handler. The +Synthesizer+ / +Verifier+ thinker
      # closure captures the Configurator's transport + cancellable
      # so the LLM-driven boot passes run against the same model
      # the agent itself uses and honor the same cancel flag.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @registry.empty?

        if @synthesize_descriptions || @verify_mcp_servers
          thinker = build_thinker(c.transport, c.cancellable)
        end
        synthesizer = build_synthesizer(thinker, c.transport.model) if @synthesize_descriptions
        verifier    = build_verifier(thinker, c.transport.model)    if @verify_mcp_servers

        @servers = Mcp::Servers.new(@registry, synthesizer: synthesizer, verifier: verifier)
        c.append_system_prompt(@servers.system_prompt_snippet.lstrip) unless @servers.empty?
        c.on_close { @servers.close }
        nil
      end

      # Register a per-agent +mcp_connect+ tool on the agent's chat.
      # The tool's +execute+ closure captures the agent reference so
      # activations register their tools on the correct chat — see
      # IDEAS.md §"Two invariants worth recording" for the
      # static-vs-dynamic tool boundary.
      #
      # @param agent [Pikuri::Agent]
      # @return [void]
      def bind(agent)
        return if @servers.nil? || @servers.empty?

        if agent.tools.any?(Mcp::Servers::Connect)
          raise 'Mcp::Servers::Connect cannot be passed in tools: when an MCP runtime is wired; ' \
                'Agent auto-registers it.'
        end

        connect = @servers.build_mcp_connect_tool(agent)
        agent.internal_add_tool(connect.to_ruby_llm_tool)
        nil
      end

      private

      def build_thinker(transport, cancellable)
        ->(prompt) { Pikuri::Agent.think(transport: transport, prompt: prompt, cancellable: cancellable) }
      end

      def build_synthesizer(thinker, model_id)
        Mcp::Synthesizer.new(
          thinker: thinker,
          cache: Mcp::Cache.new(
            model_id: model_id,
            prompt_version: Mcp::Synthesizer::PROMPT_VERSION
          )
        )
      end

      def build_verifier(thinker, model_id)
        Mcp::Verifier.new(
          thinker: thinker,
          cache: Mcp::Cache.new(
            model_id: model_id,
            prompt_version: Mcp::Verifier::PROMPT_VERSION,
            dir: File.join(File.dirname(Mcp::Cache::DIR), 'mcp_verifications')
          )
        )
      end
    end
  end
end
