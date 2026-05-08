# frozen_string_literal: true

# Value object describing a function the LLM can request via OpenAI-style tool
# calling: the metadata advertised in the +tools+ array, plus the callable that
# runs when the LLM invokes it. Tools are stateless — each is a single
# +Tool.new(...)+ constant rather than a subclass.
#
# Bundled tool implementations live under +lib/tool/+ and are required
# explicitly by the scripts that use them; +lib/tool.rb+ itself only
# introduces the {Tool} class and {Tool::Parameters} machinery.
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
end

require_relative 'tool/parameters'
