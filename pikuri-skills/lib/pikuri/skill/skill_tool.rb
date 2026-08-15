# frozen_string_literal: true

module Pikuri
  module Skill
    # The +skill+ tool: looks the requested +name+ up in the bound
    # {Catalog} and returns the skill body wrapped in a +<skill>+ block
    # with its base directory, so the LLM resolves relative sidecar
    # paths against it via the +read+ tool.
    #
    # The available-skills inventory is *not* in this tool's
    # description — it lives in the system prompt (see
    # {Renderer.format_catalog}), next to the agent's persona, as PI
    # and Claude Code do (opencode is the outlier). So the description
    # is static: it explains the load mechanism, not the inventory.
    #
    # {Extension#configure} auto-registers this (never manually) when
    # the catalog is non-empty. The bound catalog rides in the +execute+
    # closure, so a sub-agent inheriting the tool resolves names against
    # the same catalog the parent saw.
    #
    # The prompt pays per skill *installed*, this tool pays per skill
    # *used* — the split an outside-model review (Grok 4.6, 2026-08)
    # picked out over dumping every body up front. Pre-injecting bodies
    # to save the round-trip trades the cheap axis for the expensive one.
    class SkillTool < Pikuri::Tool
      # Description shown to the LLM (opencode-shape; inventory omitted —
      # see the class header).
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

            Pikuri::Skill::Renderer.format_skill(loaded)
          },
          # Hard untrusted, no egress. A skill is a file someone else wrote — the
          # Agent Skills standard exists precisely so bundles travel between harnesses
          # — and loading one drops its text into the model's context verbatim. The
          # host may well trust its own catalogue, but the tool cannot tell a
          # hand-written skill from a downloaded +.agents/+ bundle.
          trifecta_legs: Pikuri::Tool::TrifectaLegs.new(private: false, untrusted: :hard, egress_payload_review: :no_egress)
        )
      end
    end
  end
end
