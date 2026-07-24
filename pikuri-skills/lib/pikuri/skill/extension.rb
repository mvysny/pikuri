# frozen_string_literal: true

module Pikuri
  # Namespace for the Skills feature — the Agent Skills standard, as
  # {Catalog} (discovery) + {SkillTool} (load) + {Extension} (wiring).
  module Skill
    # An {Pikuri::Agent::Extension} that auto-wires the Agent Skills
    # standard onto an agent: appends the catalog's
    # +<available_skills>+ block to the system prompt and registers
    # the +skill+ tool so the LLM can load skill bodies on demand.
    # Empty catalog ⇒ no-op (no snippet, no tool).
    #
    # == Usage
    #
    #   catalog = Pikuri::Skill::Catalog::Bundled.new(
    #     search_bases: [project_root, Dir.home]
    #   )
    #   Pikuri::Agent.new(transport: ..., system_prompt: ...) do |c|
    #     c.add_extension Pikuri::Skill::Extension.new(catalog: catalog)
    #   end
    #
    # Stateless: +configure+ appends a snippet and a tool (both
    # inherited verbatim by sub-agents via the tool snapshot), so there
    # is no +bind+.
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

      # The +<available_skills>+ catalog block (empty array for an
      # empty catalog). {Renderer.format_catalog} returns leading blank
      # lines; the Agent joins sections with +\n\n+, so +lstrip+ avoids
      # doubling them.
      #
      # @return [Array<String>]
      def system_prompt_snippets
        return [] if @catalog.empty?

        [Pikuri::Skill::Renderer.format_catalog(@catalog).lstrip]
      end
    end
  end
end
