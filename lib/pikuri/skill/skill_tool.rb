# frozen_string_literal: true

module Pikuri
  module Skill
    # The +skill+ tool: instantiating
    # +Pikuri::Skill::SkillTool.new(catalog:)+ produces a tool whose
    # +execute+ closure looks the requested name up in the bound
    # {Catalog} and returns the skill's body wrapped in a +<skill>+
    # block with the absolute base directory, so the LLM can resolve
    # relative sidecar paths against it via the regular +read+ tool.
    #
    # The class name has +Tool+ as a suffix (rather than just +Tool+
    # nested inside +Skill+) to avoid shadowing the top-level
    # +Pikuri::Tool+ class — +class Tool < Pikuri::Tool+ would read
    # ambiguously. The LLM-facing tool name stays +skill+, matching
    # the Agent Skills standard.
    #
    # The catalog of available skills is *not* duplicated into this
    # tool's description. It lives in the system prompt — see
    # {Catalog#format_for_prompt} — because skills describe what the
    # agent is, not just what one of its tools returns. Putting the
    # catalog in the system prompt keeps it next to the agent's persona
    # and matches what PI and Claude Code do (opencode is the outlier
    # here). The tool description below is therefore *static* — it
    # explains the load mechanism, not the inventory.
    #
    # This tool is not registered manually. {Extension#configure}
    # auto-registers it whenever the catalog is non-empty, and skips
    # it otherwise; sub-agents inherit it through the parent's tool
    # snapshot. The bound catalog rides along in the +execute+
    # closure, so any sub-agent invoking +skill+ resolves names
    # against the same catalog the parent saw.
    class SkillTool < Pikuri::Tool
      # Description shown to the LLM. Follows the opencode-shape (summary
      # + +Usage:+ bullets) prescribed by the project's tool-description
      # convention. The list of which skills exist is not here — see
      # the class header.
      #
      # @return [String]
      DESCRIPTION = <<~DESC
        Load a specialized skill that provides domain-specific instructions and resources for a particular task.

        Usage:
        - The catalog of available skills is listed in your system prompt under `<available_skills>`.
        - Invoke this tool with a skill's `name` to inject its full instructions into the conversation.
        - The loaded skill may reference helper scripts and files in its base directory — use the `read` tool to load those when the skill's instructions tell you to.
        - On `Error: skill '...' not found`, do NOT retry with a guessed name. Pick a name that actually appears in `<available_skills>`, or report to the user that no matching skill is installed.
      DESC

      # @param catalog [Catalog] the catalog to resolve names against.
      #   Captured by closure so the tool retains access to the same
      #   instance even when copied into a sub-agent's tool snapshot.
      # @return [SkillTool]
      def initialize(catalog:)
        super(
          name: 'skill',
          description: DESCRIPTION,
          parameters: Pikuri::Tool::Parameters.build { |p|
            p.required_string :name,
                              'Name of the skill to load, e.g. "pdf-extraction". ' \
                              'Must match a name listed under `<available_skills>` ' \
                              'in the system prompt.'
          },
          execute: lambda { |name:|
            loaded = catalog.get(name)
            if loaded.nil?
              available = catalog.list.map(&:name).sort
              list = available.empty? ? 'none' : available.join(', ')
              next "Error: skill '#{name}' not found. Available skills: #{list}."
            end

            base_dir = File.dirname(loaded.location)
            <<~OUT
              <skill name="#{loaded.name}" location="#{loaded.location}">
              Sidecar paths in this skill (e.g. scripts/, references/) are relative to #{base_dir}.

              #{loaded.body}
              </skill>
            OUT
          }
        )
      end
    end
  end
end
