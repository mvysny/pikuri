# frozen_string_literal: true

require 'yaml'

module Pikuri
  class Tool
    # Discovery + validation of *skills* — Markdown files with YAML
    # frontmatter that the agent loads on demand via {Tool::Skill}.
    #
    # A skill is a directory containing a +SKILL.md+ file. The frontmatter
    # declares the skill's +name+ and +description+; everything in the
    # directory (helper scripts, reference notes, templates) is treated as
    # sidecar content the LLM can pull in via the regular +read+ tool
    # after loading the skill. Pikuri implements the
    # {https://agentskills.io/specification Agent Skills standard}
    # leniently — invalid frontmatter is warned about but the skill
    # still loads, except a missing +description+ which is fatal (no
    # description means the LLM has no signal for when to invoke it).
    #
    # == Catalog vs. tool
    #
    # {SkillCatalog} owns the *discovery* layer: where skills live, how
    # the frontmatter is parsed, what wins on a name collision. The
    # {Tool::Skill} tool is the *loading* layer: it receives a catalog at
    # construction and looks names up against it when the LLM invokes
    # +skill+. The two are paired by {Agent} — see
    # {Agent#initialize} for the auto-registration rule (non-empty
    # catalog ⇒ +Tool::Skill+ is appended to the tool list and the
    # catalog's prompt block is appended to the system prompt).
    #
    # == The seam
    #
    # {SkillCatalog} is an abstract base with two bundled
    # implementations: {Empty} (the +EMPTY+ singleton, used by
    # +pikuri-chat+ and as the default for any caller that doesn't have a
    # filesystem story) and {Bundled} (the on-disk scanner). The seam
    # lets future hosts (e.g. an in-editor pikuri reading skills from a
    # virtual filesystem, or a synthetic test catalog) swap in without
    # touching {Tool::Skill} or {Agent}.
    class SkillCatalog
      # Frontmatter +name+ cap per the Agent Skills standard.
      MAX_NAME_LENGTH = 64

      # Frontmatter +description+ cap per the Agent Skills standard.
      MAX_DESCRIPTION_LENGTH = 1024

      # The three skill directories pikuri scans, in precedence order.
      # +.pikuri+ first (the user's own pikuri-specific skills),
      # +.claude+ second (so existing Claude Code skills travel along
      # for free), +.agents+ last (the cross-harness convention PI also
      # honors). Same names are used for both global roots
      # (under +~/+) and project roots (relative to CWD, walked up).
      SKILL_DIR_NAMES = ['.pikuri/skills', '.claude/skills', '.agents/skills'].freeze

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      # A loaded skill record. Holds everything the catalog discovers
      # and the tool needs to satisfy a load: +name+ and +description+
      # for the catalog's prompt block, +location+ (absolute path to
      # the +SKILL.md+) so the LLM can reference sidecars relative to
      # +File.dirname(location)+, and +body+ (the SKILL.md content
      # below the frontmatter) returned verbatim when the tool fires.
      #
      # Bodies are eager-loaded at scan time even though only
      # +name+/+description+/+location+ end up in the prompt — skill
      # files are small, eager loading keeps the tool's hot path
      # IO-free, and there is no fault tolerance requirement that
      # warrants the complexity of lazy I/O.
      Skill = Data.define(:name, :description, :location, :body)

      # Skills available to the LLM, in stable insertion order (which
      # equals the order they were discovered, which equals precedence).
      #
      # @return [Array<Skill>]
      # @raise [NotImplementedError] in the abstract base
      def list
        raise NotImplementedError, "#{self.class}#list must be implemented"
      end

      # Look up a skill by name.
      #
      # @param name [String]
      # @return [Skill, nil]
      # @raise [NotImplementedError] in the abstract base
      def get(name)
        raise NotImplementedError, "#{self.class}#get must be implemented"
      end

      # @return [Boolean] true when {#list} is empty. {Agent} keys its
      #   auto-wiring (system-prompt augmentation + +Tool::Skill+
      #   registration) off this — empty catalog ⇒ no surface change.
      def empty?
        list.empty?
      end

      # System-prompt block advertising every loaded skill to the LLM.
      # Follows the Agent Skills standard's XML shape (PI uses the same
      # one) so a skill folder authored against any compliant harness
      # renders consistently here.
      #
      # Returns +""+ for an empty catalog so callers can unconditionally
      # concatenate without an +if+. The leading +\n\n+ separates the
      # block from whatever the caller's static system prompt ends with.
      #
      # @return [String]
      def format_for_prompt
        return '' if empty?

        lines = [
          '',
          '',
          'The following skills provide specialized instructions for specific tasks.',
          "Use the `skill` tool with the skill's name to load its full instructions.",
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

      # Null-object catalog. The +EMPTY+ constant is the singleton
      # instance used as the default for {Agent#initialize}; constructing
      # additional instances is harmless but pointless.
      class Empty < SkillCatalog
        # @return [Array<Skill>] always empty
        def list
          [].freeze
        end

        # @return [nil]
        def get(_name)
          nil
        end
      end

      # Shared singleton for the no-skills case. Frozen.
      EMPTY = Empty.new.freeze

      # On-disk catalog: eager-scans the given +roots+ at construction
      # and freezes itself. Use {.discover} to build one against
      # pikuri's conventional locations; pass +roots:+ directly in
      # tests so collision and ordering behavior can be exercised
      # without staging dirs under +~/+.
      #
      # == Precedence
      #
      # +roots+ is processed left to right. The *first* skill seen for
      # a given name wins; later occurrences are dropped with a warning
      # logged through +Pikuri.logger_for('Skills')+. Callers that want
      # "project beats global" pass project roots first.
      #
      # == Validation
      #
      # The Agent Skills standard is enforced leniently. A missing
      # +description+ is the only hard failure (the skill is skipped);
      # name/dir mismatch, oversized name/description, invalid name
      # characters, malformed YAML — all log warnings and the skill
      # still loads with whatever could be salvaged. Skills without
      # a YAML frontmatter block at all are skipped silently (the file
      # is presumably not meant as a skill).
      class Bundled < SkillCatalog
        # Build a catalog from pikuri's conventional discovery roots:
        # project skills (walked from +cwd+ up to the git root or
        # filesystem root) take precedence over global skills (under
        # the user's home directory). Within each tier, the order in
        # {SKILL_DIR_NAMES} applies (+.pikuri+ ➜ +.claude+ ➜ +.agents+).
        #
        # Non-existent directories are skipped silently; the loaded
        # set is whatever existed at construction time.
        #
        # @param cwd [String, Pathname] working directory whose
        #   ancestor chain is searched for project skill roots.
        # @return [Bundled]
        def self.discover(cwd: Dir.pwd)
          new(roots: discover_project_roots(cwd: cwd) + discover_global_roots)
        end

        # Project roots walked from +cwd+ upwards, stopping at the
        # nearest ancestor containing +.git+ (inclusive) or at the
        # filesystem root. The deepest directory's roots appear first,
        # so closer-to-CWD skills win on name collisions.
        #
        # @param cwd [String, Pathname]
        # @return [Array<String>] absolute paths to existing dirs
        def self.discover_project_roots(cwd:)
          results = []
          current = File.expand_path(cwd.to_s)
          loop do
            SKILL_DIR_NAMES.each do |sub|
              candidate = File.join(current, sub)
              results << candidate if File.directory?(candidate)
            end

            # Stop *after* processing the git root — git roots are
            # natural project boundaries; ancestors above are someone
            # else's project.
            break if File.directory?(File.join(current, '.git'))

            parent = File.dirname(current)
            break if parent == current # filesystem root

            current = parent
          end
          results
        end

        # Global roots under the user's home directory.
        #
        # @return [Array<String>] absolute paths to existing dirs
        def self.discover_global_roots
          home = Dir.home
          SKILL_DIR_NAMES.map { |sub| File.join(home, sub) }
                         .select { |dir| File.directory?(dir) }
        end

        # @param roots [Array<String, Pathname>] skill directories in
        #   precedence order — first occurrence of a given skill name
        #   wins.
        # @return [Bundled]
        def initialize(roots:)
          super()
          @skills = {}
          roots.each { |root| scan_root(root.to_s) }
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

        private

        def scan_root(root)
          return unless File.directory?(root)

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
        # unusable (no frontmatter, no description, unreadable). Warnings
        # for soft violations are logged but do not block loading.
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
        # Returns +[nil, raw]+ when there is no detectable frontmatter
        # block. On YAML parse failure, logs a warning and returns
        # +[{}, body]+ so the caller can still observe an empty
        # frontmatter (which trips the "missing description" path
        # below and discards the skill).
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
