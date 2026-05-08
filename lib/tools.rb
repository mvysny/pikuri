# frozen_string_literal: true

require 'did_you_mean'
require_relative 'duckduckgo_search'

# Value object describing a function the LLM can request via OpenAI-style tool
# calling: the metadata advertised in the +tools+ array, plus the callable that
# runs when the LLM invokes it. Tools are stateless — each is a single
# +Tool.new(...)+ constant rather than a subclass.
#
# @!attribute [r] name
#   @return [String] function name as advertised to the LLM
# @!attribute [r] description
#   @return [String] human-readable description used by the LLM to decide
#     when to call the tool
# @!attribute [r] parameters
#   @return [Tool::Parameters] declared schema; validates incoming arguments
#     and serializes to the JSON Schema shape OpenAI expects
# @!attribute [r] execute
#   @return [Proc] callable invoked by {#run}; receives validated keyword
#     arguments and returns a +String+
Tool = Data.define(:name, :description, :parameters, :execute) do
  # Validate +args+ against {#parameters} and invoke the underlying callable.
  # Takes a +Hash+ (matching the JSON-decoded tool-call payload from the LLM)
  # rather than kwargs — validation lives at the boundary.
  #
  # @param args [Hash] arguments as decoded from the tool-call JSON; keys may
  #   be Strings or Symbols
  # @return [String] observation text to feed back into the next chat turn
  # @raise [Tool::Parameters::ValidationError] if +args+ does not match the
  #   declared schema; the message is LLM-actionable and can be returned to
  #   the model as the next observation
  def run(args)
    validated = parameters.validate(args)
    execute.call(**validated)
  end

  # Render the tool as a single entry of the OpenAI-compatible +tools+ array.
  #
  # @return [Hash] +{type: 'function', function: {name:, description:, parameters:}}+
  def to_openai_schema
    { type: 'function', function: { name:, description:, parameters: parameters.to_h } }
  end
end

# Reopen Tool to add the nested {Parameters} builder + validator.
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
          value = symbolized[name]
          problem = type_error(value, schema[:type])
          if problem
            errors << "Parameter `#{name}` #{problem}."
          else
            result[name] = value
          end
        elsif @required.include?(name.to_s)
          errors << "Missing required parameter `#{name}` (#{schema[:type]}): #{schema[:description]}"
        end
      end

      return result if errors.empty?

      raise ValidationError, build_error_message(errors)
    end

    private

    def add(name, type, description, required:)
      @properties[name] = { type: type, description: description }
      @required << name.to_s if required
      self
    end

    def type_error(value, type)
      case type
      when 'string'
        return "must be a string (got #{value.class}: #{value.inspect})" unless value.is_a?(String)
      end
      nil
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
          "  - `#{name}` (#{prop[:type]}, #{req}): #{prop[:description]}"
        }
      ].join("\n")
    end
  end
end

# DuckDuckGo web-search tool. Thin wrapper over {DuckDuckGoSearch.search}
# that exposes it to the agent loop in OpenAI tool-call shape.
#
# @return [Tool]
WEB_SEARCH_TOOL = Tool.new(
  name: 'web_search',
  description: 'Performs a web search for a query and returns the top ' \
               'results formatted as Markdown with titles, links, and ' \
               'descriptions.',
  parameters: Tool::Parameters.build { |p|
    p.required_string :query, 'The search query to perform.'
  },
  execute: ->(query:) { DuckDuckGoSearch.search(query) }
)
