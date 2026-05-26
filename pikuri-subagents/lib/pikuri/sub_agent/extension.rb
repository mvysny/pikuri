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
    #     c.add_sub_agent_tool Pikuri::Tool::WEB_SEARCH
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
    # == Configure / bind split
    #
    # Same MCP-shape division of labor used by {Pikuri::Mcp::Extension}:
    #
    # * +configure(c)+ — agent-agnostic setup. Validates that every
    #   persona's +tool_names+ resolves against tools already
    #   registered on the Configurator (host-side bug to catch at
    #   boot, not at first LLM call), then appends the
    #   +<available_agents>+ snippet via
    #   {Pikuri::Agent::Configurator#append_system_prompt}.
    # * +bind(agent)+ — agent-keyed setup. Constructs the
    #   {SubAgentTool} closing over the live parent agent (its
    #   +tools+, +listeners+, +cancellable+, +context_window_cap+,
    #   +streaming+ flag) and installs it via
    #   {Pikuri::Agent#internal_add_tool}.
    #
    # Sub-agents do not inherit extensions, so +bind+ fires for the
    # parent only.
    #
    # == Duplicate-persona policy
    #
    # The constructor raises +ArgumentError+ if two personas in the
    # list share a +name+. Two personas with the same LLM-facing
    # name would be indistinguishable to the model and a quiet
    # config bug for the host — same rationale as "two Ruby classes
    # with the same name shouldn't exist." Fail fast at construction
    # rather than silently shadow.
    class Extension
      include Pikuri::Agent::Extension

      # @param personas [Array<Persona>] personas the LLM may spawn
      #   via the +agent+ tool. Must contain at least one entry;
      #   names must be unique across the list.
      # @raise [ArgumentError] if +personas+ is empty, contains a
      #   non-{Persona}, or two entries share a +name+
      def initialize(personas:)
        raise ArgumentError, 'personas: must contain at least one Persona' if personas.empty?

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
      #   declaration order. Exposed so tests + diagnostics can
      #   read the resolved map.
      attr_reader :personas

      # Validate every persona's +tool_names+ against the union of
      # the Configurator's regular and sub-agent-only tool pools,
      # then append the +<available_agents>+ snippet to the system
      # prompt. The +SubAgentTool+ itself is installed in {#bind} —
      # it needs the live parent agent's +tools+ / +listeners+ to
      # close over.
      #
      # Practical implication: call +c.add_extension+ *after* the
      # +c.add_tool+ / +c.add_sub_agent_tool+ calls the personas
      # depend on; otherwise the tool_names validation will not find
      # them.
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

        c.append_system_prompt(SubAgentTool.available_agents_snippet(@personas))
        nil
      end

      # Construct the {SubAgentTool} closing over the live parent
      # agent and register it on the agent's chat. Goes through
      # {Pikuri::Agent#internal_add_tool} rather than +@tools+
      # because the tool's +execute+ closure captures
      # +parent_agent.tools+ at construction — by the time +bind+
      # runs, that list is final.
      #
      # @param agent [Pikuri::Agent]
      # @return [void]
      def bind(agent)
        sub_tool = SubAgentTool.new(agent, personas: @personas)
        agent.internal_add_tool(sub_tool.to_ruby_llm_tool)
        nil
      end
    end
  end
end
