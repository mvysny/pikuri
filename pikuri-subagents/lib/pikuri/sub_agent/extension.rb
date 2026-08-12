# frozen_string_literal: true

module Pikuri
  module SubAgent
    # An {Pikuri::Agent::Extension} that wires the +agent+ tool onto
    # a parent agent from a list of {Persona} instances. The
    # canonical opt-in for sub-agents — same shape as
    # {Pikuri::Skill::Extension} and {Pikuri::Mcp::Extension}.
    #
    # == Usage
    #
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_sub_agent_tool Pikuri::Tool::WebSearch.build
    #     c.add_sub_agent_tool Pikuri::Tool::WEB_SCRAPE
    #     c.add_sub_agent_tool Pikuri::Tool::FETCH
    #     c.add_extension Pikuri::SubAgent::Extension.new(
    #       personas: [Pikuri::SubAgent::RESEARCHER]
    #     )
    #   end
    #
    # Either {Pikuri::Agent::Configurator#add_tool} or
    # {Pikuri::Agent::Configurator#add_sub_agent_tool} satisfies a
    # persona's +tool_names+ entry — the difference is whether the
    # parent LLM also gets the tool. Use +add_sub_agent_tool+ for
    # tools you want only the sub-agent to be able to call (this is
    # the lethal-trifecta defense for network tools — see SECURITY.md
    # §"Defense: capability boundaries via sub-agents").
    #
    # The MCP-shape configure/bind split: +configure(c)+ validates every
    # persona's +tool_names+ against tools already on the Configurator (a
    # host-side bug to catch at boot, not first LLM call) and contributes
    # the +<available_agents>+ snippet; +bind(ctx)+ constructs the
    # {SubAgentTool} over the parent's {Pikuri::Agent::ExtensionContext}.
    # Sub-agents don't inherit extensions, so +bind+ fires for the parent
    # only.
    #
    # The constructor raises on two personas sharing a +name+ (they'd be
    # indistinguishable to the model and a quiet config bug) — fail fast
    # rather than silently shadow.
    class Extension
      include Pikuri::Agent::Extension

      # @param personas [Array<Persona>] personas the LLM may spawn
      #   via the +agent+ tool. Must contain at least one entry;
      #   names must be unique across the list.
      # @param confirmer [Pikuri::Workspace::Confirmer, nil] optional gate
      #   threaded into {SubAgentTool}; when present, each delegation's
      #   +task+ is confirmed before dispatch. +nil+ (default) delegates
      #   un-gated. Hosts wire one when a persona reaches the network and
      #   the parent holds private data.
      # @raise [ArgumentError] if +personas+ is empty, contains a
      #   non-{Persona}, or two entries share a +name+
      def initialize(personas:, confirmer: nil)
        raise ArgumentError, 'personas: must contain at least one Persona' if personas.empty?

        @confirmer = confirmer

        @personas = {}
        personas.each do |persona|
          raise ArgumentError, "expected Pikuri::SubAgent::Persona, got #{persona.class}" \
            unless persona.is_a?(Persona)
          raise ArgumentError, "duplicate persona name #{persona.name.inspect} " \
                               'in personas: list' \
            if @personas.key?(persona.name)

          @personas[persona.name] = persona
        end
      end

      # @return [Hash{String=>Persona}] personas keyed by name, in
      #   declaration order.
      attr_reader :personas

      # Validate every persona's +tool_names+ against the union of the
      # Configurator's regular and sub-agent-only tool pools, then append
      # the +<available_agents>+ snippet. So: call +c.add_extension+ *after*
      # the +c.add_tool+ / +c.add_sub_agent_tool+ calls the personas depend
      # on, or the validation won't find them. (The +SubAgentTool+ itself
      # is installed in {#bind}, which needs the live parent to close over.)
      #
      # @param c [Pikuri::Agent::Configurator]
      # @raise [ArgumentError] if any persona references a
      #   +tool_names+ entry not registered on either +c.tools+ or
      #   +c.sub_agent_tools+
      # @return [void]
      def configure(c)
        have = (c.tools + c.sub_agent_tools).map(&:name)
        @personas.each_value do |persona|
          missing = persona.tool_names - have
          next if missing.empty?

          raise ArgumentError,
                "persona #{persona.name.inspect} references unregistered tool(s) " \
                "#{missing.inspect}. Register them via c.add_tool or " \
                "c.add_sub_agent_tool before adding Pikuri::SubAgent::Extension. " \
                "Currently registered: #{have.inspect}."
        end

        nil
      end

      # @return [Array<String>] the +<available_agents>+ catalog built
      #   from the wired persona list (fixed for the agent's lifetime).
      def system_prompt_snippets = [SubAgentTool.available_agents_snippet(@personas)]

      # Construct the {SubAgentTool} over the parent's
      # {Pikuri::Agent::ExtensionContext} and register it. Goes through
      # {Pikuri::Agent::ExtensionContext#add_raw_tool} because the tool's
      # +execute+ closure captures the parent's tool list, which is final
      # only by the time +bind+ runs.
      #
      # @param ctx [Pikuri::Agent::ExtensionContext]
      # @return [void]
      def bind(ctx)
        sub_tool = SubAgentTool.new(ctx, personas: @personas, confirmer: @confirmer)
        ctx.add_raw_tool(sub_tool.to_ruby_llm_tool)
        nil
      end

      # One child node per persona, resolving +tool_names+ against +tools+
      # exactly as {SubAgentTool} does at dispatch — the extension that owns
      # the resolution owns the node, so the tree can never disagree with the
      # toolset a sub-agent actually receives.
      #
      # The gate on each edge is read from the injected confirmer's own
      # posture, not from whether one was supplied: a +--no-confirm+ wiring
      # passes {Pikuri::Workspace::Confirmer::AUTO_APPROVE}, which answers
      # +blocks_on_human? == false+, so the delegation channel scores
      # +:unreviewed+ and the parent's propagated egress re-hardens with
      # nothing in the detector special-casing the flag.
      #
      # @param tools [Array<Pikuri::Tool>]
      # @return [Pikuri::Trifecta::Contribution]
      def trifecta_contribution(tools)
        channel = @confirmer&.blocks_on_human? ? :human_reviewed : :unreviewed

        children = @personas.each_value.map do |persona|
          persona_tools = tools.select { |t| persona.tool_names.include?(t.name) }
          Pikuri::Trifecta::Node.new(
            label: persona.name,
            tool_legs: persona_tools.to_h { |t| [t.name, t.trifecta_legs] },
            channel_egress: channel
          )
        end

        Pikuri::Trifecta::Contribution.new(children: children)
      end
    end
  end
end
