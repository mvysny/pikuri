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
    #   catalog = Pikuri::Skill::Catalog::Bundled.discover
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

      # Append +<available_skills>+ to the system prompt and
      # register the +skill+ tool. No-op when the catalog is empty.
      #
      # The catalog's +format_for_prompt+ historically returns a
      # snippet with leading blank lines (designed for the old
      # +system_prompt + format_for_prompt+ concatenation). The
      # Configurator handles the separator between base and snippet
      # itself ({Configurator#append_system_prompt} drains with a
      # +\n\n+ join), so we +lstrip+ to avoid doubling up the blank
      # lines.
      #
      # @param c [Pikuri::Agent::Configurator]
      # @return [void]
      def configure(c)
        return if @catalog.empty?

        c.append_system_prompt(@catalog.format_for_prompt.lstrip)
        c.add_tool(Pikuri::Skill::SkillTool.new(catalog: @catalog))
        nil
      end
    end
  end
end
