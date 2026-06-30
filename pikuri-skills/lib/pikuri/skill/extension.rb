# frozen_string_literal: true

module Pikuri
  # Namespace for the Skills feature. Built around the Agent Skills
  # standard implemented in {Pikuri::Skill::Catalog} and
  # {Pikuri::Skill::SkillTool}; this module hosts the *Extension* class
  # ({Extension}) that wires the two into an {Pikuri::Agent}.
  module Skill
    # An {Pikuri::Agent::Extension} that auto-wires the Agent Skills
    # standard onto an agent: appends the catalog's
    # +<available_skills>+ block to the system prompt and registers
    # the +skill+ tool so the LLM can load skill bodies on demand.
    #
    # == Usage
    #
    # Pass the extension via the +Agent.new+ block:
    #
    #   catalog = Pikuri::Skill::Catalog::Bundled.new(
    #     search_bases: [project_root, Dir.home]
    #   )
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog)
    #   end
    #
    # The +configure+ hook is agent-agnostic — it appends a snippet
    # and adds a tool, both of which sub-agents inherit verbatim
    # through the existing snapshot mechanism. There is no per-agent
    # state, so this extension does not implement +bind+ (inherits
    # the empty default from {Pikuri::Agent::Extension}).
    #
    # == Empty catalog
    #
    # When the catalog is {Pikuri::Skill::Catalog#empty?}, the
    # extension is a no-op — no snippet, no tool. Same semantics as
    # the legacy +skill_catalog:+ kwarg on {Pikuri::Agent#initialize},
    # which still routes through this extension as a transition layer
    # until Step 5 of the gem-split refactor (see IDEAS.md).
    class Extension
      include Pikuri::Agent::Extension

      # @param catalog [Pikuri::Skill::Catalog] the catalog of
      #   skills the agent may load. Required.
      def initialize(catalog:)
        @catalog = catalog
      end

      # @return [Pikuri::Skill::Catalog]
      attr_reader :catalog

      # Register the +skill+ tool. No-op when the catalog is empty
      # (the +<available_skills>+ snippet is contributed by
      # {#system_prompt_snippets}).
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @catalog.empty?

        if c.tools.any?(Pikuri::Skill::SkillTool)
          raise 'Pikuri::Skill::SkillTool cannot be pre-registered (in tools: or via c.add_tool) ' \
                'when adding Pikuri::Skill::Extension — the extension auto-registers it from the catalog.'
        end

        c.add_tool(Pikuri::Skill::SkillTool.new(catalog: @catalog))
        nil
      end

      # The +<available_skills>+ catalog block, or none for an empty
      # catalog. The catalog's +format_for_prompt+ historically returns
      # a snippet with leading blank lines (designed for the old
      # +system_prompt + format_for_prompt+ concatenation); the Agent
      # joins sections with +\n\n+, so +lstrip+ avoids doubling the
      # blank lines.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        return [] if @catalog.empty?

        [@catalog.format_for_prompt.lstrip]
      end
    end
  end
end
