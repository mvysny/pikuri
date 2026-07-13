# frozen_string_literal: true

require 'yaml'

module Pikuri
  module Skill
    # Discovery + validation of *skills* — Markdown files with YAML
    # frontmatter that the agent loads on demand via {SkillTool}.
    #
    # A skill is a directory containing a +SKILL.md+ whose frontmatter
    # declares +name+ and +description+. Sibling files (scripts,
    # references, templates) are sidecar content the LLM pulls in via
    # the regular +read+ tool against +File.dirname(location)+. Pikuri
    # implements the {https://agentskills.io/specification Agent Skills
    # standard} leniently — only a missing +description+ is fatal.
    #
    # Two concrete subclasses ship: {Empty} (the +EMPTY+ singleton)
    # and {Bundled} (the on-disk scanner). Hosts that read skills from
    # something other than the filesystem (virtual FS, hardcoded
    # registry) subclass directly.
    class Catalog
      # Frontmatter +name+ cap per the Agent Skills standard.
      MAX_NAME_LENGTH = 64

      # Frontmatter +description+ cap per the Agent Skills standard.
      MAX_DESCRIPTION_LENGTH = 1024

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      # A loaded skill record. Bodies are eager-loaded at scan time;
      # SKILL.md files are small and the tool's hot path stays IO-free.
      Skill = Data.define(:name, :description, :location, :body)

      # @return [Array<Skill>] skills in discovery order (which equals
      #   precedence order).
      # @raise [NotImplementedError] in the abstract base
      def list
        raise NotImplementedError, "#{self.class}#list must be implemented"
      end

      # @param name [String]
      # @return [Skill, nil]
      # @raise [NotImplementedError] in the abstract base
      def get(name)
        raise NotImplementedError, "#{self.class}#get must be implemented"
      end

      # @return [Boolean] true when {#list} is empty; an empty catalog
      #   contributes no tool and no prompt block.
      def empty?
        list.empty?
      end

      # Absolute paths of the skill directories this catalog covers.
      # Hosts wire these into +Pikuri::Workspace::Filesystem+'s
      # +readable:+ list so the LLM can +read+ sidecar files.
      #
      # @return [Array<String>]
      # @raise [NotImplementedError] in the abstract base
      def roots
        raise NotImplementedError, "#{self.class}#roots must be implemented"
      end

      # System-prompt block advertising every loaded skill to the LLM,
      # in the Agent Skills standard's XML shape. Returns +""+ for an
      # empty catalog so callers can unconditionally concatenate.
      #
      # @return [String]
      def format_for_prompt
        return '' if empty?

        lines = [
          '',
          '',
          'The following skills provide specialized instructions for specific tasks.',
          "When a skill matches the task, load it with the `skill` tool *before* answering from your own knowledge — the skill's instructions take precedence over your training. If none matches, just proceed normally.",
          '',
          '<available_skills>'
        ]
        list.each do |skill|
          lines << '  <skill>'
          lines << "    <name>#{escape_xml(skill.name)}</name>"
          lines << "    <description>#{escape_xml(skill.description)}</description>"
          lines << "    <location>#{escape_xml(skill.location)}</location>"
          lines << '  </skill>'
        end
        lines << '</available_skills>'
        lines.join("\n")
      end

      private

      def escape_xml(str)
        str.gsub('&', '&amp;')
           .gsub('<', '&lt;')
           .gsub('>', '&gt;')
           .gsub('"', '&quot;')
           .gsub("'", '&apos;')
      end

      # Null-object catalog. The +EMPTY+ constant is the singleton used
      # as the default when no skills are wired in.
      class Empty < Catalog
        def list
          [].freeze
        end

        def get(_name)
          nil
        end

        def roots
          [].freeze
        end
      end

      # Shared singleton for the no-skills case.
      EMPTY = Empty.new.freeze

      # On-disk catalog over a list of *search bases* (project root,
      # home dir, …). Under each base it scans +.pikuri/skills+ (the
      # user's own), +.claude/skills+ (Claude Code skills ride along)
      # and +.agents/skills+ (PI's cross-harness convention), in that
      # order; missing subdirs are skipped.
      #
      # == Precedence
      #
      # Bases left to right, subdirs in the order above; the *first*
      # skill seen for a name wins, later ones dropped with a warning.
      # Pass the project root first for "project beats global".
      #
      # == Validation
      #
      # The Agent Skills standard is enforced leniently: a missing
      # +description+ is the only hard failure (skill skipped). Name/dir
      # mismatch, oversized name/description, invalid name chars and
      # malformed YAML log a warning and load anyway. A file with no
      # frontmatter is skipped silently (not meant as a skill).
      class Bundled < Catalog
        # Subdirectory names scanned under each search base, in
        # precedence order.
        SKILL_SUBDIRS = ['.pikuri/skills', '.claude/skills', '.agents/skills'].freeze
        private_constant :SKILL_SUBDIRS

        # @param search_bases [Array<String, Pathname>] directories
        #   under which to look for skill subdirs. Typical values:
        #   the project root and +Dir.home+. Processed left to right.
        # @return [Bundled]
        def initialize(search_bases:)
          super()
          @roots = search_bases
                   .flat_map { |base| SKILL_SUBDIRS.map { |sub| File.join(base.to_s, sub) } }
                   .select { |dir| File.directory?(dir) }
                   .freeze
          @skills = {}
          @roots.each { |root| scan_root(root) }
          @skills.freeze
          @list = @skills.values.freeze
          freeze
        end

        # @return [Array<Skill>]
        def list
          @list
        end

        # @param name [String]
        # @return [Skill, nil]
        def get(name)
          @skills[name]
        end

        # @return [Array<String>] absolute paths of the existing skill
        #   directories this catalog covered, in scan order.
        attr_reader :roots

        private

        def scan_root(root)
          Dir.children(root).sort.each do |entry|
            skill_dir = File.join(root, entry)
            next unless File.directory?(skill_dir)

            skill_md = File.join(skill_dir, 'SKILL.md')
            next unless File.file?(skill_md)

            skill = parse_skill(skill_md, parent_dir_name: entry)
            next if skill.nil?

            existing = @skills[skill.name]
            if existing
              LOGGER.warn(
                "skill name '#{skill.name}' at #{skill_md} is shadowed by " \
                "earlier entry at #{existing.location}"
              )
            else
              @skills[skill.name] = skill
            end
          end
        end

        # Read +path+ and return a {Skill}, or +nil+ if the file is
        # unusable (no frontmatter, no description, unreadable).
        def parse_skill(path, parent_dir_name:)
          raw = File.read(path)
          frontmatter, body = split_frontmatter(raw)

          if frontmatter.nil?
            LOGGER.warn("#{path}: no YAML frontmatter; skipped")
            return nil
          end

          description = frontmatter['description'].to_s.strip
          if description.empty?
            LOGGER.warn("#{path}: missing required 'description'; skipped")
            return nil
          end

          name = (frontmatter['name'] || parent_dir_name).to_s
          validate_name(name, parent_dir_name: parent_dir_name, path: path)
          validate_description(description, path: path)

          Skill.new(
            name: name,
            description: description,
            location: path,
            body: body
          )
        rescue Errno::ENOENT, Errno::EACCES => e
          LOGGER.warn("#{path}: #{e.class}: #{e.message}; skipped")
          nil
        end

        # Split a SKILL.md into +[frontmatter_hash, body_string]+.
        # Returns +[nil, raw]+ when no detectable frontmatter block is
        # present. On YAML parse failure, logs a warning and returns
        # +[{}, body]+ so the caller's "missing description" path
        # discards the skill.
        def split_frontmatter(content)
          normalized = content.gsub(/\r\n?/, "\n")
          return [nil, normalized] unless normalized.start_with?("---\n")

          end_marker = normalized.index("\n---", 4)
          return [nil, normalized] unless end_marker

          yaml_str = normalized[4...end_marker]
          body = normalized[(end_marker + 4)..].to_s
          body = body.sub(/\A\n/, '')

          parsed =
            begin
              YAML.safe_load(yaml_str) || {}
            rescue Psych::SyntaxError => e
              LOGGER.warn("frontmatter YAML parse error: #{e.message}")
              {}
            end
          parsed = {} unless parsed.is_a?(Hash)

          [parsed, body]
        end

        def validate_name(name, parent_dir_name:, path:)
          if name != parent_dir_name
            LOGGER.warn("#{path}: skill name '#{name}' does not match parent directory '#{parent_dir_name}'")
          end
          if name.length > MAX_NAME_LENGTH
            LOGGER.warn("#{path}: skill name exceeds #{MAX_NAME_LENGTH} chars (#{name.length})")
          end
          unless /\A[a-z0-9-]+\z/.match?(name)
            LOGGER.warn("#{path}: skill name '#{name}' contains invalid characters " \
                        "(allowed: lowercase a-z, 0-9, hyphens)")
          end
          if name.start_with?('-') || name.end_with?('-')
            LOGGER.warn("#{path}: skill name '#{name}' starts or ends with a hyphen")
          end
          return unless name.include?('--')

          LOGGER.warn("#{path}: skill name '#{name}' contains consecutive hyphens")
        end

        def validate_description(description, path:)
          return unless description.length > MAX_DESCRIPTION_LENGTH

          LOGGER.warn(
            "#{path}: description exceeds #{MAX_DESCRIPTION_LENGTH} chars (#{description.length})"
          )
        end
      end
    end
  end
end
