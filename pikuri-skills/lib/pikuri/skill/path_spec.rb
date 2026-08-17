# frozen_string_literal: true

module Pikuri
  module Skill
    # Parses a skill's +paths:+ frontmatter key into the pattern list a
    # touched-file matcher takes:
    #
    #   PathSpec.parse(['**/*.rb', 'src/**'], path: md)   # => ["**/*.rb", "src"]
    #   PathSpec.parse('{app,lib}/**, docs', path: md)    # => ["{app,lib}/**", "docs"]
    #   PathSpec.parse(nil, path: md)                     # => [] — advertised always
    #
    # A scalar comma-splits; a trailing +/**+ goes, because gitignore matches a
    # directory and its contents either way and +src+ / +src/**+ should compare
    # equal.
    #
    # == Implementation details
    #
    # {UNCONDITIONAL} is an inversion trap worth knowing before you author
    # frontmatter: +paths: []+, +paths: ["**"]+ and a bare +paths:+ with
    # nothing under it all mean *advertise unconditionally* — the opposite of
    # what "this skill matches no paths" is meant to say, and where an
    # unreadable value lands too, which is why that one warns. Both harnesses
    # that honour the key read it this way; hiding a skill from the model is a
    # different key's job.
    module PathSpec
      # The normalized form of "no gate": this skill is advertised on every
      # turn, like a skill that never mentioned +paths:+ at all.
      UNCONDITIONAL = [].freeze

      LOGGER = Pikuri.logger_for('Skills')
      private_constant :LOGGER

      module_function

      # @param value [String, Array<String>, nil] the raw frontmatter +paths:+
      #   value; +nil+ when the key is absent
      # @param path [String] the SKILL.md location, used in warnings only
      # @return [Array<String>] frozen normalized patterns, or {UNCONDITIONAL}
      def parse(value, path:)
        return UNCONDITIONAL if value.nil?

        patterns = coerce(value)
        if patterns.nil?
          LOGGER.warn("#{path}: 'paths:' must be a string or a list of strings, got " \
                      "#{value.class}; ignored, so the skill stays unconditional")
          return UNCONDITIONAL
        end

        normalize(patterns)
      end

      def coerce(value)
        case value
        when String then split_top_level(value)
        when Array then value.all?(String) ? value.flat_map { |s| split_top_level(s) } : nil
        end
      end
      private_class_method :coerce

      def normalize(patterns)
        cleaned = patterns.map { |p| p.strip.delete_suffix('/**') }.reject(&:empty?)
        return UNCONDITIONAL if cleaned.empty? || cleaned.all?('**')

        cleaned.freeze
      end
      private_class_method :normalize

      # Comma-split that leaves +{js,ts}+ intact.
      def split_top_level(str)
        parts = [+'']
        depth = 0
        str.each_char do |char|
          case char
          when '{' then depth += 1
          when '}' then depth -= 1 if depth.positive?
          when ','
            if depth.zero?
              parts << +''
              next
            end
          end
          parts.last << char
        end
        parts.map(&:strip).reject(&:empty?)
      end
      private_class_method :split_top_level
    end
  end
end
