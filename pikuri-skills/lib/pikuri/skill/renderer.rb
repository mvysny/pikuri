# frozen_string_literal: true

module Pikuri
  module Skill
    # Turns {Catalog} / {Catalog::Skill} data into the Agent Skills XML the
    # model actually reads. Two renders, both stateless:
    #
    # - {format_catalog} — the +<available_skills>+ inventory for the system
    #   prompt (advertises what's loadable):
    #
    #     <available_skills>
    #       <skill>
    #         <name>pdf-tools</name>
    #         <description>Extracts text from PDFs.</description>
    #         <location>/repo/.pikuri/skills/pdf-tools/SKILL.md</location>
    #       </skill>
    #     </available_skills>
    #
    # - {format_skill} — one skill's body block, injected when the skill is
    #   loaded (by the +skill+ tool or a host-driven load):
    #
    #     <skill name="pdf-tools" location="/repo/.pikuri/skills/pdf-tools/SKILL.md">
    #     Sidecar paths in this skill (e.g. scripts/, references/) are relative to /repo/.pikuri/skills/pdf-tools.
    #
    #     <the SKILL.md body>
    #     </skill>
    #
    # Presentation lives here, not on {Catalog} (which stays pure discovery /
    # validation / holding) nor on {SkillTool} (a callable action): both
    # renders have callers in different classes whose only shared handle is
    # the catalog data, so a stateless module reached with that data fits
    # both without handle-passing.
    module Renderer
      module_function

      # The +<available_skills>+ inventory block, or +""+ for an empty
      # catalog (so callers concatenate unconditionally). Leads with two
      # blank lines; callers joining prompt sections +lstrip+ as needed.
      #
      # @param catalog [Pikuri::Skill::Catalog]
      # @return [String]
      def format_catalog(catalog)
        return '' if catalog.empty?

        lines = [
          '',
          '',
          'The following skills provide specialized instructions for specific tasks.',
          "When a skill matches the task, load it with the `skill` tool *before* answering from your own knowledge — the skill's instructions take precedence over your training. If none matches, just proceed normally.",
          '',
          '<available_skills>'
        ]
        catalog.list.each do |skill|
          lines << '  <skill>'
          lines << "    <name>#{escape_xml(skill.name)}</name>"
          lines << "    <description>#{escape_xml(skill.description)}</description>"
          lines << "    <location>#{escape_xml(skill.location)}</location>"
          lines << '  </skill>'
        end
        lines << '</available_skills>'
        lines.join("\n")
      end

      # One skill's +<skill>+ body block: the wrapper carries +name+ and
      # +location+ so the model resolves relative sidecar paths against the
      # skill's directory via the +read+ tool.
      #
      # @param skill [Pikuri::Skill::Catalog::Skill]
      # @return [String]
      def format_skill(skill)
        base_dir = File.dirname(skill.location)
        <<~OUT
          <skill name="#{escape_xml(skill.name)}" location="#{escape_xml(skill.location)}">
          Sidecar paths in this skill (e.g. scripts/, references/) are relative to #{base_dir}.

          #{skill.body}
          </skill>
        OUT
      end

      # @param str [String]
      # @return [String] +str+ with XML metacharacters entity-escaped.
      def escape_xml(str)
        str.gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
           .gsub("'", '&apos;')
      end
      private_class_method :escape_xml
    end
  end
end
