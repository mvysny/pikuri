# frozen_string_literal: true

require 'did_you_mean'

module Pikuri
  # Loaded by +lib/tools.rb+ after {Tool} itself is defined; the +class Tool+
  # reopening below assumes that order.
  class Tool
    # Schema for a {Tool}'s arguments. Built up via the fluent
    # +<required|optional>_<type>+ methods, then frozen by {.build}; serializes
    # to the OpenAI JSON-Schema shape via {#to_h} and validates LLM-supplied
    # argument hashes via {#validate}.
    #
    # @example
    #   params = Tool::Parameters.build { |p| p.required_string :query, 'The query.' }
    #   params.to_h
    #   # => {type: 'object',
    #   #     properties: {query: {type: 'string', description: 'The query.'}},
    #   #     required: ['query']}
    #   params.validate('query' => 'cats') # => {query: 'cats'}
    class Parameters
      # Raised by {Parameters#validate} when arguments do not match the declared
      # schema. The message lists every problem and reprints the schema, so it
      # can be fed back to the LLM verbatim as the next tool-call observation.
      class ValidationError < StandardError; end

      EMPTY = Parameters.new.freeze

      # Yield a fresh builder, freeze it, and return it.
      #
      # @yieldparam builder [Parameters]
      # @return [Parameters] frozen builder, safe to share between calls
      def self.build
        builder = new
        yield builder
        builder.freeze
      end

      # @return [Parameters]
      def initialize
        @properties = {}
        @required = []
      end

      # Freeze the builder along with its internal collections, so post-build
      # mutation attempts raise +FrozenError+ instead of silently succeeding.
      #
      # @return [self]
      def freeze
        @properties.freeze
        @required.freeze
        super
      end

      # Add a required +string+ property.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def required_string(name, description)
        add(name, 'string', description, required: true)
      end

      # Add an optional +string+ property.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def optional_string(name, description)
        add(name, 'string', description, required: false)
      end

      # Add a required +array+-of-+string+ property — JSON-Schema
      # +{type: 'array', items: {type: 'string'}}+. The LLM sends a
      # native JSON array in the tool-call arguments (the shape its
      # training data overwhelmingly uses for list-valued parameters),
      # so there is no in-band encoding for it to get wrong.
      # The value must arrive as an Array — no
      # JSON-encoded-array-in-a-string fallback. Element coercion
      # mirrors the scalar fields' one documented leniency, in
      # reverse: Integers and finite Floats are converted to their
      # +to_s+ form (a model emitting +["Fix issue 12", 42]+ meant a
      # string list — the conversion is unambiguous), while booleans,
      # +nil+, and nested structures are rejected — those signal a
      # genuinely wrong call shape, not a representational quirk.
      # An empty array is type-valid; rejecting it (if the tool needs
      # at least one element) is the tool's job, with a tool-specific
      # error message.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def required_string_array(name, description)
        @properties[name] = {
          type: 'array',
          items: { type: 'string' },
          description: description
        }
        @required << name.to_s
        self
      end

      # Add a required +integer+ property. Accepts Integers, Floats with a
      # zero fractional part (e.g. +1.0+), and base-10 numeric Strings (after
      # trimming) that resolve to whole numbers; rejects everything else.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def required_integer(name, description)
        add(name, 'integer', description, required: true)
      end

      # Add an optional +integer+ property. See {#required_integer} for
      # accepted shapes.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def optional_integer(name, description)
        add(name, 'integer', description, required: false)
      end

      # Add a required +number+ property (JSON-Schema +number+: Integer or
      # finite Float). Numeric Strings (after trimming) are parsed; NaN and
      # Infinity are rejected.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def required_number(name, description)
        add(name, 'number', description, required: true)
      end

      # Add an optional +number+ property. See {#required_number} for
      # accepted shapes.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def optional_number(name, description)
        add(name, 'number', description, required: false)
      end

      # Add a required +boolean+ property. Accepts Ruby +true+/+false+
      # as-is, and the literal Strings +"true"+/+"false"+ (some models
      # surface JSON booleans as Strings) after trimming surrounding
      # whitespace. Other Strings, numbers, and +nil+ are rejected —
      # there is no truthy-coercion of +"yes"+ / +0+ / etc.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def required_boolean(name, description)
        add(name, 'boolean', description, required: true)
      end

      # Add an optional +boolean+ property. See {#required_boolean} for
      # accepted shapes.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @return [self]
      def optional_boolean(name, description)
        add(name, 'boolean', description, required: false)
      end

      # Add a required +enum+ property — a +string+ field constrained
      # to one of a fixed set of values. Emits JSON-Schema +enum+
      # alongside +type: 'string'+, which the LLM treats as a closed
      # choice. Validation rejects any string outside the set with an
      # LLM-actionable error message listing the allowed values.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @param values [Array<String>] non-empty list of allowed values;
      #   each entry must be a non-empty String. The list is +dup+'d
      #   and frozen at insertion so callers can't mutate it later.
      # @return [self]
      # @raise [ArgumentError] if +values+ is not a non-empty Array of
      #   non-empty Strings (build-time check — surfaces as a host-side
      #   bug rather than an LLM-facing validation error)
      def required_enum(name, description, values:)
        add_enum(name, description, values, required: true)
      end

      # Add an optional +enum+ property. See {#required_enum} for the
      # +values+ contract and validation behavior.
      #
      # @param name [Symbol] property name
      # @param description [String] human-readable description shown to the LLM
      # @param values [Array<String>] non-empty list of allowed values
      # @return [self]
      # @raise [ArgumentError] if +values+ is not a non-empty Array of
      #   non-empty Strings
      def optional_enum(name, description, values:)
        add_enum(name, description, values, required: false)
      end

      # Schema in OpenAI JSON-Schema shape.
      #
      # @return [Hash] +{type: 'object', properties: {...}, required: [...]}+
      def to_h
        { type: 'object', properties: @properties, required: @required }
      end

      # Validate a tool-call argument hash against the declared schema. Returns
      # a symbol-keyed hash safe to splat as kwargs into a tool's +execute+
      # Proc; raises {ValidationError} with an LLM-actionable message listing
      # every missing/unknown/mistyped field and reprinting the schema.
      #
      # Strict: unknown keys are rejected (with DidYouMean suggestions), wrong
      # types are rejected. All issues are collected and reported together so
      # the LLM can fix them in one round trip.
      #
      # @param args [Hash] arguments as decoded from the tool-call JSON; keys
      #   may be Strings or Symbols
      # @return [Hash{Symbol=>Object}] validated, symbol-keyed arguments
      # @raise [ValidationError] if +args+ is not a Hash, contains unknown
      #   keys, omits a required key, or has a value of the wrong type
      def validate(args)
        raise ValidationError, "Arguments must be an object, got #{args.class}." unless args.is_a?(Hash)

        symbolized = args.transform_keys(&:to_sym)
        errors = []
        result = {}

        (symbolized.keys - @properties.keys).each do |unknown|
          errors << unknown_key_error(unknown)
        end

        @properties.each do |name, schema|
          if symbolized.key?(name)
            begin
              coerced = coerce(symbolized[name], schema[:type])
              raise CoercionError, enum_message(schema[:enum], coerced) if schema[:enum] && !schema[:enum].include?(coerced)

              result[name] = coerced
            rescue CoercionError => e
              errors << "Parameter `#{name}` #{e.message}."
            end
          elsif @required.include?(name.to_s)
            errors << missing_required_message(name, schema)
          end
        end

        return result if errors.empty?

        raise ValidationError, build_error_message(errors)
      end

      private

      # Internal coercion failure. Caught by {#validate} and turned into a
      # {ValidationError} message — never escapes the class.
      class CoercionError < StandardError; end
      private_constant :CoercionError

      def add(name, type, description, required:)
        @properties[name] = { type: type, description: description }
        @required << name.to_s if required
        self
      end

      def add_enum(name, description, values, required:)
        unless values.is_a?(Array) && !values.empty? &&
               values.all? { |v| v.is_a?(String) && !v.empty? }
          raise ArgumentError,
                "values: must be a non-empty Array of non-empty Strings, got #{values.inspect}"
        end

        @properties[name] = {
          type: 'string',
          enum: values.dup.freeze,
          description: description
        }
        @required << name.to_s if required
        self
      end

      # Coerce +value+ to a Ruby value matching the JSON-Schema +type+,
      # returning the coerced value. Raises {CoercionError} on failure.
      def coerce(value, type)
        case type
        when 'string'
          return value if value.is_a?(String)

          raise CoercionError, type_message('string', value)
        when 'integer'
          coerce_integer(value)
        when 'number'
          coerce_number(value)
        when 'boolean'
          coerce_boolean(value)
        when 'array'
          coerce_string_array(value)
        end
      end

      def coerce_string_array(value)
        raise CoercionError, "must be an array of strings (got #{value.class}: #{value.inspect})" unless value.is_a?(Array)

        value.each_with_index.map do |element, i|
          case element
          when String
            element
          when Integer
            element.to_s
          when Float
            raise CoercionError, array_element_message(i, element) unless element.finite?

            element.to_s
          else
            raise CoercionError, array_element_message(i, element)
          end
        end
      end

      def array_element_message(index, element)
        "must be an array of strings (element #{index} is #{element.class}: #{element.inspect}; " \
          'numbers are auto-converted, other types are not)'
      end

      def coerce_boolean(value)
        return value if value == true || value == false

        if value.is_a?(String)
          case value.strip
          when 'true'  then return true
          when 'false' then return false
          end
        end

        raise CoercionError, type_message('boolean', value)
      end

      def coerce_integer(value)
        case value
        when Integer
          value
        when Float
          raise CoercionError, type_message('integer', value) unless value.finite? && value.modulo(1).zero?

          value.to_i
        when String
          parsed = parse_numeric_string(value)
          raise CoercionError, type_message('integer', value) unless parsed && parsed.modulo(1).zero?

          parsed.to_i
        else
          raise CoercionError, type_message('integer', value)
        end
      end

      def coerce_number(value)
        case value
        when Integer
          value
        when Float
          raise CoercionError, type_message('number', value) unless value.finite?

          value
        when String
          parsed = parse_numeric_string(value)
          raise CoercionError, type_message('number', value) unless parsed

          parsed
        else
          raise CoercionError, type_message('number', value)
        end
      end

      # Matches the decimal-numeric subset that JSON allows: optional sign,
      # mantissa (with optional fractional part), optional decimal exponent.
      # Rejects hex (+0x10+), underscores (+1_000+), +NaN+, +Infinity+.
      DECIMAL_NUMERIC = /\A[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/
      private_constant :DECIMAL_NUMERIC

      # Strict base-10 numeric-string parse. Returns a finite Float, or +nil+
      # for empty/whitespace/garbage/hex/NaN/Infinity input.
      def parse_numeric_string(str)
        trimmed = str.strip
        return nil unless trimmed.match?(DECIMAL_NUMERIC)

        parsed = Float(trimmed, exception: false)
        return nil unless parsed&.finite?

        parsed
      end

      def type_message(type, value)
        article = type == 'integer' ? 'an' : 'a'
        "must be #{article} #{type} (got #{value.class}: #{value.inspect})"
      end

      def enum_message(values, got)
        "must be one of #{values.map { |v| "`#{v}`" }.join(', ')} (got String: #{got.inspect})"
      end

      def missing_required_message(name, schema)
        enum_part = schema[:enum] ? ", one of: #{schema[:enum].map { |v| "`#{v}`" }.join(', ')}" : ''
        "Missing required parameter `#{name}` (#{type_label(schema)}#{enum_part}): #{schema[:description]}"
      end

      # Human/LLM-facing label for a property's type in error messages:
      # +"array of strings"+ for array properties, the bare JSON-Schema
      # type name otherwise.
      def type_label(schema)
        schema[:items] ? "array of #{schema[:items][:type]}s" : schema[:type]
      end

      def unknown_key_error(unknown)
        suggestion = DidYouMean::SpellChecker
                     .new(dictionary: @properties.keys.map(&:to_s))
                     .correct(unknown.to_s).first
        msg = "Unknown parameter `#{unknown}`."
        msg += suggestion ? " Did you mean `#{suggestion}`?" : " Valid parameters: #{valid_keys_list}."
        msg
      end

      def valid_keys_list
        @properties.keys.map { |k| "`#{k}`" }.join(', ')
      end

      def build_error_message(errors)
        [
          'Invalid arguments:',
          *errors.map { |e| "- #{e}" },
          '',
          'Expected schema:',
          *@properties.map { |name, prop|
            req = @required.include?(name.to_s) ? 'required' : 'optional'
            enum_part = prop[:enum] ? ", one of: #{prop[:enum].map { |v| "`#{v}`" }.join(', ')}" : ''
            "  - `#{name}` (#{type_label(prop)}, #{req}#{enum_part}): #{prop[:description]}"
          }
        ].join("\n")
      end
    end
  end
end
